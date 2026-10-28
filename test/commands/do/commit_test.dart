// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:gg_git/gg_git.dart' show IsCommitted;
import 'package:gg_multi_commit/src/commands/do/commit.dart';
import 'package:gg_one/gg_one.dart' as gg;
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';
import 'package:gg_multi_core/gg_multi_core.dart';

import '../../test_helpers.dart';

class MockGgDoCommit extends Mock implements gg.DoCommit {}

class FakeDirectory extends Fake implements Directory {}

class MockGgDidCommit extends Mock implements gg.DidCommit {}

class MockEnsurePublishConfigIgnored extends Mock
    implements gg.EnsurePublishConfigIgnored {}

class MockIsCommitted extends Mock implements IsCommitted {}

/// No editor: the messages are asked one by one, like before the sheet.
Future<String?> noEditor({
  required String prompt,
  required String text,
  required String fileName,
}) async => null;

void main() {
  late Directory tempDir;
  late Directory ticketsDir;
  late Directory ticketDir;
  final messages = <String>[];
  final committedMessages = <String?>[];
  final capturedInitials = <String>[];
  final committedForces = <bool?>[];
  late MockEnsurePublishConfigIgnored ensureIgnored;
  late MockIsCommitted isCommitted;

  setUpAll(() {
    registerFallbackValue(FakeDirectory());
  });

  void ggLog(String msg) => messages.add(rmControls(msg));

  Directory repo(String name) => Directory(path.join(ticketDir.path, name));

  /// A [gg.DoCommit] stub recording the message it was called with, then
  /// running [answer] for the committed repo.
  MockGgDoCommit stubDoCommit([
    FutureOr<void> Function(Directory repo)? answer,
  ]) {
    final mock = MockGgDoCommit();
    when(
      () => mock.exec(
        directory: any(named: 'directory'),
        ggLog: any(named: 'ggLog'),
        message: any(named: 'message'),
        logType: any(named: 'logType'),
        updateChangeLog: any(named: 'updateChangeLog'),
        force: any(named: 'force'),
      ),
    ).thenAnswer((invocation) async {
      committedMessages.add(invocation.namedArguments[#message] as String?);
      committedForces.add(invocation.namedArguments[#force] as bool?);
      await answer?.call(invocation.namedArguments[#directory] as Directory);
    });
    return mock;
  }

  /// A [gg.DoCommit] stub failing for the repo named [failing].
  MockGgDoCommit failingDoCommit(String failing) => stubDoCommit((repo) {
    if (path.basename(repo.path) == failing) {
      throw Exception('Failed to commit $failing');
    }
  });

  /// An [EditMessage] stub recording what it was shown and returning [result]
  /// (the unchanged initial message when [result] is null).
  EditMessage editMessage([String? result]) => (initial) async {
    capturedInitials.add(initial);
    return result ?? initial;
  };

  /// The command under test: no editor, a terminal, every repo has changes
  /// and the `.gitignore` already hides the publish config — unless the
  /// test says otherwise.
  DoCommitCommand command({
    gg.DoCommit? ggDoCommit,
    TicketLocalizer? ticketLocalizer,
    EditMessage? edit,
    gg.EditText editText = noEditor,
    bool hasTerminal = true,
    gg.DidCommit? ggDidCommit,
  }) => DoCommitCommand(
    ggLog: ggLog,
    editText: editText,
    hasTerminal: () => hasTerminal,
    ggDoCommit: ggDoCommit,
    ticketLocalizer: ticketLocalizer,
    editMessage: edit,
    ggDidCommit: ggDidCommit,
    ensureIgnored: ensureIgnored,
    isCommitted: isCommitted,
  );

  /// Lets [isCommitted] answer [answer] for each repo by its name.
  void stubIsCommitted(FutureOr<bool> Function(String repo) answer) =>
      when(
        () => isCommitted.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer(
        (invocation) async => answer(
          path.basename(
            (invocation.namedArguments[#directory] as Directory).path,
          ),
        ),
      );

  /// Runs [cmd] in [dir] with [args].
  Future<void> runCommand(
    DoCommitCommand cmd,
    Directory dir, [
    List<String> args = const [],
  ]) => (CommandRunner<void>(
    'test',
    'do commit ticket',
  )..addCommand(cmd)).run(['commit', '--input', dir.path, ...args]);

  setUp(() {
    messages.clear();
    committedMessages.clear();
    capturedInitials.clear();
    committedForces.clear();
    ensureIgnored = MockEnsurePublishConfigIgnored();
    when(() => ensureIgnored.ensure(directory: any(named: 'directory')))
        .thenAnswer((_) async => false);
    isCommitted = MockIsCommitted();
    stubIsCommitted((_) => false);
    tempDir = Directory.systemTemp.createTempSync('do_commit_ticket_test_');
    ticketsDir = Directory(path.join(tempDir.path, 'tickets'))..createSync();
    ticketDir = Directory(path.join(ticketsDir.path, 'TICKC'))..createSync();
    // Create repositories with pubspec.yaml for SortedProcessingList
    final aDir = Directory(path.join(ticketDir.path, 'A'))..createSync();
    File(path.join(aDir.path, 'pubspec.yaml')).writeAsStringSync('name: A');
    final bDir = Directory(path.join(ticketDir.path, 'B'))..createSync();
    File(path.join(bDir.path, 'pubspec.yaml')).writeAsStringSync('name: B');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('DoCommitCommand (ticket-wide)', () {
    test('fails outside any ticket folder', () async {
      // With the real collaborators: it stops before any of them is used.
      final realCommand = DoCommitCommand(
        ggLog: ggLog,
        editText: noEditor,
        hasTerminal: () => true,
      );
      await expectLater(
        () => runCommand(realCommand, tempDir),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            'Exception: Not inside a ticket folder',
          ),
        ),
      );
      expect(
        messages,
        contains('Please run this command inside a ticket folder.'),
      );
    });

    test('logs when there are no repositories', () async {
      final emptyTicket = Directory(path.join(ticketsDir.path, 'EMPTY'))
        ..createSync();
      await runCommand(command(), emptyTicket);
      expect(messages, contains('⚠️ No repos in this ticket'));
    });

    test('commits all repos successfully', () async {
      await runCommand(
        command(
          ticketLocalizer: inSyncTicketLocalizer(),
          ggDoCommit: stubDoCommit(),
        ),
        ticketDir,
        ['--message', 'Test commit'],
      );
      expect(messages[1].split('\n'), ['', 'A']);
    });

    test('localizes a hand-added dependency and commits gg\'s part of it '
        'before the user\'s commit', () async {
      final sampleTicket = await createSampleTicket(tempDir);
      final a = sampleRepo(sampleTicket, 'a');
      await addDependency(a, 'b');

      // What each repo looked like when the user's commit was asked for.
      final seen = <String, Map<String, List<String>>>{};
      final ggDoCommit = stubDoCommit((repo) async {
        seen[path.basename(repo.path)] = {
          'commits': await commitSubjects(repo),
          'dirty': await dirtyFiles(repo),
        };
      });

      await runCommand(command(ggDoCommit: ggDoCommit), sampleTicket, [
        '--message',
        'Use b',
      ]);

      expect(messages, contains('✓ Localized the references of a'));
      expect(seen['a'], {
        'commits': ['#gg: changed references to path'],
        'dirty': ['pubspec.yaml'],
      });
      expect(seen['b'], {'commits': <String>[], 'dirty': <String>[]});
    });

    test('commits and warns once when a repo is missing between the '
        'ticket repos', () async {
      // a reaches its ticket sibling b only through the ocean's c.
      final sampleTicket = await createSampleTicket(tempDir);
      final a = sampleRepo(sampleTicket, 'a');
      await addDependency(a, 'c');
      addOceanRepo(tempDir, 'c', 'b');

      await runCommand(command(ggDoCommit: stubDoCommit()), sampleTicket, [
        '-m',
        'Use c',
      ]);

      expect(
        messages.where((m) => m.contains('Repos between the ticket repos')),
        hasLength(1),
      );
      expect(messages, contains('Run gg do add c to add them.\n'));
      expect(messages.last, '\nAll repos committed\n');
      expect(committedMessages, ['Use c', 'Use c']);
    });

    test('aborts on first repo that fails', () async {
      await expectLater(
        () => runCommand(
          command(
            ticketLocalizer: inSyncTicketLocalizer(),
            ggDoCommit: failingDoCommit('B'),
          ),
          ticketDir,
          ['--message', 'Test commit'],
        ),
        throwsA(isA<Exception>()),
      );
      expect(messages, [
        '\nCommitting ...',
        '\nA',
        '\nB',
        // The reason is printed once, under the repo it belongs to.
        '✗ Failed to commit\nException: Failed to commit B',
        '\nPlease fix the issues above.\n',
      ]);
    });

    test('commits no repo when the localization fails', () async {
      await expectLater(
        () => runCommand(
          command(
            ticketLocalizer: failingTicketLocalizer('Cannot localize A.'),
            ggDoCommit: stubDoCommit(),
            edit: editMessage(),
          ),
          ticketDir,
        ),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            'Exception: Cannot localize A.',
          ),
        ),
      );

      // Stopped before the message was asked for or any repo was committed.
      expect(capturedInitials, isEmpty);
      expect(committedMessages, isEmpty);
      expect(messages, ['\nCommitting ...']);
    });
  });

  group('commit message default from ticket.json', () {
    /// Runs `do commit` on [ticketDir], optionally with `-m` [message].
    Future<void> run({
      String? message,
      EditMessage? edit,
      List<String> args = const [],
    }) => runCommand(
      command(
        ticketLocalizer: inSyncTicketLocalizer(),
        ggDoCommit: stubDoCommit(),
        edit: edit ?? editMessage(),
      ),
      ticketDir,
      [
        if (message != null) ...['--message', message],
        ...args,
      ],
    );

    test('passes --force on to every repo', () async {
      // Without the flag every repo runs its checks.
      await run(message: 'Msg');
      expect(committedForces, [false, false]);

      committedForces.clear();
      await run(message: 'Msg', args: ['--force']);
      expect(committedForces, [true, true]);

      committedForces.clear();
      await run(message: 'Msg', args: ['-f']);
      expect(committedForces, [true, true]);
    });

    test('reuses the ticket description when no message is given', () async {
      File(path.join(ticketDir.path, ticketJsonFileName))
          .writeAsStringSync('{"description": "Ticket desc"}');

      await run();

      // The description pre-filled the editor and reached every repo.
      expect(capturedInitials, ['Ticket desc']);
      expect(committedMessages, ['Ticket desc', 'Ticket desc']);
    });

    test('commits the edited message', () async {
      File(path.join(ticketDir.path, ticketJsonFileName))
          .writeAsStringSync('{"description": "Ticket desc"}');

      await run(edit: editMessage('Edited message'));

      expect(committedMessages, ['Edited message', 'Edited message']);
    });

    test('falls back to the description when the edit is cleared', () async {
      File(path.join(ticketDir.path, ticketJsonFileName))
          .writeAsStringSync('{"description": "Ticket desc"}');

      await run(edit: editMessage('   '));

      expect(committedMessages, ['Ticket desc', 'Ticket desc']);
    });

    test('does not offer an edit when -m is given', () async {
      File(path.join(ticketDir.path, ticketJsonFileName))
          .writeAsStringSync('{"description": "Ticket desc"}');

      await run(message: '  Explicit message  ');

      expect(capturedInitials, isEmpty);
      expect(committedMessages, ['Explicit message', 'Explicit message']);
    });

    test(
      'offers an empty edit when there is no ticket.json description',
      () async {
        await run();

        expect(capturedInitials, ['']);
        // Neither -m nor a description nor an edit: gg do commit decides, and
        // only complains about repos that actually have something to commit.
        expect(committedMessages, [null, null]);
      },
    );

    test('passes no message when the edit stays empty', () async {
      await run(edit: editMessage('  '));

      expect(committedMessages, [null, null]);
    });

    test('does not offer an edit when the ticket has no repos', () async {
      final emptyTicket = Directory(path.join(ticketsDir.path, 'EMPTY'))
        ..createSync();
      File(path.join(emptyTicket.path, ticketJsonFileName))
          .writeAsStringSync('{"description": "Ticket desc"}');

      await runCommand(
        command(
          ticketLocalizer: inSyncTicketLocalizer(),
          ggDoCommit: stubDoCommit(),
          edit: editMessage(),
        ),
        emptyTicket,
      );

      expect(messages, contains('⚠️ No repos in this ticket'));
      expect(capturedInitials, isEmpty);
    });

    test('exec forwards the message without offering an edit', () async {
      await command(
        ticketLocalizer: inSyncTicketLocalizer(),
        ggDoCommit: stubDoCommit(),
        edit: editMessage(),
      ).exec(directory: ticketDir, ggLog: ggLog, message: 'From code');

      expect(capturedInitials, isEmpty);
      expect(committedMessages, ['From code', 'From code']);
    });
  });

  group('nextCommitMessage from publish_config.json', () {
    Future<void> proposeIn(
      String name, {
      required String firstLine,
      List<String>? details,
    }) => gg.RepoPublishConfig(
      nextCommitMessage: gg.CommitMessage(
        firstLine: firstLine,
        details: details,
      ),
    ).save(file: gg.repoPublishConfigFile(repo(name)));

    Future<void> run({
      String? message,
      EditMessage? edit,
      gg.DoCommit? ggDoCommit,
    }) => runCommand(
      command(
        ticketLocalizer: inSyncTicketLocalizer(),
        ggDoCommit: ggDoCommit ?? stubDoCommit(),
        edit: edit ?? editMessage(),
      ),
      ticketDir,
      [
        if (message != null) ...['--message', message],
      ],
    );

    test('proposes the per-repo message and shares the rest', () async {
      // Only A carries a proposal — B keeps the one shared ticket message.
      await proposeIn('A', firstLine: 'Adapt message.json');
      File(path.join(ticketDir.path, ticketJsonFileName))
          .writeAsStringSync('{"description": "Ticket desc"}');

      await run();

      // The ticket-wide editor ran once, A's own editor once — pre-filled
      // with its own proposal, never with another repo's.
      expect(capturedInitials, ['Ticket desc', 'Adapt message.json']);
      expect(committedMessages, ['Adapt message.json', 'Ticket desc']);
    });

    test('asks no shared message when every repo proposes one', () async {
      await proposeIn('A', firstLine: 'A change');
      await proposeIn('B', firstLine: 'B change');

      await run();

      expect(capturedInitials, ['A change', 'B change']);
      expect(committedMessages, ['A change', 'B change']);
    });

    test('commits the details as the message body', () async {
      await proposeIn(
        'A',
        firstLine: 'Adapt message.json',
        details: ['Detail 0', 'Detail 1'],
      );
      await proposeIn('B', firstLine: 'B change');

      await run();

      expect(
        committedMessages.first,
        'Adapt message.json\n\nDetail 0\nDetail 1',
      );
    });

    test('records the commit and keeps the proposal', () async {
      await proposeIn('A', firstLine: 'Adapt message.json');
      await proposeIn('B', firstLine: 'B change');

      await run();

      final config = gg.RepoPublishConfig.tryLoad(repo('A'))!;
      expect(config.commits.single.firstLine, 'Adapt message.json');
      // The proposal is not consumed — the AI keeps it up to date.
      expect(config.nextCommitMessage?.firstLine, 'Adapt message.json');
      // The publish config was hidden before the commit.
      verify(() => ensureIgnored.ensure(directory: any(named: 'directory')))
          .called(2);
    });

    test('records no duplicate on a second identical run', () async {
      await proposeIn('A', firstLine: 'Adapt message.json');
      await proposeIn('B', firstLine: 'B change');

      await run();
      await run();

      expect(gg.RepoPublishConfig.tryLoad(repo('A'))!.commits, hasLength(1));
    });

    test('records nothing when the commit failed', () async {
      await proposeIn('A', firstLine: 'Adapt message.json');
      await proposeIn('B', firstLine: 'B change');

      await expectLater(
        () => run(ggDoCommit: failingDoCommit('A')),
        throwsA(isA<Exception>()),
      );

      expect(gg.RepoPublishConfig.tryLoad(repo('A'))!.commits, isEmpty);
      expect(gg.RepoPublishConfig.tryLoad(repo('B'))!.commits, hasLength(1));
    });

    test('records nothing when there was nothing to commit', () async {
      await proposeIn('A', firstLine: 'Adapt message.json');
      await proposeIn('B', firstLine: 'B change');
      stubIsCommitted((repo) => repo == 'A');

      await run();

      // gg do commit ran, but A had no changes: no commit was made.
      expect(committedMessages, ['Adapt message.json', 'B change']);
      expect(gg.RepoPublishConfig.tryLoad(repo('A'))!.commits, isEmpty);
      expect(gg.RepoPublishConfig.tryLoad(repo('B'))!.commits, hasLength(1));
    });

    test('records nothing when the changes cannot be read', () async {
      await proposeIn('A', firstLine: 'Adapt message.json');
      await proposeIn('B', firstLine: 'B change');
      stubIsCommitted((_) => throw Exception('no git'));

      await run();

      expect(gg.RepoPublishConfig.tryLoad(repo('A'))!.commits, isEmpty);
    });

    test('warns when the record cannot be written', () async {
      await proposeIn('A', firstLine: 'Adapt message.json');
      await proposeIn('B', firstLine: 'B change');
      // A directory where the file belongs makes the write fail.
      final file = gg.repoPublishConfigFile(repo('A'));
      final ggDoCommit = stubDoCommit((repoDir) {
        if (path.basename(repoDir.path) == 'A') {
          file.deleteSync();
          Directory(file.path).createSync();
        }
      });

      await run(ggDoCommit: ggDoCommit);

      expect(
        messages.join('\n'),
        contains('⚠️ Could not record the messages:'),
      );
      expect(messages.last, '\nAll repos committed\n');
    });

    test('accepts a long first line from the editor', () async {
      await proposeIn('A', firstLine: 'ok');
      await proposeIn('B', firstLine: 'B change');

      await run(edit: editMessage('a' * 200));

      expect(committedMessages.first, 'a' * 200);
      expect(
        gg.RepoPublishConfig.tryLoad(repo('A'))!.commits.single.firstLine,
        'a' * 200,
      );
    });

    test('accepts a -m with a long first line', () async {
      await proposeIn('A', firstLine: 'ok');
      await proposeIn('B', firstLine: 'B change');

      await run(message: 'a' * 200);

      expect(capturedInitials, isEmpty);
      expect(committedMessages, ['a' * 200, 'a' * 200]);
    });

    test('-m wins over the proposal', () async {
      await proposeIn('A', firstLine: 'proposed');
      await proposeIn('B', firstLine: 'B change');

      await run(message: 'From the flag');

      expect(capturedInitials, isEmpty);
      expect(committedMessages, ['From the flag', 'From the flag']);
    });

    test('falls back to the proposal when the edit is cleared', () async {
      await proposeIn('A', firstLine: 'proposed');
      await proposeIn('B', firstLine: 'B change');

      await run(edit: editMessage('   '));

      expect(committedMessages.first, 'proposed');
    });
  });

  group('message sheet', () {
    late List<String> sheets;
    late MockGgDidCommit didCommit;

    /// Lets [didCommit] answer [answer] for each repo by its name.
    void stubDidCommit(FutureOr<bool> Function(String repo) answer) =>
        when(
          () => didCommit.get(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        ).thenAnswer(
          (invocation) async => answer(
            path.basename(
              (invocation.namedArguments[#directory] as Directory).path,
            ),
          ),
        );

    setUp(() {
      sheets = [];
      didCommit = MockGgDidCommit();
      stubDidCommit((_) => false);
      File(path.join(ticketDir.path, ticketJsonFileName))
          .writeAsStringSync('{"description": "Ticket desc"}');
    });

    Future<void> run(
      String? Function(String text) answer, {
      List<String> args = const [],
      bool hasTerminal = true,
      gg.DoCommit? ggDoCommit,
    }) => runCommand(
      command(
        ticketLocalizer: inSyncTicketLocalizer(),
        ggDoCommit: ggDoCommit ?? stubDoCommit(),
        edit: editMessage(),
        ggDidCommit: didCommit,
        hasTerminal: hasTerminal,
        editText: ({required prompt, required text, required fileName}) async {
          expect(prompt, 'gg do commit');
          expect(fileName, 'TICKC_commit.jsonc');
          sheets.add(text);
          return answer(text);
        },
      ),
      ticketDir,
      args,
    );

    test('edits the commit and merge messages of all repos at once', () async {
      await gg.RepoPublishConfig(
        nextCommitMessage: gg.CommitMessage(firstLine: 'Proposed for B'),
      ).save(file: gg.repoPublishConfigFile(repo('B')));

      await run(
        (_) =>
            '{"A": {"commitMessage": ["Commit A", "Detail"], '
            '"mergeMessage": ["Merge A"]}, "B": {}}',
      );

      // No line editor was opened.
      expect(capturedInitials, isEmpty);
      expect(sheets.single, contains('"commitMessage": ["Ticket desc"]'));
      expect(sheets.single, contains('"commitMessage": ["Proposed for B"]'));
      expect(committedMessages, ['Commit A\n\nDetail', 'Proposed for B']);

      final a = gg.RepoPublishConfig.tryLoad(repo('A'))!;
      expect(a.mergeMessage, 'Merge A');
      expect(a.commits.single.text, 'Commit A\n\nDetail');
      final b = gg.RepoPublishConfig.tryLoad(repo('B'))!;
      // The default merge message was only confirmed: it is not frozen, so a
      // later change of the ticket description still reaches the review.
      expect(b.mergeMessage, isNull);
      expect(b.commits.single.firstLine, 'Proposed for B');
      verify(() => ensureIgnored.ensure(directory: any(named: 'directory')))
          .called(2);
    });

    test('records no unchanged default merge message', () async {
      await run((text) => text);

      final a = gg.RepoPublishConfig.tryLoad(repo('A'))!;
      expect(a.mergeMessage, isNull);
      expect(a.commits.single.firstLine, 'Ticket desc');
    });

    test('leaves out the repos that are committed already', () async {
      stubDidCommit((repo) => repo == 'A');

      await run((text) => text);

      expect(sheets.single, isNot(contains('"A"')));
      expect(committedMessages, ['Ticket desc', 'Ticket desc']);
      expect(gg.RepoPublishConfig.tryLoad(repo('A')), isNull);
      expect(gg.RepoPublishConfig.tryLoad(repo('B'))!.commits, hasLength(1));
    });

    test('records no commit for a repo with nothing to commit', () async {
      // gg's state is not written yet, but git has nothing to commit.
      stubIsCommitted((repo) => repo == 'A');

      await run((_) => '{"A": {"mergeMessage": ["Merge A"]}}');

      final a = gg.RepoPublishConfig.tryLoad(repo('A'))!;
      expect(a.commits, isEmpty);
      expect(a.mergeMessage, 'Merge A');
      expect(gg.RepoPublishConfig.tryLoad(repo('B'))!.commits, hasLength(1));
    });

    test('opens no sheet when every repo is committed', () async {
      stubDidCommit((_) => true);

      await run((text) => text);

      expect(sheets, isEmpty);
      expect(capturedInitials, isEmpty);
    });

    test('shows a repo whose state cannot be read', () async {
      stubDidCommit((_) => throw Exception('no git'));

      await run((text) => text);

      expect(sheets.single, contains('"A"'));
      expect(sheets.single, contains('"B"'));
    });

    test('commits with the shared message when a commit message is '
        'cleared', () async {
      await run((_) => '{"A": {"commitMessage": []}}');
      // An emptied field keeps its default, the ticket description.
      expect(committedMessages, ['Ticket desc', 'Ticket desc']);
    });

    test('records the commit but no merge message the .gitignore cannot '
        'hide', () async {
      when(() => ensureIgnored.ensure(directory: any(named: 'directory')))
          .thenThrow(Exception('no git'));

      await run((_) => '{"A": {"mergeMessage": ["Merge A"]}}');

      final a = gg.RepoPublishConfig.tryLoad(repo('A'))!;
      expect(a.mergeMessage, isNull);
      expect(a.commits.single.firstLine, 'Ticket desc');
      expect(
        messages.join('\n'),
        contains(
          'Could not hide publish_config.json from git, the merge message '
          'is not recorded: Exception: no git',
        ),
      );
      expect(messages.last, '\nAll repos committed\n');
    });

    test('keeps the edits of a repo whose commit failed', () async {
      await expectLater(
        () => run(
          (_) =>
              '{"A": {"commitMessage": ["Commit A"]}, '
              '"B": {"commitMessage": ["Commit B", "Detail"], '
              '"mergeMessage": ["Merge B"]}}',
          ggDoCommit: failingDoCommit('B'),
        ),
        throwsA(isA<Exception>()),
      );

      expect(
        gg.RepoPublishConfig.tryLoad(repo('A'))!.commits.single.firstLine,
        'Commit A',
      );
      // B was not committed: its edits wait for the next run.
      final b = gg.RepoPublishConfig.tryLoad(repo('B'))!;
      expect(b.commits, isEmpty);
      expect(b.nextCommitMessage?.text, 'Commit B\n\nDetail');
      expect(b.mergeMessage, 'Merge B');
    });

    test('writes nothing for a failed repo that was not edited', () async {
      await expectLater(
        () => run((text) => text, ggDoCommit: failingDoCommit('B')),
        throwsA(isA<Exception>()),
      );
      expect(gg.RepoPublishConfig.tryLoad(repo('B')), isNull);
    });

    test('falls back to the line editor without an editor', () async {
      await run((_) => null);
      expect(sheets, hasLength(1));
      expect(capturedInitials, ['Ticket desc']);
    });

    test('--no-interactive takes the defaults without asking', () async {
      await gg.RepoPublishConfig(
        nextCommitMessage: gg.CommitMessage(firstLine: 'Proposed for B'),
      ).save(file: gg.repoPublishConfigFile(repo('B')));

      await run((text) => text, args: ['--no-interactive']);

      expect(sheets, isEmpty);
      expect(capturedInitials, isEmpty);
      expect(committedMessages, ['Ticket desc', 'Proposed for B']);
      expect(gg.RepoPublishConfig.tryLoad(repo('B'))!.commits, hasLength(1));
    });

    test('--no-interactive without a description passes no message', () async {
      File(path.join(ticketDir.path, ticketJsonFileName)).deleteSync();
      await run((text) => text, args: ['--no-interactive']);
      expect(committedMessages, [null, null]);
    });

    test('takes the defaults without a terminal', () async {
      await run((text) => text, hasTerminal: false);
      // Nobody to ask: the defaults, without a single prompt.
      expect(sheets, isEmpty);
      expect(capturedInitials, isEmpty);
      expect(committedMessages, ['Ticket desc', 'Ticket desc']);
    });
  });
}
