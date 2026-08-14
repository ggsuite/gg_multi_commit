// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_args/gg_args.dart';
import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_lang/gg_lang.dart';
import 'package:gg_local_package_dependencies/gg_local_package_dependencies.dart';
import 'package:gg_git/gg_git.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_one/gg_one.dart' as gg;
import 'package:gg_publish/gg_publish.dart' as gg_publish;
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:path/path.dart' as path;

import 'package:gg_multi_core/gg_multi_core.dart';
import 'package:gg_multi_commit/src/commands/can/commit.dart';
import 'package:gg_multi_commit/src/commands/do/upgrade/deps.dart';

/// Thrown when merging the main branch into a feature branch ends in
/// conflicts.
///
/// The conflicts are deliberately left in the working tree so the user can
/// resolve them; the message therefore carries the full report — conflicting
/// files and the command to continue with — because the callers (`do review`,
/// `do publish`) let it bubble up to the top-level error output.
class MergeConflictException implements Exception {
  /// Constructor
  MergeConflictException(this.message);

  /// The error message.
  final String message;

  @override
  String toString() => message;
}

/// Command to push changes across all repositories in the current ticket.
///
/// Pushing is what brings the ticket onto the remote, so everything that has
/// to happen before the remote sees the branches lives here:
///
/// 1. All repos must be committed (checked via gg_git's `IsCommitted`).
/// 2. The remote main branch is merged into every feature branch, so the
///    pushed state always contains the current main.
/// 3. The dependencies of every repo are upgraded
///    (»dart pub upgrade [--major-versions] --tighten«). `--no-upgrade`
///    skips this step — `do publish`'s ticket-wide checks do so, because
///    the publish upgrades every repo again right before it is published.
/// 4. `gg can commit` re-verifies every repo — merge and upgrade bring in
///    changes, so the checks only make sense after them. Their output stays
///    visible on the command line.
/// 5. What the upgrade changed is recorded as a `#gg:` system commit
///    (no CHANGELOG entry).
/// 6. Commits that already exist on the remote feature branch are integrated
///    (`git pull --rebase`; an obsolete leftover branch of an already merged
///    ticket is replaced instead — see [_remoteBranchIsObsolete]), and every
///    repo is pushed via gg_one's `gg do push`.
///
/// `gg do review` runs this automatically before it opens the pull requests.
class DoPushCommand extends DirCommand<void> {
  /// Constructor
  DoPushCommand({
    required super.ggLog,
    super.name = 'push',
    super.description = 'Merge main into the ticket repos and push them',
    gg.DoPush? ggDoPush,
    gg.GgSystemCommit? systemCommit,
    IsCommitted? isCommitted,
    UpgradeDepsCommand? upgradeDependencies,
    CanCommitCommand? canCommit,
    SortedProcessingList? sortedProcessingList,
    ProcessRunner? processRunner,
    gg_publish.MainBranch? mainBranch,
  }) : _ggDoPush = ggDoPush ?? gg.DoPush(ggLog: ggLog),
       _systemCommit = systemCommit ?? gg.GgSystemCommit(ggLog: ggLog),
       _isCommitted = isCommitted ?? IsCommitted(ggLog: ggLog),
       _upgradeDependencies =
           upgradeDependencies ?? UpgradeDepsCommand(ggLog: ggLog),
       _canCommit = canCommit ?? CanCommitCommand(ggLog: ggLog),
       _sortedProcessingList =
           sortedProcessingList ?? SortedProcessingList(ggLog: ggLog),
       _processRunner = processRunner ?? defaultProcessRunner,
       _mainBranch = mainBranch ?? gg_publish.MainBranch(ggLog: ggLog) {
    _addArgs();
  }

  /// Instance of gg DoPush to perform the push action
  final gg.DoPush _ggDoPush;

  /// Records the changes of the upgrade phase as a `#gg:` system commit.
  final gg.GgSystemCommit _systemCommit;

  /// Checks whether everything in a repository is committed.
  final IsCommitted _isCommitted;

  /// Upgrades the dependencies of every ticket repo.
  final UpgradeDepsCommand _upgradeDependencies;

