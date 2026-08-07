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
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:path/path.dart' as path;

import 'package:gg_multi_core/gg_multi_core.dart';
import 'package:gg_multi_commit/src/commands/can/review.dart';
import 'package:gg_multi_commit/src/commands/did/review.dart';
import 'package:gg_multi_commit/src/commands/do/push.dart';

/// Command to review all repos in the ticket.
///
/// Reviewing brings the ticket in front of a reviewer:
///
/// 1. `can review` validates that every repo is on a feature branch and
///    committed.
/// 2. `do push` brings every repo onto the remote — merging the main branches
///    into the feature branches on the way (see [DoPushCommand]).
/// 3. A pull request is opened (or reused) per repo and its url printed.
/// 4. The ticket hash is stored as `didReview` in `<ticket>/.gg.json`, so
///    `gg did review` can answer whether the current state was reviewed and
///    `gg do publish` refuses a state that was not.
///
/// The review does not touch the repos' dependency references: the feature
/// branches keep their local path references. Whoever checks the branch out
/// recreates the whole setup from the ticket's `ticket.json`
/// (`gg do import ticket`) instead of resolving siblings via git references.
class DoReviewCommand extends DirCommand<void> {
  /// Constructor
  DoReviewCommand({
    required super.ggLog,
    super.name = 'review',
    super.description = 'Review all repos of the current ticket',
    CanReviewCommand? canReviewCommand,
    SortedProcessingList? sortedProcessingList,
    DoPushCommand? doPushCommand,
    gg.CreatePullRequest? createPullRequest,
    TicketState? ticketState,
  }) : _canReviewCommand = canReviewCommand ?? CanReviewCommand(ggLog: ggLog),
       _sortedProcessingList =
           sortedProcessingList ?? SortedProcessingList(ggLog: ggLog),
       _doPushCommand = doPushCommand ?? DoPushCommand(ggLog: ggLog),
       _createPullRequest =
           createPullRequest ?? gg.CreatePullRequest(ggLog: ggLog),
       _ticketState = ticketState ?? TicketState(ggLog: ggLog) {
    _addArgs();
  }

  /// Instance of CanReviewCommand
  final CanReviewCommand _canReviewCommand;

  /// Instance of SortedProcessingList
  final SortedProcessingList _sortedProcessingList;

  /// Merges the main branches into the feature branches and pushes all repos.
  final DoPushCommand _doPushCommand;

  /// Opens the pull request of a repository's feature branch — without the
  /// auto-merge flag, which only `do publish` adds.
  final gg.CreatePullRequest _createPullRequest;

  /// Persists the `didReview` flag in `<ticketDir>/.gg.json`.
  final TicketState _ticketState;

  @override
  Future<void> exec({
    required Directory directory,
    required GgLog ggLog,
    bool? verbose,
  }) => get(directory: directory, ggLog: ggLog, verbose: verbose);

  @override
  Future<void> get({
    required Directory directory,
    required GgLog ggLog,
    bool? verbose,
  }) async {
    ggLog(cH1('\nReviewing ...'));

    verbose ??= argResults?['verbose'] as bool? ?? false;

    // Step 1: Detect ticket folder ------------------------------------------
    final String? ticketPath = WorkspaceUtils.detectTicketPath(
      path.absolute(directory.path),
    );
    if (ticketPath == null) {
      ggLog(cAction('Please run this command inside a ticket folder.'));
      throw Exception(cDetail('Not inside a ticket folder'));
    }

    final ticketDir = Directory(ticketPath);
    final ticketName = path.basename(ticketDir.path);

    // Step 2: Collect repos in processing order -----------------------------
    final subs = await _sortedProcessingList.get(
      directory: ticketDir,
      ggLog: ggLog,
    );

    if (subs.isEmpty) {
      ggLog(cWarn('⚠️ No repos in this ticket'));
      return;
    }

    final GgLog taskLog = verbose ? ggLog : <String>[].add;

    // Step 3: Can review? ---------------------------------------------------
    await GgStatusPrinter<void>(
      message: 'Can review?',
      ggLog: ggLog,
      dark: true,
    ).run(
      () async =>
          _runCanReview(ticketDir: ticketDir, ggLog: taskLog, errorLog: ggLog),
    );

    // Step 4: Push ----------------------------------------------------------
    // `do push` merges the main branches into the feature branches and
    // brings every repo onto the remote. A merge conflict bubbles up as
    // [MergeConflictException] with the full report; the half-merged
    // working tree survives for the user to resolve.
    await _doPushCommand.exec(
      directory: ticketDir,
      ggLog: ggLog,
      verbose: verbose,
    );

    // Step 5: Open a pull request per repo and print its url ----------------
    // Everything is on the remote now, so the work can be reviewed right
    // away instead of only when it is published.
    await _createPullRequests(
      ticketDir: ticketDir,
      ticketName: ticketName,
      subs: subs,
      ggLog: ggLog,
      taskLog: taskLog,
    );

    // Step 6: Persist the review --------------------------------------------
    // `gg did review` answers with this hash whether the *current* state was
    // reviewed, and `gg do publish` refuses a state that was not.
    await _ticketState.writeSuccess(
      ticketDir: ticketDir,
      subs: subs,
      key: DidReviewCommand.stateKey,
    );
  }

