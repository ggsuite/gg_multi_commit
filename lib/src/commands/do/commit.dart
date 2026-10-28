// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_args/gg_args.dart';
import 'package:gg_changelog/gg_changelog.dart' as cl;
import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_git/gg_git.dart' show IsCommitted;
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
    TicketLocalizer? ticketLocalizer,
    gg.DidCommit? ggDidCommit,
    gg.EditText? editText,
    gg.HasTerminal? hasTerminal,
    gg.EnsurePublishConfigIgnored? ensureIgnored,
    IsCommitted? isCommitted,
  }) : _ggDoCommit = ggDoCommit ?? gg.DoCommit(ggLog: ggLog),
       _sortedProcessingList =
           sortedProcessingList ?? SortedProcessingList(ggLog: ggLog),
       _ticketLocalizer = ticketLocalizer ?? TicketLocalizer(ggLog: ggLog),
       _editMessage = editMessage ?? _defaultEditMessage,
       _ggDidCommit = ggDidCommit ?? gg.DidCommit(ggLog: ggLog),
       _editText = editText ?? gg.defaultEditText,
       _hasTerminal = hasTerminal ?? gg.stdioHasTerminal,
       _ensureIgnored =
           ensureIgnored ?? gg.EnsurePublishConfigIgnored(ggLog: ggLog),
       _isGitCommitted = isCommitted ?? IsCommitted(ggLog: ggLog) {
    _addArgs();
  }

  String? get _messageOption => argResults?['message'] as String?;

  /// Instance of gg DoCommit to perform the commit action
  final gg.DoCommit _ggDoCommit;

  /// Sorted processing of repositories within a ticket
  final SortedProcessingList _sortedProcessingList;

  /// Opens an interactive editor for the commit message.
  final EditMessage _editMessage;

  /// Localizes references the user added by hand before committing.
  final TicketLocalizer _ticketLocalizer;

  /// Tells whether a repo is committed already — it then needs no message.
  final gg.DidCommit _ggDidCommit;

  /// Opens the messages of all repos as one sheet in the editor.
  final gg.EditText _editText;

  /// Whether stdin and stdout are a terminal — else nobody can answer.
  final gg.HasTerminal _hasTerminal;

  /// Lists the publish config in a repo's `.gitignore` before anything is
  /// committed or written into it.
  final gg.EnsurePublishConfigIgnored _ensureIgnored;

  /// Tells whether a repo has uncommitted changes — only then a commit is
  /// made, and recorded.
  final IsCommitted _isGitCommitted;

  @override
  Future<void> exec({
    required Directory directory,
    required GgLog ggLog,
    String? message,
    cl.LogType? logType,
    bool? updateChangeLog,
    bool? force,
    bool? interactive,
    Map<String, dynamic> options = const {},
  }) => get(
    directory: directory,
    ggLog: ggLog,
    message: message,
    logType: logType,
    updateChangeLog: updateChangeLog,
    force: force,
    interactive: interactive,
  );

  @override
  Future<void> get({
    required Directory directory,
    required GgLog ggLog,
    String? message,
    cl.LogType? logType,
    bool? updateChangeLog,
    bool? force,
    bool? interactive,
  }) async {
    ggLog(cH1('\nCommitting ...'));

    message ??= _messageOption;
    force ??= argResults?['force'] as bool? ?? false;
    interactive ??= !(argResults?['no-interactive'] as bool? ?? false);

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

    // Hand-added deps are localized; only gg's own files are committed here.
    await _ticketLocalizer.localizeUnlocalized(
      ticketDir: ticketDir,
      repos: nodes,
      ggLog: ggLog,
    );

    // A repo whose publish_config.json proposes its own message starts with
    // it; every other repo with the ticket description.
    final configs = <String, gg.RepoPublishConfig>{
      for (final node in nodes)
        path.basename(node.directory.path): loadTicketRepoPublishFiles(
          repoDir: node.directory,
          ticketDir: ticketDir,
        ).config,
    };

    final explicit = message?.trim() ?? '';
    final description = readTicketDescription(ticketDir) ?? '';

    // Without -m the messages of all repos are edited at once, on one sheet
    // in the editor. Without an editor they are asked one by one, and
    // without anybody to ask (--no-interactive, no terminal) the defaults
    // are taken.
    final asks = interactive && _hasTerminal();
    final shown = explicit.isEmpty && asks
        ? await _sheetEntries(
            nodes: nodes,
            configs: configs,
            description: description,
          )
        : null;
    final sheet = shown == null
        ? null
        : await _editSheet(ticketDir: ticketDir, entries: shown);

    // The one message every repo without its own shares: -m, or the ticket
    // description — offered in the same editor `do publish` uses for its
    // merge messages when there is no sheet, so it can be adjusted before it
    // is applied to every repo.
    final String? shared;
    if (explicit.isNotEmpty) {
      shared = explicit;
    } else if (sheet != null || !asks) {
      shared = description.isEmpty ? null : description;
    } else if (configs.values.every((c) => c.nextCommitMessage != null)) {
      shared = null;
    } else {
      shared = await _resolveMessage(description);
    }

    // Iterate over each repository and perform the commit
    final failedRepos = <String>[];
    for (final node in nodes) {
      final repoDir = node.directory;
      final repoName = path.basename(repoDir.path);
      ggLog('\n${cH1(repoName)}');
      final proposal = configs[repoName]!.nextCommitMessage;
      final edited = sheet?[repoName];
      gg.CommitMessage? resolved;
      var hidden = false;
      var committed = false;
      try {
        if (explicit.isNotEmpty) {
          resolved = proposal == null ? null : gg.CommitMessage.parse(explicit);
        } else if (sheet != null) {
          // A repo missing on the sheet has nothing to commit.
          final edit = edited?.commitMessage;
          resolved = edit == null || edit.firstLine.isEmpty ? null : edit;
        } else if (proposal != null) {
          resolved = asks ? await _resolveMessageFor(proposal) : proposal;
        }

        // The publish config is hidden before the commit, so `git add .`
        // never sweeps it into the user's commit.
        if (resolved != null || edited != null) {
          hidden = await _hidePublishConfig(repoDir: repoDir, ggLog: ggLog);
        }
        final hasChanges = await _hasChanges(repoDir);
        await _ggDoCommit.exec(
          directory: repoDir,
          ggLog: ggLog,
          message: resolved?.text ?? shared,
          logType: logType,
          updateChangeLog: updateChangeLog,
          force: force,
        );
        committed = hasChanges;
      } catch (e) {
        ggLog(
          [cDetail('✗ Failed to commit'), cError(rmControls('$e'))].join('\n'),
        );
        failedRepos.add(repoName);
      }

      // Only a commit that actually happened is recorded — a failed one, or
      // a repo with nothing to commit, must not enter the history the
      // pull-request description is built from. What the user changed on
      // the sheet is kept also when the commit failed, so a rerun offers it
      // again.
      await _record(
        repoDir: repoDir,
        config: configs[repoName]!,
        committed: committed ? resolved : null,
        shown: shown?[repoName],
        edited: edited,
        withMergeMessage: hidden,
        ggLog: ggLog,
      );
    }

    // Summarize the results
    if (failedRepos.isEmpty) {
      ggLog('\nAll repos committed\n');
      return;
    }

    ggLog(cAction('\nPlease fix the issues above.\n'));
    throw Exception(cDetail('Failed to commit.'));
  }

  /// The commit message and the merge message of every repo that has
  /// something to commit, as they are put on the sheet, by repo name.
  Future<Map<String, gg.MessageSheetEntry>> _sheetEntries({
    required List<Node> nodes,
    required Map<String, gg.RepoPublishConfig> configs,
    required String description,
  }) async {
    final entries = <String, gg.MessageSheetEntry>{};
    for (final node in nodes) {
      final repoName = path.basename(node.directory.path);
      if (await _isCommitted(node.directory)) {
        continue;
      }
      entries[repoName] = gg.commitSheetEntry(
        repo: repoName,
        config: configs[repoName],
        description: description,
      );
    }
    return entries;
  }

  /// Shows [entries] on one sheet in the editor and returns the edited
  /// entries by repo name — none when no repo needs a message. Null when no
  /// editor can be opened.
  Future<Map<String, gg.MessageSheetEntry>?> _editSheet({
    required Directory ticketDir,
    required Map<String, gg.MessageSheetEntry> entries,
  }) async {
    if (entries.isEmpty) {
      return const {};
    }

    final edited = await gg.MessageSheet(entries: [...entries.values]).edit(
      title: 'gg do commit',
      fileName: '${path.basename(ticketDir.path)}_commit.jsonc',
      editText: _editText,
    );
    return edited == null
        ? null
        : {for (final entry in edited) entry.repo: entry};
  }

  /// Whether [repoDir] has nothing left to commit. Unknown counts as no: the
  /// repo is then shown on the sheet, and the commit decides.
  Future<bool> _isCommitted(Directory repoDir) async {
    try {
      return await _ggDidCommit.get(directory: repoDir, ggLog: (_) {});
    } catch (_) {
      return false;
    }
  }

  /// Whether a commit of [repoDir] takes something — then a successful
  /// commit made one. Unknown counts as no: nothing is recorded that may not
  /// have happened.
  Future<bool> _hasChanges(Directory repoDir) async {
    try {
      return !await _isGitCommitted.get(directory: repoDir, ggLog: (_) {});
    } catch (_) {
      return false;
    }
  }

  /// Lists the publish config in the `.gitignore` of [repoDir], so it never
  /// shows up as a change. Returns false, with a warning, when that failed:
  /// the commit is still made and recorded, only the merge message is not —
  /// the review asks it again.
  Future<bool> _hidePublishConfig({
    required Directory repoDir,
    required GgLog ggLog,
  }) async {
    try {
      await _ensureIgnored.ensure(directory: repoDir);
      return true;
    } catch (e) {
      ggLog(
        cWarn(
          '⚠️ Could not hide publish_config.json from git, the merge message '
          'is not recorded: ${rmControls('$e')}',
        ),
      );
      return false;
    }
  }

  /// Writes the answers of [repoDir] into its `publish_config.json` — see
  /// [gg.CommitSheetAnswers.withCommitAnswers]. Never fails the run: the
  /// commit is made already.
  Future<void> _record({
    required Directory repoDir,
    required gg.RepoPublishConfig config,
    required gg.CommitMessage? committed,
    required gg.MessageSheetEntry? shown,
    required gg.MessageSheetEntry? edited,
    required bool withMergeMessage,
    required GgLog ggLog,
  }) async {
    final updated = config.withCommitAnswers(
      committed: committed,
      shown: shown,
      edited: edited,
      withMergeMessage: withMergeMessage,
    );
    if (identical(updated, config)) {
      return;
    }
    try {
      await updated.save(file: gg.repoPublishConfigFile(repoDir));
    } catch (e) {
      ggLog(cWarn('⚠️ Could not record the messages: ${rmControls('$e')}'));
    }
  }

  /// Returns the commit message every repository of the ticket shares when
  /// there is no sheet and no `-m`: the ticket description seeds the
  /// interactive message editor — the same prompt `do publish` offers for
  /// merge messages — and the edited text wins; clearing it falls back to the
  /// description.
  ///
  /// Returns `null` when nothing could be resolved (no description and an
  /// empty edit). `gg do commit` then reports the missing message itself, but
  /// only for repos that actually have something to commit — so a ticket that
  /// is already committed still passes without a message.
  Future<String?> _resolveMessage(String description) async {
    final edited = (await _editMessage(description) ?? '').trim();
    final resolved = edited.isEmpty ? description : edited;
    return resolved.isEmpty ? null : resolved;
  }

  /// Returns the commit message of a repository whose `publish_config.json`
  /// carries a [proposal], when there is no sheet and no `-m`: the proposal
  /// pre-fills the editor, and clearing it falls back to the proposal. The
  /// first line may be of any length.
  Future<gg.CommitMessage> _resolveMessageFor(gg.CommitMessage proposal) async {
    final edited = (await _editMessage(proposal.text) ?? '').trim();
    return gg.CommitMessage.parse(edited.isEmpty ? proposal.text : edited);
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

    argParser.addFlag(
      'force',
      abbr: 'f',
      help: 'Commit without running checks (analyze/format/tests).',
      defaultsTo: false,
      negatable: true,
    );

    argParser.addFlag(
      'no-interactive',
      help:
          'Ask nothing: take the proposed commit messages, else the ticket '
          'description.',
      defaultsTo: false,
      negatable: false,
    );
  }
}

/// Mock for [DoCommitCommand]
class MockDoCommitCommand extends MockDirCommand<void>
    implements DoCommitCommand {}
