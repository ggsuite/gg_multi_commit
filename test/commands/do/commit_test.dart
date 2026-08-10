// @license
// Copyright (c) 2025 Göran Hegenberg. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:gg_multi_commit/src/commands/do/commit.dart';
import 'package:gg_one/gg_one.dart' as gg;
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';
import 'package:gg_multi_core/gg_multi_core.dart';

class MockGgCanCommit extends Mock implements gg.CanCommit {}

class MockGgDoCommit extends Mock implements gg.DoCommit {}

class FakeDirectory extends Fake implements Directory {}

void main() {
  late Directory tempDir;
  late Directory ticketsDir;
  late Directory ticketDir;
  final messages = <String>[];
  final committedMessages = <String?>[];
  final capturedInitials = <String>[];

  setUpAll(() {
    registerFallbackValue(FakeDirectory());
  });

  void ggLog(String msg) => messages.add(rmControls(msg));

  /// A [gg.DoCommit] stub recording the message it was called with.
  MockGgDoCommit recordingDoCommit() {
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
    });
    return mock;
  }

  /// An [EditMessage] stub recording what it was shown and returning [result]
  /// (the unchanged initial message when [result] is null).
  EditMessage editMessage([String? result]) => (initial) async {
    capturedInitials.add(initial);
    return result ?? initial;
  };

  setUp(() {
    messages.clear();
    committedMessages.clear();
    capturedInitials.clear();
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
      final runner = CommandRunner<void>('test', 'do commit ticket')
        ..addCommand(DoCommitCommand(ggLog: ggLog));
      await expectLater(
        () async => await runner.run(['commit', '--input', tempDir.path]),
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
      final runner = CommandRunner<void>('test', 'do commit ticket')
        ..addCommand(DoCommitCommand(ggLog: ggLog));
      await runner.run(['commit', '--input', emptyTicket.path]);
      expect(messages, contains('⚠️ No repos in this ticket'));
    });

    test('commits all repos successfully', () async {
      final mockGgCanCommit = MockGgCanCommit();
      final mockGgDoCommit = MockGgDoCommit();

      when(
        () => mockGgCanCommit.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockGgDoCommit.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          logType: any(named: 'logType'),
          updateChangeLog: any(named: 'updateChangeLog'),
          force: any(named: 'force'),
        ),
      ).thenAnswer((_) async {});

      final runner = CommandRunner<void>('test', 'do commit ticket')
        ..addCommand(
          DoCommitCommand(
            ggLog: ggLog,
            ggCanCommit: mockGgCanCommit,
            ggDoCommit: mockGgDoCommit,
          ),
        );
      await runner.run([
        'commit',
        '--input',
        ticketDir.path,
        '--message',
        'Test commit',
      ]);
      expect(messages[1].split('\n'), ['', 'A']);
    });

    test('aborts on first repo that fails', () async {
      final mockGgCanCommit = MockGgCanCommit();
      final mockGgDoCommit = MockGgDoCommit();

      when(
        () => mockGgCanCommit.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      when(
        () => mockGgDoCommit.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          logType: any(named: 'logType'),
          updateChangeLog: any(named: 'updateChangeLog'),
          force: any(named: 'force'),
        ),
      ).thenAnswer((invocation) async {
        final repoDir = invocation.namedArguments[#directory] as Directory;
        if (path.basename(repoDir.path) == 'B') {
          throw Exception('Failed to commit B');
        }
      });

      final runner = CommandRunner<void>('test', 'do commit ticket')
        ..addCommand(
          DoCommitCommand(
            ggLog: ggLog,
            ggCanCommit: mockGgCanCommit,
            ggDoCommit: mockGgDoCommit,
          ),
        );
      await expectLater(
        () async => await runner.run([
          'commit',
          '--input',
          ticketDir.path,
          '--message',
          'Test commit',
        ]),
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
  });

  group('commit message default from ticket.json', () {
    /// Runs `do commit` on [ticketDir], optionally with `-m` [message].
    Future<void> run({String? message, EditMessage? edit}) async {
      final runner = CommandRunner<void>('test', 'do commit ticket')
        ..addCommand(
          DoCommitCommand(
            ggLog: ggLog,
            ggDoCommit: recordingDoCommit(),
            editMessage: edit ?? editMessage(),
          ),
        );
      await runner.run([
        'commit',
        '--input',
        ticketDir.path,
        if (message != null) ...['--message', message],
      ]);
    }

    test('reuses the ticket description when no message is given', () async {
      File(
        path.join(ticketDir.path, ticketJsonFileName),
      ).writeAsStringSync('{"description": "Ticket desc"}');

      await run();

      // The description pre-filled the editor and reached every repo.
      expect(capturedInitials, ['Ticket desc']);
      expect(committedMessages, ['Ticket desc', 'Ticket desc']);
    });

    test('commits the edited message', () async {
      File(
        path.join(ticketDir.path, ticketJsonFileName),
      ).writeAsStringSync('{"description": "Ticket desc"}');

      await run(edit: editMessage('Edited message'));

      expect(committedMessages, ['Edited message', 'Edited message']);
    });

    test('falls back to the description when the edit is cleared', () async {
      File(
        path.join(ticketDir.path, ticketJsonFileName),
      ).writeAsStringSync('{"description": "Ticket desc"}');

      await run(edit: editMessage('   '));

      expect(committedMessages, ['Ticket desc', 'Ticket desc']);
    });

    test('does not offer an edit when -m is given', () async {
      File(
        path.join(ticketDir.path, ticketJsonFileName),
      ).writeAsStringSync('{"description": "Ticket desc"}');

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
      File(
        path.join(emptyTicket.path, ticketJsonFileName),
      ).writeAsStringSync('{"description": "Ticket desc"}');

      final runner = CommandRunner<void>('test', 'do commit ticket')
        ..addCommand(
          DoCommitCommand(
            ggLog: ggLog,
            ggDoCommit: recordingDoCommit(),
            editMessage: editMessage(),
          ),
        );
      await runner.run(['commit', '--input', emptyTicket.path]);

      expect(messages, contains('⚠️ No repos in this ticket'));
      expect(capturedInitials, isEmpty);
    });

    test('exec forwards the message without offering an edit', () async {
      final command = DoCommitCommand(
        ggLog: ggLog,
        ggDoCommit: recordingDoCommit(),
        editMessage: editMessage(),
      );

      await command.exec(
        directory: ticketDir,
        ggLog: ggLog,
        message: 'From code',
      );

      expect(capturedInitials, isEmpty);
      expect(committedMessages, ['From code', 'From code']);
    });
  });

  group('nextCommitMessage from publish_config.json', () {
    Directory repo(String name) => Directory(path.join(ticketDir.path, name));

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

    Future<void> run({String? message, EditMessage? edit}) async {
      final runner = CommandRunner<void>('test', 'do commit ticket')
        ..addCommand(
          DoCommitCommand(
            ggLog: ggLog,
            ggDoCommit: recordingDoCommit(),
            editMessage: edit ?? editMessage(),
          ),
        );
      await runner.run([
        'commit',
        '--input',
        ticketDir.path,
        if (message != null) ...['--message', message],
      ]);
    }

    test('proposes the per-repo message and shares the rest', () async {
      // Only A carries a proposal — B keeps the one shared ticket message.
      await proposeIn('A', firstLine: 'Adapt message.json');
      File(
        path.join(ticketDir.path, ticketJsonFileName),
      ).writeAsStringSync('{"description": "Ticket desc"}');

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

      final failing = MockGgDoCommit();
      when(
        () => failing.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          logType: any(named: 'logType'),
          updateChangeLog: any(named: 'updateChangeLog'),
          force: any(named: 'force'),
        ),
      ).thenThrow(Exception('nope'));

      final runner = CommandRunner<void>('test', 'do commit ticket')
        ..addCommand(
          DoCommitCommand(
            ggLog: ggLog,
            ggDoCommit: failing,
            editMessage: editMessage(),
          ),
        );
      await expectLater(
        () => runner.run(['commit', '--input', ticketDir.path]),
        throwsA(isA<Exception>()),
      );

      expect(gg.RepoPublishConfig.tryLoad(repo('A'))!.commits, isEmpty);
    });

    test('re-opens the editor on a too long first line', () async {
      await proposeIn('A', firstLine: 'ok');
      await proposeIn('B', firstLine: 'B change');

      var call = 0;
      await run(
        edit: (initial) async {
          capturedInitials.add(initial);
          call++;
          return call == 1 ? 'a' * 61 : 'Corrected';
        },
      );

      expect(messages.any((m) => m.contains('60 characters')), isTrue);
      expect(committedMessages.first, 'Corrected');
    });

    test('gives up after three invalid attempts', () async {
      await proposeIn('A', firstLine: 'ok');
      await proposeIn('B', firstLine: 'B change');

      await expectLater(
        () => run(edit: (_) async => 'a' * 61),
        throwsA(isA<Exception>()),
      );
      expect(
        messages.any((m) => m.contains('still invalid after 3 attempts')),
        isTrue,
      );
    });

    test('rejects a -m whose first line is too long', () async {
      await proposeIn('A', firstLine: 'ok');
      await proposeIn('B', firstLine: 'B change');

      await expectLater(
        () => run(message: 'a' * 61),
        throwsA(isA<Exception>()),
      );
      expect(messages.any((m) => m.contains('Invalid commit message')), isTrue);
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
}
