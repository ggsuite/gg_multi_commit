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

/// Command to check if all repos in the ticket were committed.
class DidCommitCommand extends DirCommand<void> {
  /// Creates a new did commit command.
  DidCommitCommand({
    required super.ggLog,
    super.name = 'commit',
    super.description = 'Check if all ticket repos were committed',
    gg.DidCommit? ggDidCommit,
    SortedProcessingList? sortedProcessingList,
  }) : _ggDidCommit = ggDidCommit ?? gg.DidCommit(ggLog: ggLog),
       _sortedProcessingList =
           sortedProcessingList ?? SortedProcessingList(ggLog: ggLog);

  /// gg command that checks whether a repository was committed.
  final gg.DidCommit _ggDidCommit;

  /// Sorted processing list for repos.
  final SortedProcessingList _sortedProcessingList;

  @override
  Future<void> exec({
    required Directory directory,
    required GgLog ggLog,
    Map<String, dynamic> options = const {},
  }) => get(directory: directory, ggLog: ggLog);

  @override
  Future<void> get({required Directory directory, required GgLog ggLog}) async {
    final String? ticketPath = WorkspaceUtils.detectTicketPath(
      path.absolute(directory.path),
    );
    if (ticketPath == null) {
      ggLog(cAction('Please run this command inside a ticket folder.'));
      throw Exception(cDetail('Not inside a ticket folder'));
    }

    final ticketDir = Directory(ticketPath);
    final nodes = await _sortedProcessingList.get(
      directory: ticketDir,
      ggLog: ggLog,
    );

    if (nodes.isEmpty) {
      ggLog(cWarn('⚠️ No repos in this ticket'));
      return;
    }

    for (final node in nodes) {
      final repoDir = node.directory;
      final repoName = path.basename(repoDir.path);
      ggLog('\n${cH1(repoName)}');
      try {
        await _ggDidCommit.exec(directory: repoDir, ggLog: ggLog);
      } catch (e) {
        ggLog(
          [
            cError('✗ $repoName was not committed'),
            cDetail(rmControls('$e')),
          ].join('\n'),
        );
        rethrow;
      }
    }

    ggLog('\nAll repos committed\n');
  }
}

/// Mock for [DidCommitCommand]
class MockDidCommitCommand extends MockDirCommand<void>
    implements DidCommitCommand {}