  /// Opens — or reuses — the pull request of every ticket repo and prints its
  /// url, so a reviewer can be pointed at it immediately. The printed url
  /// links directly to the **changes** of the pull request — see
  /// [_changesUrl] — because looking at the diff is what a review starts
  /// with.
  ///
  /// The pull requests are created **without** the auto-merge flag: the
  /// ticket is under review, not ready to land. `gg do publish` reuses them
  /// and sets auto-merge when the release is complete.
  ///
  /// A repo whose pull request cannot be opened does **not** fail the review:
  /// the push has succeeded already, and the branch is on the remote either
  /// way. The reason is reported and the remaining repos are still processed.
  Future<void> _createPullRequests({
    required Directory ticketDir,
    required String ticketName,
    required List<Node> subs,
    required GgLog ggLog,
    required GgLog taskLog,
  }) async {
    // The ticket description is what the ticket is about, so it is the
    // natural pull-request title — the same default `do commit` uses for its
    // commit message. Without one the ticket (and branch) name is left.
    final message = readTicketDescription(ticketDir) ?? ticketName;

    final urls = <String, String>{};
    final failures = <String, String>{};

    // Collected first, printed afterwards: the status printer overwrites its
    // own line, so nothing may be logged while it runs.
    await GgStatusPrinter<void>(
      message: 'Creating pull requests',
      ggLog: ggLog,
      dark: true,
    ).run(() async {
      for (final repo in subs) {
        final repoDir = repo.directory;
        final repoName = path.basename(repoDir.path);
        try {
          final url = await _createPullRequest.get(
            directory: repoDir,
            ggLog: taskLog,
            message: message,
          );
          if (url != null) {
            urls[repoName] = _changesUrl(url);
          }
        } catch (e) {
          failures[repoName] = _reason(e);
        }
      }
    });

    if (urls.isNotEmpty) {
      ggLog(cAction('\n✓ Please open and review:'));
      for (final entry in urls.entries) {
        ggLog('  ${cPath(entry.value)}');
      }
      ggLog('\n');
    }

    for (final entry in failures.entries) {
      // The reason comes last: it is an error message of its own and brings
      // its own final period, so nothing may be appended behind it.
      ggLog(
        cWarn(
          'No pull request for ${entry.key}. Create it manually, or run '
          '"gg do review" again. Reason: ${entry.value}',
        ),
      );
    }
  }

  /// The message of [error] as it is shown to the user: the `Exception: `
  /// prefix `toString` prepends says nothing the sentence around it does not
  /// already say.
  String _reason(Object error) =>
      error.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');

  /// Returns [url] pointing directly at the changes of the pull request, so
  /// the reviewer lands on the diff instead of the conversation.
  ///
  /// GitHub appends `/changes` (`…/pull/59` → `…/pull/59/changes`), Azure
  /// DevOps selects the Files tab via `?_a=files`. Urls of other providers
  /// are printed untouched.
  String _changesUrl(String url) {
    if (url.startsWith('https://github.com/')) {
      return '$url/changes';
    }
    // Azure DevOps pull request urls end in `/pullrequest/<id>`.
    if (url.contains('/pullrequest/')) {
      return '$url?_a=files';
    }
    return url;
  }

  /// Executes `gg_multi can review` for the given ticket directory.
  Future<void> _runCanReview({
    required Directory ticketDir,
    required GgLog ggLog,
    required GgLog errorLog,
  }) async {
    try {
      await _canReviewCommand.exec(directory: ticketDir, ggLog: ggLog);
    } catch (e) {
      errorLog(cError('${(e as dynamic).message}'));
      rethrow;
    }
  }

  /// Adds command line arguments for this command.
  void _addArgs() {
    argParser.addFlag(
      'verbose',
      abbr: 'v',
      help: 'Show detailed log output.',
      defaultsTo: false,
      negatable: true,
    );
  }
}

/// Mock for [DoReviewCommand]
class MockDoReviewCommand extends MockDirCommand<void>
    implements DoReviewCommand {}
