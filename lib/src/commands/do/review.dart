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
/// 3. The run is **planned** ([PublishPlanner]): which repos does the ticket
///    actually release, and with which version increment and merge message?
/// 4. A pull request is opened (or reused) for each of *those* repos and its
///    url printed — titled with the repo's merge message.
/// 5. The ticket hash is stored as `didReview` in `<ticket>/.gg.json`, so
///    `gg did review` can answer whether the current state was reviewed and
///    `gg do publish` refuses a state that was not.
///
/// **Why the questions are asked here.** A ticket carries repos that are only
/// part of it because they sit between two changed packages; they are neither
/// released nor worth reviewing. Asking their version increment — as the
/// publish used to — asked about a release that never happens, and opening
/// their pull request sent a reviewer to an empty diff. The plan answers both
/// at once, and its answers are stored in `<ticket>/.gg/gg-publish.json`, so
/// `gg do publish` finds them and asks nothing again.
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
    PublishPlanner? publishPlanner,
  }) : _canReviewCommand = canReviewCommand ?? CanReviewCommand(ggLog: ggLog),
       _sortedProcessingList =
           sortedProcessingList ?? SortedProcessingList(ggLog: ggLog),
       _doPushCommand = doPushCommand ?? DoPushCommand(ggLog: ggLog),
       _createPullRequest =
           createPullRequest ?? gg.CreatePullRequest(ggLog: ggLog),
       _ticketState = ticketState ?? TicketState(ggLog: ggLog),
       _publishPlanner = publishPlanner ?? PublishPlanner(ggLog: ggLog) {
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

  /// Decides which repos the ticket releases and asks their publish questions.
  final PublishPlanner _publishPlanner;

  @override
  Future<void> exec({
    required Directory directory,
    required GgLog ggLog,
    bool? verbose,
    Map<String, dynamic> options = const {},
  }) => get(directory: directory, ggLog: ggLog, verbose: verbose);

  @override
  Future<void> get({
    required Directory directory,
    required GgLog ggLog,
    bool? verbose,
  }) async {
    ggLog(cH1('\nPrepare review'));

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

    // Step 5: Plan the release ----------------------------------------------
    // Only now is the state the reviewer will see final: `do push` merged the
    // main branches in and refreshed the dependencies, so only now can the
    // skip check be trusted. The pass decides which repos the ticket releases
    // and asks their version increment and merge message.
    final plan = await _planRelease(
      ticketDir: ticketDir,
      subs: subs,
      ggLog: ggLog,
    );

    // Step 6: Open a pull request per released repo and print its url -------
    // Everything is on the remote now, so the work can be reviewed right
    // away instead of only when it is published.
    await _createPullRequests(
      ticketDir: ticketDir,
      ticketName: ticketName,
      plan: plan,
      ggLog: ggLog,
      taskLog: taskLog,
    );

    // Step 7: Persist the review --------------------------------------------
    // `gg did review` answers with this hash whether the *current* state was
    // reviewed, and `gg do publish` refuses a state that was not.
    await _ticketState.writeSuccess(
      ticketDir: ticketDir,
      subs: subs,
      key: DidReviewCommand.stateKey,
    );
  }

  /// Plans what the ticket releases and stores the answers for the publish.
  ///
  /// Each repository's `publish_config.json` is read back first, so the
  /// questions arrive with the answers of an earlier run pre-selected — they
  /// are asked again, because a choice made earlier has to stay correctable.
  /// A repository still carrying the progress of an unfinished publish is
  /// left exactly as it is: its answers are used, nothing is asked and
  /// nothing is written, because overwriting it would strand the `--continue`
  /// that is supposed to finish that run.
  ///
  /// Nothing here may fail the review: the push already succeeded, and a
  /// plan that cannot be made is one the publish makes later.
  Future<PublishPlan> _planRelease({
    required Directory ticketDir,
    required List<Node> subs,
    required GgLog ggLog,
  }) async {
    final unfinishedPublish = anyRepoHasStatus(
      repoDirs: subs.map((node) => node.directory),
      ticketDir: ticketDir,
    );
    if (unfinishedPublish) {
      ggLog(
        cWarn(
          '⚠️ An unfinished publish is in progress — leaving the publish '
          'configuration untouched. Finish it with '
          '"gg do publish --continue".',
        ),
      );
    }

    final plan = await _publishPlanner.plan(
      ticketDir: ticketDir,
      subs: subs,
      ggLog: ggLog,
      // A review is not a release: it never forces one, and it never fails
      // for a question a headless run cannot answer — `do publish` asks it.
      ask: !unfinishedPublish,
      requireAnswers: false,
      wording: PublishPlanWording.review,
    );

    if (!unfinishedPublish && plan.anyPublishes) {
      await plan.save();
    }

    return plan;
  }

  /// Opens — or reuses — the pull request of every repo the ticket **releases**
  /// and prints its url, so a reviewer can be pointed at it immediately. The
  /// printed url links directly to the **changes** of the pull request — see
  /// [_changesUrl] — because looking at the diff is what a review starts
  /// with.
  ///
  /// A repo the plan leaves unpublished gets **no pull request**: it carries
  /// no change of its own — it is in the ticket because it sits between two
  /// changed packages — so a reviewer would land on an empty diff.
  ///
  /// The title is the repo's merge message, the very text that will describe
  /// the change when it lands; the ticket description and finally the ticket
  /// name stand in when the plan has none. The description lists the commits
  /// the ticket made in that repository, as recorded in its
  /// `publish_config.json`. An already open pull request keeps what it has.
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
    required PublishPlan plan,
    required GgLog ggLog,
    required GgLog taskLog,
  }) async {
    // The ticket description is what the ticket is about, so it is the
    // fallback pull-request title — the same default `do commit` uses for its
    // commit message. Without one the ticket (and branch) name is left.
    final fallbackMessage = readTicketDescription(ticketDir) ?? ticketName;

    final released = plan.entries.where((entry) => entry.publishes).toList();
    if (released.isEmpty) {
      ggLog(
        cDetail(
          '\nNo pull requests — the ticket releases nothing. Every repo is '
          'already published.',
        ),
      );
      return;
    }

    final urls = <String, String>{};
    final failures = <String, String>{};

    // Collected first, printed afterwards: the status printer overwrites its
    // own line, so nothing may be logged while it runs.
    await GgStatusPrinter<void>(
      message: 'Creating pull requests',
      ggLog: ggLog,
      dark: true,
    ).run(() async {
      for (final entry in released) {
        try {
          final url = await _createPullRequest.get(
            directory: entry.directory,
            ggLog: taskLog,
            message: entry.mergeMessage ?? fallbackMessage,
            body: entry.pullRequestBody,
          );
          if (url != null) {
            urls[entry.name] = _changesUrl(url);
          }
        } catch (e) {
          failures[entry.name] = _reason(e);
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
