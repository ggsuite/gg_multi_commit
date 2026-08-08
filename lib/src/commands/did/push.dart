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
import 'package:gg_multi_commit/src/commands/did/commit.dart';

/// Command to check if all repos in the ticket were pushed.
///
/// A push presupposes a commit, so `did commit` is checked first — the most
/// fundamental missing step is what the user is told about, with its own
/// suggestion (»Please run gg do commit«) instead of a misleading »not
/// pushed«.
class DidPushCommand extends DirCommand<void> {
  /// Creates a new did push command.
  DidPushCommand({
    required super.ggLog,
    super.name = 'push',
    super.description = 'Check if all ticket repos were pushed',
    gg.DidPush? ggDidPush,
    SortedProcessingList? sortedProcessingList,
    DidCommitCommand? didCommitCommand,
  }) : _ggDidPush = ggDidPush ?? gg.DidPush(ggLog: ggLog),
       _sortedProcessingList =
           sortedProcessingList ?? SortedProcessingList(ggLog: ggLog),
       _didCommitCommand = didCommitCommand ?? DidCommitCommand(ggLog: ggLog);

  /// gg command that checks whether a repository was pushed.
  final gg.DidPush _ggDidPush;

  /// Sorted processing list for repos.
  final SortedProcessingList _sortedProcessingList;

  /// Checked first: without commits there is nothing to push.
  final DidCommitCommand _didCommitCommand;

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

    // Without commits there is nothing to push — report that first, with
    // the commit suggestion.
    await _didCommitCommand.exec(directory: ticketDir, ggLog: ggLog);

    for (final node in nodes) {
      final repoDir = node.directory;
      final repoName = path.basename(repoDir.path);
      ggLog('\n${cH1(repoName)}');
      try {
        await _ggDidPush.exec(directory: repoDir, ggLog: ggLog);
      } catch (e) {
        ggLog(
          [
            cError('✗ $repoName was not pushed'),
            cDetail(rmControls('$e')),
          ].join('\n'),
        );
        rethrow;
      }
    }

    ggLog(cDetail('✓ All repos pushed'));
  }
}

/// Mock for [DidPushCommand]
class MockDidPushCommand extends MockDirCommand<void>
    implements DidPushCommand {}
