// @license
// Copyright (c) 2025 Göran Hegenberg. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_args/gg_args.dart';
import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_local_package_dependencies/gg_local_package_dependencies.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_one/gg_one.dart' as gg;
import 'package:gg_publish/gg_publish.dart' as gg_publish;
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:path/path.dart' as path;

import 'package:gg_multi_core/gg_multi_core.dart';

/// Command to check if all repos in the ticket can be reviewed.
class CanReviewCommand extends DirCommand<void> {
  /// Constructor
  CanReviewCommand({
    required super.ggLog,
    super.name = 'review',
    super.description = 'Check if all ticket repos can be reviewed',
    SortedProcessingList? sortedProcessingList,
    ProcessRunner? processRunner,
    gg_publish.IsFeatureBranch? ggIsFeatureBranch,
    gg.PubGetOffline? ggPubGetOffline,
    TicketState? ticketState,
  }) : _sortedProcessingList =
           sortedProcessingList ?? SortedProcessingList(ggLog: ggLog),
       _processRunner = processRunner ?? defaultProcessRunner,
       _ggIsFeatureBranch =
           ggIsFeatureBranch ?? gg_publish.IsFeatureBranch(ggLog: ggLog),
       _ggPubGetOffline = ggPubGetOffline ?? gg.PubGetOffline(ggLog: ggLog),
       _ticketState = ticketState ?? TicketState(ggLog: ggLog) {
    _addArgs();
  }

  /// State key used to persist the cached success in
  /// `<ticketDir>/.gg.json`.
  static const String stateKey = 'canReview';

  /// Instance of SortedProcessingList
  final SortedProcessingList _sortedProcessingList;

  /// The process runner
  final ProcessRunner _processRunner;

  /// Instance of gg_publish IsFeatureBranch
  final gg_publish.IsFeatureBranch _ggIsFeatureBranch;

  /// Instance of gg PubGetOffline
  final gg.PubGetOffline _ggPubGetOffline;

  /// Caches successful runs at ticket level.
  final TicketState _ticketState;

  @override
  Future<void> exec({
    required Directory directory,
    required GgLog ggLog,
    bool? verbose,
    bool? force,
    bool? saveState,
  }) => get(
    directory: directory,
    ggLog: ggLog,
    verbose: verbose,
    force: force,
    saveState: saveState,
  );

  @override
  Future<void> get({
    required Directory directory,
    required GgLog ggLog,
    bool? verbose,
    bool? force,
    bool? saveState,
  }) async {
    verbose ??= argResults?['verbose'] as bool? ?? false;
    force ??= argResults?['force'] as bool? ?? false;
    saveState ??= argResults?['save-state'] as bool? ?? true;

    // Step 1: Detect ticket folder
    final String? ticketPath = WorkspaceUtils.detectTicketPath(
      path.absolute(directory.path),
    );
    if (ticketPath == null) {
      ggLog(cAction('Please run this command inside a ticket folder.'));
      throw Exception(cDetail('Not inside a ticket folder'));
    }

    final ticketDir = Directory(ticketPath);
    // Get sorted repos
    final subs = await _sortedProcessingList.get(
      directory: ticketDir,
      ggLog: ggLog,
    );

    if (subs.isEmpty) {
      ggLog(cWarn('⚠️ No repos in this ticket'));
      return;
    }

    // Short-circuit if the ticket state has not changed since the last
    // successful run.
    if (!force &&
        await _ticketState.readSuccess(
          ticketDir: ticketDir,
          subs: subs,
          key: stateKey,
        )) {
      ggLog('✓ All repos can be reviewed');
      return;
    }

    // Only show task logs when verbose is enabled
    final GgLog taskLog = verbose ? ggLog : <String>[].add;

    // Step 2: Check that all repos are on a feature branch
    await GgStatusPrinter<void>(
      message: 'On feature branch?',
      ggLog: ggLog,
      dark: true,
    ).run(() async => _checkFeatureBranches(subs: subs, ggLog: taskLog));

    // Step 3: Sync pubspec.lock with pubspec.yaml so the next check does not
    // trip over an outdated lockfile.
    await GgStatusPrinter<void>(
      message: 'dart pub get --offline',
      ggLog: ggLog,
      dark: true,
    ).run(() async => _pubGetOffline(subs: subs, ggLog: taskLog));

    // Step 4: Check for uncommitted changes
    await GgStatusPrinter<void>(
      message: 'Uncommitted changes?',
      ggLog: ggLog,
      dark: true,
    ).run(() async => _checkUncommittedChanges(subs: subs, ggLog: taskLog));

    // Persist success so the next invocation can short-circuit.
    if (saveState) {
      await _ticketState.writeSuccess(
        ticketDir: ticketDir,
        subs: subs,
        key: stateKey,
      );
    }

    // All successful
    ggLog('✓ All repos can be reviewed');
  }

