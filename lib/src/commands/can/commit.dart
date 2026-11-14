// @license
// Copyright (c) ggsuite
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

/// Command to check if all repos in the ticket can be committed.
class CanCommitCommand extends DirCommand<void> {
  /// Constructor
  CanCommitCommand({
    required super.ggLog,
    super.name = 'commit',
    super.description = 'Check if all ticket repos can be committed',
    gg.CanCommit? ggCanCommit,
    gg.DidCommit? ggDidCommit,
    gg.GgState? ggState,
    SortedProcessingList? sortedProcessingList,
    TicketLocalizer? ticketLocalizer,
  }) : _ggCanCommit = ggCanCommit ?? gg.CanCommit(ggLog: ggLog),
       _ggDidCommit = ggDidCommit ?? gg.DidCommit(ggLog: ggLog),
       _ggState = ggState ?? gg.GgState(ggLog: ggLog),
       _sortedProcessingList =
           sortedProcessingList ?? SortedProcessingList(ggLog: ggLog),
       _ticketLocalizer = ticketLocalizer ?? TicketLocalizer(ggLog: ggLog) {
    _addArgs();
  }

  /// Instance of gg CanCommit
  final gg.CanCommit _ggCanCommit;

  /// Tells whether a repo is already committed — decides the final message.
  final gg.DidCommit _ggDidCommit;

  /// Tells which repos passed their checks before.
  final gg.GgState _ggState;

  /// The key gg_one's `gg can commit` records its success under.
  static const String canCommitStateKey = 'canCommit';

  /// Sorted processing list for repos
  final SortedProcessingList _sortedProcessingList;

  /// Tells whether the references between the ticket repos are localized.
  final TicketLocalizer _ticketLocalizer;

  @override
  Future<void> exec({
    required Directory directory,
    required GgLog ggLog,
    bool? force,
    Map<String, dynamic> options = const {},
  }) => get(directory: directory, ggLog: ggLog, force: force);

  @override
  Future<void> get({
    required Directory directory,
    required GgLog ggLog,
    bool? force,
  }) async {
    force ??= argResults?['force'] as bool? ?? false;

    // Detect if we are inside a ticket folder
    final String? ticketPath = WorkspaceUtils.detectTicketPath(
      path.absolute(directory.path),
    );
    if (ticketPath == null) {
      ggLog(cAction('Please run this command inside a ticket folder.'));
      throw Exception(cDetail('Not inside a ticket folder'));
    }

    final ticketDir = Directory(ticketPath);
    // Collect all repository directories in the ticket via SortedProcessingList
    final nodes = await _sortedProcessingList.get(
      directory: ticketDir,
      ggLog: ggLog,
    );

    if (nodes.isEmpty) {
      ggLog(cWarn('⚠️ No repos in this ticket'));
      return;
    }

    // A hand-added dependency would otherwise test the published package.
    await _ticketLocalizer.throwWhenOutOfSync(
      ticketDir: ticketDir,
      repos: nodes,
      ggLog: ggLog,
    );

    // Which repos passed their checks before? They only confirm that, which
    // takes a moment; the others run analyzer and tests. Asked up front, so
    // a repo that merely confirms never waits behind a test run.
    final passedBefore = force
        ? List<bool>.filled(nodes.length, false)
        : await gg.runInParallel<bool>(
            count: nodes.length,
            maxParallel: gg.GgParallelism.light,
            ggLog: ggLog,
            task: (index, _) => _passedBefore(nodes[index].directory),
          );

    // Check every repository. The checks of one repo do not need those of
    // another, so several repos are checked at the same time — the output
    // still lists them one after the other, in processing order. Running
    // checks keeps a machine busy: only a few repos do so at once, see
    // GgParallelism.heavy, and their test runs share the machine — a repo
    // that is the only one to be checked gets all of it. The first repo
    // that fails ends the run: the checks still running are stopped.
    final checks = gg.TaskSlots.heavy();
    final committed = await gg.runInParallel<bool>(
      count: nodes.length,
      maxParallel: gg.GgParallelism.light,
      cancelOnError: true,
      ggLog: ggLog,
      task: (index, ggLog) async {
        final repoDir = nodes[index].directory;
        final repoName = path.basename(repoDir.path);
        ggLog('\n${cH1(repoName)}');
        try {
          Future<void> check() =>
              _ggCanCommit.exec(directory: repoDir, ggLog: ggLog, force: force);
          await (passedBefore[index] ? check() : checks.use(check));

          // A repo with nothing left to commit changes the closing message
          // from »can be committed« to »committed«. The answer is only
          // interesting for that message, so its log output is dropped.
          return await _ggDidCommit.get(directory: repoDir, ggLog: (_) {});
        } catch (e) {
          // The reason is printed once, right under the repo it belongs to.
          // The exception only ends the run. This is the failure itself, not
          // context around it, so it is red rather than dimmed — a wall of
          // gray hides the one thing the user has to read.
          ggLog(
            [cError('✗ Cannot commit'), cError(rmControls('$e'))].join('\n'),
          );
          ggLog(cAction('\nPlease fix the issues above.\n'));
          throw Exception(cError('Cannot commit.'));
        }
      },
    );
    final allCommitted = committed.every((isCommitted) => isCommitted);

    // All successful. Undimmed, like the summaries of `do commit` and
    // `did commit` — this is the answer the user ran the command for, not
    // context around it.
    ggLog(
      allCommitted
          ? '\nAll repos committed\n'
          : '\nAll repos can be committed\n',
    );
  }

  // ...........................................................................
  /// Whether the checks of [repoDir] passed for the state it is in. A state
  /// that cannot be read counts as not passed: the checks say why.
  Future<bool> _passedBefore(Directory repoDir) async {
    try {
      return await _ggState.readSuccess(
        directory: repoDir,
        key: canCommitStateKey,
        ggLog: (_) {}, // coverage:ignore-line
      );
    } catch (_) {
      return false;
    }
  }

  // Adds command line arguments
  void _addArgs() {
    argParser.addFlag(
      'force',
      abbr: 'f',
      negatable: false,
      help: 'Execute the checks even if they succeeded before.',
      defaultsTo: false,
    );
  }
}

/// Mock for [CanCommitCommand]
class MockCanCommitCommand extends MockDirCommand<void>
    implements CanCommitCommand {}
