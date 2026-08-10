// @license
// Copyright (c) 2025 Göran Hegenberg. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:gg_multi_commit/src/commands/did/commit.dart';
import 'package:gg_multi_commit/src/commands/did/push.dart';
import 'package:gg_one/gg_one.dart' as gg;
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

class MockGgDidPush extends Mock implements gg.DidPush {}

/// A [MockDidCommitCommand] whose check passes.
MockDidCommitCommand stubDidCommit() {
  final mock = MockDidCommitCommand();
  when(
    () => mock.exec(
      directory: any(named: 'directory'),
      ggLog: any(named: 'ggLog'),
    ),
  ).thenAnswer((_) async {});
  return mock;
}

class FakeDirectory extends Fake implements Directory {}

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
    tempDir = Directory.systemTemp.createTempSync('did_push_ticket_test_');
    ticketsDir = Directory(path.join(tempDir.path, 'tickets'))..createSync();
    ticketDir = Directory(path.join(ticketsDir.path, 'TICKDP'))..createSync();
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

  group('DidPushCommand (ticket-wide)', () {
    test('fails outside any ticket folder', () async {
      final runner = CommandRunner<void>('test', 'did push ticket')
        ..addCommand(DidPushCommand(ggLog: ggLog));
      await expectLater(
        () async => await runner.run(['push', '--input', tempDir.path]),
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
      final runner = CommandRunner<void>('test', 'did push ticket')
        ..addCommand(DidPushCommand(ggLog: ggLog));
      await runner.run(['push', '--input', emptyTicket.path]);
      expect(messages, contains('⚠️ No repos in this ticket'));
    });

    test('reports a missing commit first and skips the push check', () async {
      // A push presupposes a commit: the chain surfaces the commit error
      // with its own suggestion instead of a misleading »not pushed«.
      final mockGgDidPush = MockGgDidPush();
      final mockDidCommit = MockDidCommitCommand();
      when(
        () => mockDidCommit.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenThrow(Exception('Please run gg do commit.'));

      final runner = CommandRunner<void>('test', 'did push ticket')
        ..addCommand(
          DidPushCommand(
            ggLog: ggLog,
            ggDidPush: mockGgDidPush,
            didCommitCommand: mockDidCommit,
          ),
        );

      await expectLater(
        () async => await runner.run(['push', '--input', ticketDir.path]),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('Please run gg do commit.'),
          ),
        ),
      );

      verifyNever(
        () => mockGgDidPush.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      );
    });

    test('checks all repos successfully', () async {
      final mockGgDidPush = MockGgDidPush();

      when(
        () => mockGgDidPush.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async => true);

      final runner = CommandRunner<void>('test', 'did push ticket')
        ..addCommand(
          DidPushCommand(
            ggLog: ggLog,
            ggDidPush: mockGgDidPush,
            didCommitCommand: stubDidCommit(),
          ),
        );
      await runner.run(['push', '--input', ticketDir.path]);
      expect(messages, [
        '\n'
            'A',
        '\n'
            'B',
        '\nAll repos pushed\n',
      ]);
    });

    test('aborts on first repo that fails', () async {
      final mockGgDidPush = MockGgDidPush();

      when(
        () => mockGgDidPush.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((invocation) async {
        final repoDir = invocation.namedArguments[#directory] as Directory;
        if (path.basename(repoDir.path) == 'B') {
          throw Exception('Failed did push for B');
        }
        return false;
      });

      final runner = CommandRunner<void>('test', 'did push ticket')
        ..addCommand(
          DidPushCommand(
            ggLog: ggLog,
            ggDidPush: mockGgDidPush,
            didCommitCommand: stubDidCommit(),
          ),
        );
      await expectLater(
        () async => await runner.run(['push', '--input', ticketDir.path]),
        throwsA(isA<Exception>()),
      );
      expect(
        messages,
        contains('✗ B was not pushed\nException: Failed did push for B'),
      );
    });
  });
}