  /// Re-verifies every repo after the merge and upgrade phases.
  final CanCommitCommand _canCommit;

  /// Sorted processing of repositories within a ticket
  final SortedProcessingList _sortedProcessingList;

  /// Runs git commands (merge, fetch, integrate).
  final ProcessRunner _processRunner;

  /// Detects the name of a repository's main branch (`main`/`master`).
  final gg_publish.MainBranch _mainBranch;

  @override
  Future<void> exec({
    required Directory directory,
    required GgLog ggLog,
    bool? force,
    bool? verbose,
    bool? majorVersions,
    bool? upgrade,
    Map<String, dynamic> options = const {},
  }) => get(
    directory: directory,
    ggLog: ggLog,
    force: force,
    verbose: verbose,
    majorVersions: majorVersions,
    upgrade: upgrade,
  );

  @override
  Future<void> get({
    required Directory directory,
    required GgLog ggLog,
    bool? force,
    bool? verbose,
    bool? majorVersions,
    bool? upgrade,
  }) async {
    // Read verbose/force flags from CLI if not provided programmatically.
    verbose ??= argResults?['verbose'] as bool? ?? false;
    force ??= argResults?['force'] as bool? ?? false;
    majorVersions ??= argResults?['major-versions'] as bool? ?? true;
    upgrade ??= argResults?['upgrade'] as bool? ?? true;

    // Detect if we are inside a ticket folder
    final String? ticketPath = WorkspaceUtils.detectTicketPath(
      path.absolute(directory.path),
    );
    if (ticketPath == null) {
      ggLog(cAction('Please run this command inside a ticket folder.'));
      throw Exception(cDetail('Not inside a ticket folder'));
    }

    final ticketDir = Directory(ticketPath);

    // Collect all repository directories
    // in the ticket using SortedProcessingList
    final nodes = await _sortedProcessingList.get(
      directory: ticketDir,
      ggLog: ggLog,
    );

    if (nodes.isEmpty) {
      ggLog(cWarn('⚠️ No repos in this ticket'));
      return;
    }

    // List repositories that will be pushed ---------------------------------
    final repoNames = nodes
        .map((node) => path.basename(node.directory.path))
        .toList();

    // Only the output of `gg do push` per repo is verbose. The repo headers
    // and the summary are what the user needs either way, so they go to
    // ggLog — a taskLog for all of it would swallow them without --verbose.
    final GgLog taskLog = verbose ? ggLog : <String>[].add;

    ggLog(cH1('\nPushing ...'));
    for (final name in repoNames) {
      ggLog(cDetail(' - $name'));
    }

    // Merging mutates the repos, so nothing may be dirty: a merge into a
    // repo with uncommitted changes can fail halfway or sweep the changes
    // into the merge commit.
    await GgStatusPrinter<void>(
      message: 'Uncommitted changes?',
      ggLog: ggLog,
      dark: true,
    ).run(() async => _checkUncommittedChanges(nodes: nodes, ggLog: taskLog));

    // Merge the remote main branch into every feature branch, so the pushed
    // state always contains the current main. No repo is pushed unless every
    // repo merged cleanly.
    await GgStatusPrinter<void>(
      message: 'Merging main into the feature branches',
      ggLog: ggLog,
      dark: true,
    ).run(
      () async =>
          _mergeMainIntoRepos(nodes: nodes, ggLog: taskLog, errorLog: ggLog),
    );

    // The merge brings the manifests of main into the feature branches, so
    // the resolved dependencies of every repo can be outdated now. Resolve
    // them again before the upgrade runs — a stale `pubspec.lock` would
    // otherwise make the resolution below start from broken state.
    await GgStatusPrinter<void>(
      message: 'Running dart pub get',
      ggLog: ggLog,
      dark: true,
    ).run(() async => _pubGet(nodes: nodes, ggLog: taskLog));

    // Upgrade the dependencies of every repo. The output stays visible —
    // the user must see what the upgrade changed. `do publish`'s ticket-wide
    // checks skip this (upgrade: false): the publish upgrades every repo
    // again right before it is published — after its refs point at the
    // registry, which is the moment that matters.
    if (upgrade) {
      await _upgradeDependencies.exec(
        directory: ticketDir,
        ggLog: ggLog,
        majorVersions: majorVersions,
      );
    }

    // Re-verify every repo after merge + upgrade — the checks only make
    // sense after those changes came in. The output stays visible.
    await _canCommit.exec(directory: ticketDir, ggLog: ggLog);

    // Record what the upgrade changed as a »#gg:« system commit.
    await GgStatusPrinter<void>(
      message: 'Committing upgrade changes',
      ggLog: ggLog,
      dark: true,
    ).run(
      () async => _commitUpgradeChanges(
        nodes: nodes,
        ggLog: taskLog,
        majorVersions: majorVersions!,
        upgrade: upgrade!,
      ),
    );

    await _pushingRepos(
      nodes: nodes,
      ggLog: ggLog,
      taskLog: taskLog,
      force: force,
    );
  }

