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

/// Command to check if all repos in the ticket can be committed.
class CanCommitCommand extends DirCommand<void> {
  /// Constructor
  CanCommitCommand({
    required super.ggLog,
    super.name = 'commit',
    super.description = 'Check if all ticket repos can be committed',
    gg.CanCommit? ggCanCommit,
    gg.DidCommit? ggDidCommit,
    SortedProcessingList? sortedProcessingList,
  }) : _ggCanCommit = ggCanCommit ?? gg.CanCommit(ggLog: ggLog),
       _ggDidCommit = ggDidCommit ?? gg.DidCommit(ggLog: ggLog),
       _sortedProcessingList =
           sortedProcessingList ?? SortedProcessingList(ggLog: ggLog);

  /// Instance of gg CanCommit
  final gg.CanCommit _ggCanCommit;

  /// Tells whether a repo is already committed — decides the final message.
  final gg.DidCommit _ggDidCommit;

  /// Sorted processing list for repos
  final SortedProcessingList _sortedProcessingList;

  @override
  Future<void> exec({
    required Directory directory,
    required GgLog ggLog,
    Map<String, dynamic> options = const {},
  }) => get(directory: directory, ggLog: ggLog);

  @override
  Future<void> get({required Directory directory, required GgLog ggLog}) async {
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

    // Iterate over each repository and check if it can be committed
    var allCommitted = true;
    for (final node in nodes) {
      final repoDir = node.directory;
      final repoName = path.basename(repoDir.path);
      ggLog('\n${cH1(repoName)}');
      try {
        await _ggCanCommit.exec(directory: repoDir, ggLog: ggLog);

        // A repo with nothing left to commit changes the closing message
        // from »can be committed« to »committed«. The answer is only
        // interesting for that message, so its log output is dropped.
        if (allCommitted) {
          allCommitted = await _ggDidCommit.get(
            directory: repoDir,
            ggLog: (_) {},
          );
        }
      } catch (e) {
        // The reason is printed once, right under the repo it belongs to.
        // The exception only ends the run. This is the failure itself, not
        // context around it, so it is red rather than dimmed — a wall of gray
        // hides the one thing the user has to read.
        ggLog([cError('✗ Cannot commit'), cError(rmControls('$e'))].join('\n'));
        ggLog(cAction('\nPlease fix the issues above.\n'));
        throw Exception(cError('Cannot commit.'));
      }
    }

    // All successful. Undimmed, like the summaries of `do commit` and
    // `did commit` — this is the answer the user ran the command for, not
    // context around it.
    ggLog(
      allCommitted
          ? '\nAll repos committed\n'
          : '\nAll repos can be committed\n',
    );
  }
}

/// Mock for [CanCommitCommand]
class MockCanCommitCommand extends MockDirCommand<void>
    implements CanCommitCommand {}
