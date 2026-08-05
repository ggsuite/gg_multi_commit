// @license
// Copyright (c) 2025 Göran Hegenberg. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_args/gg_args.dart';
import 'package:gg_changelog/gg_changelog.dart' as cl;
import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_local_package_dependencies/gg_local_package_dependencies.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_one/gg_one.dart' as gg;
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:path/path.dart' as path;

import 'package:gg_multi_core/gg_multi_core.dart';

/// Command to commit changes across all repositories in the current ticket.
class DoCommitCommand extends DirCommand<void> {
  /// Constructor
  DoCommitCommand({
    required super.ggLog,
    super.name = 'commit',
    super.description = 'Commit changes in all ticket repos',
    gg.CanCommit? ggCanCommit,
    gg.DoCommit? ggDoCommit,
    SortedProcessingList? sortedProcessingList,
    EditMessage? editMessage,
  }) : _ggDoCommit = ggDoCommit ?? gg.DoCommit(ggLog: ggLog),
       _sortedProcessingList =
           sortedProcessingList ?? SortedProcessingList(ggLog: ggLog),
       _editMessage = editMessage ?? _defaultEditMessage {
    _addArgs();
  }

  String? get _messageOption => argResults?['message'] as String?;

  /// Instance of gg DoCommit to perform the commit action
  final gg.DoCommit _ggDoCommit;

  /// Sorted processing of repositories within a ticket
  final SortedProcessingList _sortedProcessingList;

  /// Opens an interactive editor for the commit message.
  final EditMessage _editMessage;

  @override
  Future<void> exec({
    required Directory directory,
    required GgLog ggLog,
    String? message,
    cl.LogType? logType,
    bool? updateChangeLog,
  }) => get(
    directory: directory,
    ggLog: ggLog,
    message: message,
    logType: logType,
    updateChangeLog: updateChangeLog,
  );

  @override
  Future<void> get({
    required Directory directory,
    required GgLog ggLog,
    String? message,
    cl.LogType? logType,
    bool? updateChangeLog,
  }) async {
    ggLog(cH1('\nCommitting ...'));

    message ??= _messageOption;

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

    // Without an explicit -m the ticket description becomes the commit
    // message — offered in the same editor `do publish` uses for its merge
    // messages, so it can be adjusted before it is applied to every repo.
    message = await _resolveMessage(message: message, ticketDir: ticketDir);

    // Iterate over each repository and perform the commit
    final failedRepos = <String>[];
    for (final node in nodes) {
      final repoDir = node.directory;
      final repoName = path.basename(repoDir.path);
      ggLog('\n${cH1(repoName)}');
      try {
        await _ggDoCommit.exec(
          directory: repoDir,
          ggLog: ggLog,
          message: message,
          logType: logType,
          updateChangeLog: updateChangeLog,
          force: false,
        );
      } catch (e) {
        ggLog(
          [cDetail('✗ Failed to commit'), cError(rmControls('$e'))].join('\n'),
        );
        failedRepos.add(repoName);
      }
    }

    // Summarize the results
    if (failedRepos.isEmpty) {
      ggLog('\nAll repos committed\n');
      return;
    }

    ggLog(cAction('\nPlease fix the issues above.\n'));
    throw Exception(cDetail('Failed to commit.'));
  }

  /// Returns the commit message used for every repository of the ticket.
  ///
  /// An explicit [message] (`-m`) is taken as-is. Without one the ticket
  /// description seeds the interactive message editor — the same prompt
  /// `do publish` offers for merge messages — and the edited text wins;
  /// clearing it falls back to the description.
  ///
  /// Returns `null` when nothing could be resolved (no `-m`, no description
  /// and an empty edit). `gg do commit` then reports the missing message
  /// itself, but only for repos that actually have something to commit — so a
  /// ticket that is already committed still passes without a message.
  Future<String?> _resolveMessage({
    required String? message,
    required Directory ticketDir,
  }) async {
    final explicit = message?.trim();
    if (explicit != null && explicit.isNotEmpty) {
      return explicit;
    }

    final description = readTicketDescription(ticketDir) ?? '';
    final edited = (await _editMessage(description) ?? '').trim();
    final resolved = edited.isEmpty ? description : edited;
    return resolved.isEmpty ? null : resolved;
  }

  /// Opens the shared message editor for the commit message.
  // coverage:ignore-start
  static Future<String?> _defaultEditMessage(String initialMessage) =>
      editMessage(
        initialMessage,
        prompt: 'Edit commit message',
        subject: 'the commit message prompt',
        hint: 'pass -m <message>',
      );
  // coverage:ignore-end

  // Adds command line arguments
  void _addArgs() {
    argParser.addFlag(
      'log',
      abbr: 'l',
      help: 'Do not add message to CHANGELOG.md.',
      negatable: true,
      defaultsTo: true,
    );

    argParser.addOption(
      'message',
      abbr: 'm',
      help: 'The commit message and log entry',
    );
  }
}

/// Mock for [DoCommitCommand]
class MockDoCommitCommand extends MockDirCommand<void>
    implements DoCommitCommand {}