  // ...........................................................................
  /// Commits the changes the upgrade phase left behind as a gg system
  /// commit — »#gg: dart pub upgrade …« with no CHANGELOG entry.
  Future<void> _commitUpgradeChanges({
    required List<Node> nodes,
    required GgLog ggLog,
    required bool majorVersions,
    required bool upgrade,
  }) async {
    // Without the upgrade phase only the post-merge `pub get` can have
    // changed something — name the commit after what actually ran.
    final message = upgrade
        ? '${gg.ggCommitPrefix}dart pub upgrade '
              '${majorVersions ? '--major-versions ' : ''}--tighten'
        : '${gg.ggCommitPrefix}dart pub get';

    for (final node in nodes) {
      final repoDir = node.directory;
      final isCommitted = await _isCommitted.get(
        directory: repoDir,
        ggLog: ggLog,
      );
      if (isCommitted) {
        continue;
      }
      // A system commit, not »gg do commit«: it must contain gg's own files
      // only. Anything else the user left dirty is saved in its own,
      // prefix-less commit first — the ticket description names it.
      await _systemCommit.commit(
        directory: repoDir,
        ggLog: ggLog,
        message: message,
        userCommitMessage: gg.readTicketDescriptionForRepo,
        // The upgrade tightened the constraints in pubspec.yaml, so the
        // recorded »everything is committed« hash is stale — and `can merge`
        // reads it through `did commit` right after this push.
        stateKey: gg.GgState.doCommitKey,
      );
    }
  }

  // ...........................................................................
  /// Runs `dart pub get` (`flutter pub get` in a Flutter repo) in all [nodes].
  ///
  /// A repo without a `pubspec.yaml` — a pure TypeScript package — has no Dart
  /// dependencies to resolve and is skipped. A failure is reported and fails
  /// the push: an unresolvable dependency after the merge is exactly what the
  /// user has to fix before the branch reaches the remote.
  Future<void> _pubGet({
    required List<Node> nodes,
    required GgLog ggLog,
  }) async {
    for (final repo in nodes) {
      final repoDir = repo.directory;
      final repoName = path.basename(repoDir.path);

      final type = checkProjectType(repoDir);
      if (!type.isDartFamily) {
        continue;
      }

      final executable = type == ProjectType.flutter ? 'flutter' : 'dart';
      final result = await _processRunner(executable, <String>[
        'pub',
        'get',
      ], workingDirectory: repoDir.path);

      if (result.exitCode != 0) {
        final stderrStr = result.stderr?.toString() ?? '';
        final stdoutStr = result.stdout?.toString() ?? '';
        throw Exception(
          cError(
            '"$executable pub get" failed in $repoName: '
            '${stderrStr.isNotEmpty ? stderrStr : stdoutStr}',
          ),
        );
      }

      ggLog(cDetail('✓ Resolved dependencies of $repoName'));
    }
  }

