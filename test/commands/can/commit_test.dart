// @license
// Copyright (c) 2025 Göran Hegenberg. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:gg_multi_commit/src/commands/can/commit.dart';
import 'package:gg_one/gg_one.dart' as gg;
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

class MockGgCanCommit extends Mock implements gg.CanCommit {}

class MockGgDidCommit extends Mock implements gg.DidCommit {}

class FakeDirectory extends Fake implements Directory {}

/// A [gg.DidCommit] answering every repo with [committed].
MockGgDidCommit mockDidCommit(bool committed) {
  final mock = MockGgDidCommit();
  when(
    () => mock.get(
      directory: any(named: 'directory'),
      ggLog: any(named: 'ggLog'),
    ),
  ).thenAnswer((invocation) async {
    // The command drops this output — calling it proves the sink is a valid
    // one and covers the closure it passes in.
    (invocation.namedArguments[#ggLog] as void Function(String))('ignored');
    return committed;
  });
  return mock;
}

void main() {
  late Directory tempDir;
  late Directory ticketsDir;
  late Directory ticketDir;
  final messages = <String>[];

  setUpAll(() {
    registerFallbackValue(FakeDirectory());
  });

  void ggLog(String msg) => messages.add(rmControls(msg));

  setUp(() {
    messages.clear();
    tempDir = Directory.systemTemp.createTempSync('can_commit_ticket_test_');
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

  group('CanCommitCommand (ticket-wide)', () {
    test('fails outside any ticket folder', () async {
      final runner = CommandRunner<void>('test', 'can commit ticket')
        ..addCommand(CanCommitCommand(ggLog: ggLog));
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
      final runner = CommandRunner<void>('test', 'can commit ticket')
        ..addCommand(CanCommitCommand(ggLog: ggLog));
      await runner.run(['commit', '--input', emptyTicket.path]);
      expect(messages, contains('⚠️ No repos in this ticket'));
    });

    test('checks all repos successfully', () async {
      final mockGgCanCommit = MockGgCanCommit();

      when(
        () => mockGgCanCommit.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      final runner = CommandRunner<void>('test', 'can commit ticket')
        ..addCommand(
          CanCommitCommand(
            ggLog: ggLog,
            ggCanCommit: mockGgCanCommit,
            ggDidCommit: mockDidCommit(false),
          ),
        );
      await runner.run(['commit', '--input', ticketDir.path]);
      expect(messages.first.split('\n'), ['', 'A']);

      // Something is still open, so the repos only *can* be committed.
      expect(messages.last, '\nAll repos can be committed\n');
    });

    test('reports »committed« when every repo is committed already', () async {
      final mockGgCanCommit = MockGgCanCommit();

      when(
        () => mockGgCanCommit.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async {});

      final runner = CommandRunner<void>('test', 'can commit ticket')
        ..addCommand(
          CanCommitCommand(
            ggLog: ggLog,
            ggCanCommit: mockGgCanCommit,
            ggDidCommit: mockDidCommit(true),
          ),
        );
      await runner.run(['commit', '--input', ticketDir.path]);
      expect(messages.last, '\nAll repos committed.\n');
    });

    test('aborts on first repo that fails', () async {
      final mockGgCanCommit = MockGgCanCommit();

      when(
        () => mockGgCanCommit.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((invocation) async {
        final repoDir = invocation.namedArguments[#directory] as Directory;
        if (path.basename(repoDir.path) == 'B') {
          throw Exception('Failed to commit B');
        }
      });

      final runner = CommandRunner<void>('test', 'can commit ticket')
        ..addCommand(
          CanCommitCommand(
            ggLog: ggLog,
            ggCanCommit: mockGgCanCommit,
            ggDidCommit: mockDidCommit(false),
          ),
        );
      await expectLater(
        () async => await runner.run(['commit', '--input', ticketDir.path]),
        throwsA(isA<Exception>()),
      );
      expect(messages, [
        '\nA',
        '\nB',
        // The reason is printed once, under the repo it belongs to.
        '✗ Cannot commit\nException: Failed to commit B',
        '\nPlease fix the issues above.\n',
      ]);
    });
  });
}