  /// Checks that all repos are on a feature branch.
  Future<void> _checkFeatureBranches({
    required List<Node> subs,
    required GgLog ggLog,
  }) async {
    final notOnFeatureBranch = <String>[];
    for (final repo in subs) {
      final repoDir = repo.directory;
      final repoName = path.basename(repoDir.path);
      final isFeature = await _ggIsFeatureBranch.get(
        directory: repoDir,
        ggLog: ggLog,
      );
      if (isFeature) {
        continue;
      }
      // A repo already merged to its default branch (main/master) has nothing
      // left to review — e.g. when resuming a publish that already completed
      // some repos. Skip it instead of failing.
      final branch = await _currentBranch(repoDir);
      if (branch == 'main' || branch == 'master') {
        ggLog('$repoName is on $branch — already merged, skipping.');
        continue;
      }
      notOnFeatureBranch.add(repoName);
    }
    if (notOnFeatureBranch.isNotEmpty) {
      ggLog(cWarn('Not on a feature branch:'));
      for (final name in notOnFeatureBranch) {
        ggLog(cDetail(' - $name'));
      }
      throw Exception(
        cError('Not on a feature branch: ${notOnFeatureBranch.join(', ')}'),
      );
    }
  }

  /// Returns the current branch name of [repoDir] (e.g. `main`, `feat_x`).
  Future<String> _currentBranch(Directory repoDir) async {
    final result = await _processRunner('git', [
      'rev-parse',
      '--abbrev-ref',
      'HEAD',
    ], workingDirectory: repoDir.path);
    return result.stdout.toString().trim();
  }

  /// Runs `dart pub get --offline` (or the Flutter equivalent) in all repos
  /// so that each `pubspec.lock` matches its `pubspec.yaml` before the
  /// uncommitted-changes check runs.
  ///
  /// [gg.PubGetOffline] self-gates on the presence of a `pubspec.yaml`: pure
  /// TypeScript repos (no pubspec.yaml) are skipped, while bridge repos
  /// (pubspec.yaml + package.json + tsconfig) DO carry a Dart `pubspec.lock`
  /// that must be kept in sync — otherwise a stale lock would later surface as
  /// an uncommitted change. So run it for every repo and let it self-gate.
  Future<void> _pubGetOffline({
    required List<Node> subs,
    required GgLog ggLog,
  }) async {
    for (final repo in subs) {
      await _ggPubGetOffline.exec(directory: repo.directory, ggLog: ggLog);
    }
  }

  /// Checks for uncommitted changes in all repos.
  Future<void> _checkUncommittedChanges({
    required List<Node> subs,
    required GgLog ggLog,
  }) async {
    final uncommitted = <String>[];
    for (final repo in subs) {
      final repoDir = repo.directory;
      final result = await _processRunner('git', [
        'status',
        '--porcelain',
      ], workingDirectory: repoDir.path);
      if (result.stdout.toString().trim().isNotEmpty) {
        uncommitted.add(path.basename(repoDir.path));
      }
    }
    if (uncommitted.isNotEmpty) {
      ggLog(cWarn('Uncommitted changes in'));
      for (final name in uncommitted) {
        ggLog(cDetail(' - $name'));
      }
      throw Exception(
        cError('Uncommitted changes in ${uncommitted.join(', ')}'),
      );
    }
  }

  // Adds command line arguments
  void _addArgs() {
    argParser.addFlag(
      'verbose',
      abbr: 'v',
      help: 'Show detailed log output.',
      defaultsTo: false,
      negatable: true,
    );
    argParser.addFlag(
      'force',
      abbr: 'f',
      negatable: false,
      help: 'Execute the checks even if they succeeded before.',
      defaultsTo: false,
    );
    argParser.addFlag(
      'save-state',
      abbr: 's',
      negatable: true,
      help: 'Persist the success hash for later reuse',
      defaultsTo: true,
    );
  }
}

/// Mock for [CanReviewCommand]
class MockCanReviewCommand extends MockDirCommand<void>
    implements CanReviewCommand {}