  // ...........................................................................
  /// Throws when one of the [nodes] has uncommitted changes.
  Future<void> _checkUncommittedChanges({
    required List<Node> nodes,
    required GgLog ggLog,
  }) async {
    final uncommitted = <String>[];
    for (final repo in nodes) {
      final isCommitted = await _isCommitted.get(
        directory: repo.directory,
        ggLog: ggLog,
      );
      if (!isCommitted) {
        uncommitted.add(path.basename(repo.directory.path));
      }
    }
    if (uncommitted.isNotEmpty) {
      ggLog(cWarn('Uncommitted changes in'));
      for (final name in uncommitted) {
        ggLog(cDetail(' - $name'));
      }
      throw Exception(
        cError('Uncommitted changes in ${uncommitted.join(', ')}. ') +
            cAction('Please run ') +
            cCmd('gg do commit') +
            cAction(' first.'),
      );
    }
  }

  // ...........................................................................
  /// Merges `origin/<main>` into the current branch of all [nodes].
  ///
  /// `<main>` is the repo's detected main branch (`main`/`master`); a repo
  /// without one has nothing to integrate and is skipped.
  Future<void> _mergeMainIntoRepos({
    required List<Node> nodes,
    required GgLog ggLog,
    required GgLog errorLog,
  }) async {
    for (final repo in nodes) {
      final repoDir = repo.directory;
      final repoName = path.basename(repoDir.path);

      final String? mainBranch = await _mainBranchName(repoDir);
      if (mainBranch == null) {
        ggLog(cDetail('✓ $repoName has no main branch — nothing to merge'));
        continue;
      }

      try {
        // Make sure `origin/<main>` points to the remote's current main.
        // Without this the merge below would silently merge a stale main.
        await _runGit(
          <String>['fetch', 'origin', mainBranch],
          repoDir: repoDir,
          allowFailure: true,
        );

        final result = await _processRunner('git', <String>[
          'merge',
          '-m',
          '${gg.ggCommitPrefix}merge origin/$mainBranch into the feature branch',
          'origin/$mainBranch',
        ], workingDirectory: repoDir.path);

        if (result.exitCode != 0) {
          final stderrStr = result.stderr?.toString() ?? '';
          final stdoutStr = result.stdout?.toString() ?? '';
          final errMsg = stderrStr.isNotEmpty ? stderrStr : stdoutStr;

          // Conflicts are not an error the push can fix — the merge stays in
          // the working tree and the user resolves it. The exception carries
          // the full report because the callers let it bubble to the
          // top-level error output.
          final conflicts = await _conflictingFiles(repoDir);
          if (conflicts.isNotEmpty) {
            throw MergeConflictException(
              _mergeConflictReport(
                repoName: repoName,
                mainBranch: mainBranch,
                conflicts: conflicts,
              ),
            );
          }

          // Any other failure happens before the merge touched the tree —
          // end a possibly half-started merge and report.
          await _runGit(
            <String>['merge', '--abort'],
            repoDir: repoDir,
            allowFailure: true,
          );
          throw Exception(cError(errMsg));
        }

        ggLog(cDetail('✓ Merged $mainBranch into $repoName'));
      } on MergeConflictException {
        rethrow;
      } catch (e) {
        // The reason is printed once, right under the repo it belongs to.
        errorLog(
          [
            cDetail('✗ Failed to merge $mainBranch into $repoName'),
            cError(rmControls('$e')),
          ].join('\n'),
        );
        throw Exception(cDetail('Failed to merge main.'));
      }
    }
  }

  // ...........................................................................
  /// The name of the main branch of [repoDir] (`main`/`master`), or null when
  /// the repository has neither.
  Future<String?> _mainBranchName(Directory repoDir) async {
    try {
      return await _mainBranch.get(directory: repoDir, ggLog: <String>[].add);
    } catch (_) {
      return null;
    }
  }

  // ...........................................................................
  /// The report a merge conflict aborts the push with: the conflicting files
  /// and the command to continue with after resolving them.
  String _mergeConflictReport({
    required String repoName,
    required String mainBranch,
    required List<String> conflicts,
  }) => [
    cError('Merging origin/$mainBranch into $repoName produced conflicts:'),
    for (final file in conflicts) cPath(' - $repoName/$file'),
    cAction('Please resolve the conflicts. Then execute: ') +
        cCmd("gg do commit -m 'Merge main' --no-log"),
  ].join('\n');

