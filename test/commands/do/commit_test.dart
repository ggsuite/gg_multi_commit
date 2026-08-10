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
}