  // ...........................................................................
  /// Returns the files [repoDir] currently has merge conflicts in.
  Future<List<String>> _conflictingFiles(Directory repoDir) async {
    final out = await _runGit(
      <String>['diff', '--name-only', '--diff-filter=U'],
      repoDir: repoDir,
      allowFailure: true,
    );
    return out
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  // ...........................................................................
  /// Returns the current branch of [repoDir] — the literal `HEAD` when the
  /// repository is in detached HEAD state.
  Future<String> _currentBranch(Directory repoDir) =>
      _runGit(<String>['rev-parse', '--abbrev-ref', 'HEAD'], repoDir: repoDir);

  // ...........................................................................
  /// Runs git with [args] in [repoDir] and returns the trimmed stdout.
  /// Delegates to the shared [runGit] so `do push` and
  /// `do publish` use one git runner. See there for [allowFailure].
  Future<String> _runGit(
    List<String> args, {
    required Directory repoDir,
    bool allowFailure = false,
  }) => runGit(
    _processRunner,
    args,
    repoDir: repoDir,
    allowFailure: allowFailure,
  );

  // ...........................................................................
  /// Integrates the remote feature branch and pushes every repo, collecting
  /// the repos that failed instead of stopping at the first one.
  Future<void> _pushingRepos({
    required List<Node> nodes,
    required GgLog ggLog,
    required GgLog taskLog,
    required bool force,
  }) async {
    // The reason is printed once, right under the repo it belongs to. The
    // summary and the exception only name the repos — repeating a multi-line
    // git error three times buries it.
    final failedRepos = <String>[];

    for (final node in nodes) {
      final repoDir = node.directory;
      final repoName = path.basename(repoDir.path);

      ggLog('\n${cH1(repoName)}');

      try {
        // Integrate commits that already reached the remote feature branch —
        // e.g. pushed from another machine — so the push below cannot be
        // rejected as non-fast-forward.
        final branch = await _currentBranch(repoDir);
        if (branch != 'HEAD') {
          await _integrateRemoteBranch(
            repoDir: repoDir,
            repoName: repoName,
            branch: branch,
            ggLog: taskLog,
            errorLog: ggLog,
          );
        }

        await _ggDoPush.exec(directory: repoDir, ggLog: taskLog, force: force);
        ggLog(cDetail('✓ Pushed'));
      } catch (e) {
        ggLog(
          [
            cDetail('✗ Failed to push'),
            cError(rmControls('${(e as dynamic).message}')),
          ].join('\n'),
        );
        failedRepos.add(repoName);
      }
    }

    // Summarize the results ----------------------------------------------
    if (failedRepos.isEmpty) {
      ggLog('\nAll repos pushed\n');
      return;
    } else {
      ggLog(cAction('\nPlease fix the issues above.\n'));
    }

    throw Exception(cDetail('Failed to push.'));
  }

  // ...........................................................................
  /// Integrates commits that already exist on the remote feature branch into
  /// the local branch before pushing.
  ///
  /// A feature branch can advance on the remote (e.g. pushed from another
  /// machine) while the local branch advanced independently. Without this,
  /// the subsequent push fails with a non-fast-forward rejection. We
  /// integrate via `git pull --rebase` so the local commits are replayed on
  /// top of the remote state. On a genuine rebase conflict we abort and throw
  /// an actionable error — we never force-push.
  ///
  /// The one exception is an **obsolete** remote branch — see
  /// [_remoteBranchIsObsolete]: rebasing onto it would replay the whole main
  /// branch onto a tip that predates it and conflict on commits that are long
  /// merged. Such a branch is overwritten with `--force-with-lease` instead.
  Future<void> _integrateRemoteBranch({
    required Directory repoDir,
    required String repoName,
    required String branch,
    required GgLog ggLog,
    required GgLog errorLog,
  }) async {
    // Nothing to integrate if the branch does not exist on the remote yet —
    // the push will simply create it.
    final remoteBranch = await _processRunner('git', <String>[
      'ls-remote',
      '--heads',
      'origin',
      branch,
    ], workingDirectory: repoDir.path);
    final remoteHasBranch =
        remoteBranch.exitCode == 0 &&
        (remoteBranch.stdout?.toString().trim().isNotEmpty ?? false);
    if (!remoteHasBranch) {
      return;
    }

    // The hash the remote branch points to right now. It is both the input of
    // the obsolete-branch analysis and the lease of the force push below, so
    // a branch somebody moved in between is never overwritten.
    final remoteHead = remoteBranch.stdout!
        .toString()
        .trim()
        .split(RegExp(r'\s'))
        .first;

    // Make the remote commits available locally — the analysis walks them.
    await _runGit(
      <String>['fetch', 'origin', branch],
      repoDir: repoDir,
      allowFailure: true,
    );

    // Already contained in the local history — nothing to integrate. Checked
    // first because it is the cheap and by far most common case.
    if (await _isAncestor(remoteHead, 'HEAD', repoDir: repoDir)) {
      return;
    }

    if (await _remoteBranchIsObsolete(
      repoDir: repoDir,
      remoteHead: remoteHead,
    )) {
      await _replaceObsoleteRemoteBranch(
        repoDir: repoDir,
        repoName: repoName,
        branch: branch,
        remoteHead: remoteHead,
        ggLog: ggLog,
        errorLog: errorLog,
      );
      return;
    }

    final pull = await _processRunner('git', <String>[
      'pull',
      '--rebase',
      'origin',
      branch,
    ], workingDirectory: repoDir.path);
    if (pull.exitCode != 0) {
      // Leave the repository in a clean (non-rebasing) state for the user.
      await _processRunner('git', <String>[
        'rebase',
        '--abort',
      ], workingDirectory: repoDir.path);
      final stderrStr = pull.stderr?.toString() ?? '';
      errorLog(
        [
          cDetail('✗ Failed to integrate origin/$branch into $repoName'),
          cError(rmControls(stderrStr)),
        ].join('\n'),
      );
      errorLog(
        cAction(
          'Resolve the divergence manually, e.g. '
          '${cCmd('git pull --rebase origin $branch')}, then re-run.',
        ),
      );
      throw Exception(cDetail('Failed to integrate the remote branch.'));
    }
    ggLog(cDetail('✓ Integrated origin/$branch into $repoName before push'));
  }

  // ...........................................................................
  /// Whether `origin/<branch>` is a leftover of a ticket that was **already
  /// merged**, and therefore must not be rebased onto.
  ///
  /// A ticket branch that was squash-merged into `main` keeps existing on the
  /// remote when the provider did not delete it. Re-using the ticket (a fresh
  /// `gg do add`/`do checkout`) recreates
  /// the branch locally *from the current main* — which now contains the
  /// squashed ticket plus everything merged after it. `git pull --rebase`
  /// then replays all of those commits onto a tip that predates them and dies
  /// in conflicts on foreign, long-merged work.
  ///
  /// The branch counts as obsolete when every commit it holds on top of the
  /// local history is either
  ///
  /// * already contained in `origin/main` **by content** (`git cherry`
  ///   compares patch ids, so a squash merge is recognized), or
  /// * one of gg's own bookkeeping commits (`#gg: …`, or a legacy subject) —
  ///   the ref-flipping commits of an earlier gg version carry no work.
  ///
  /// Anything else — a real commit somebody pushed to the branch and that is
  /// not on main — makes this return false, so the regular rebase runs and
  /// no work can be lost.
  Future<bool> _remoteBranchIsObsolete({
    required Directory repoDir,
    required String remoteHead,
  }) async {
    // The local branch must be up to date with main — otherwise this is an
    // ordinary divergence and not the "branch rebuilt from main" situation.
    // `origin/main` is current: the push fetched and merged it in its merge
    // step. A repository without it fails this check and is never treated as
    // obsolete.
    if (!await _isAncestor('origin/main', 'HEAD', repoDir: repoDir)) {
      return false;
    }

    // Commits of the remote branch that are already on main by content.
    final cherry = await _runGit(
      <String>['cherry', 'origin/main', remoteHead],
      repoDir: repoDir,
      allowFailure: true,
    );
    final onMainByContent = <String>{
      for (final line in cherry.split('\n'))
        if (line.trim().startsWith('- ')) line.trim().substring(2).trim(),
    };

    // Everything the remote branch adds to the local history.
    final extra = await _runGit(
      <String>['log', '--format=%H%x09%s', remoteHead, '--not', 'HEAD'],
      repoDir: repoDir,
      allowFailure: true,
    );
    if (extra.isEmpty) {
      return false; // Nothing to explain — the rebase is a no-op anyway.
    }

    for (final line in extra.split('\n')) {
      final entry = line.trim();
      if (entry.isEmpty) {
        continue;
      }
      final tab = entry.indexOf('\t');
      final hash = tab < 0 ? entry : entry.substring(0, tab);
      final subject = tab < 0 ? '' : entry.substring(tab + 1).trim();

      if (onMainByContent.contains(hash)) {
        continue;
      }
      if (gg.isGgGenerated(subject)) {
        continue;
      }
      return false;
    }

    return true;
  }

  // ...........................................................................
  /// Overwrites an obsolete `origin/<branch>` (see [_remoteBranchIsObsolete])
  /// with the local state, so the following push is a fast-forward.
  ///
  /// The lease pins [remoteHead] — the hash the obsolete-branch analysis was
  /// made from — so a branch that moved on the remote in the meantime is
  /// rejected instead of overwritten.
  Future<void> _replaceObsoleteRemoteBranch({
    required Directory repoDir,
    required String repoName,
    required String branch,
    required String remoteHead,
    required GgLog ggLog,
    required GgLog errorLog,
  }) async {
    final push = await _processRunner('git', <String>[
      'push',
      '--force-with-lease=$branch:$remoteHead',
      '--set-upstream',
      'origin',
      'HEAD:refs/heads/$branch',
    ], workingDirectory: repoDir.path);

    if (push.exitCode != 0) {
      final stderrStr = push.stderr?.toString() ?? '';
      errorLog(
        [
          cDetail('✗ Failed to replace the obsolete branch origin/$branch'),
          cError(rmControls(stderrStr)),
        ].join('\n'),
      );
      errorLog(
        cAction(
          'origin/$branch is a leftover of an already merged ticket. Delete '
          'it with ${cCmd('git push origin --delete $branch')}, then re-run.',
        ),
      );
      throw Exception(cDetail('Failed to replace the obsolete branch.'));
    }

    ggLog(
      cWarn(
        'origin/$branch of $repoName was a leftover of an already merged '
        'ticket — replaced it with the current branch instead of rebasing '
        'onto it.',
      ),
    );
  }

  // ...........................................................................
  /// Whether [ancestor] is an ancestor of [descendant] in [repoDir].
  Future<bool> _isAncestor(
    String ancestor,
    String descendant, {
    required Directory repoDir,
  }) async {
    final result = await _processRunner('git', <String>[
      'merge-base',
      '--is-ancestor',
      ancestor,
      descendant,
    ], workingDirectory: repoDir.path);
    return result.exitCode == 0;
  }

  // Adds command line arguments
  void _addArgs() {
    argParser.addFlag(
      'force',
      abbr: 'f',
      help: 'Do a force push.',
      defaultsTo: false,
      negatable: true,
    );
    argParser.addFlag(
      'verbose',
      abbr: 'v',
      help: 'Show detailed log output.',
      defaultsTo: false,
      negatable: true,
    );
    argParser.addFlag(
      'major-versions',
      abbr: 'm',
      help: 'Upgrade dependencies to their latest major versions.',
      defaultsTo: true,
      negatable: true,
    );
    argParser.addFlag(
      'upgrade',
      help: 'Upgrade the dependencies before pushing.',
      defaultsTo: true,
      negatable: true,
    );
  }
}

/// Mock for [DoPushCommand]
class MockDoPushCommand extends MockDirCommand<void> implements DoPushCommand {}
