// @license
// Copyright (c) ggsuite
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

import '../../test_helpers.dart';

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

/// A [gg.CanCommit] whose exec is stubbed once and hands over to [onExec].
MockGgCanCommit mockCanCommit([
  Future<void> Function(Invocation invocation)? onExec,
]) {
  final mock = MockGgCanCommit();
  when(
    () => mock.exec(
      directory: any(named: 'directory'),
      ggLog: any(named: 'ggLog'),
      force: any(named: 'force'),
    ),
  ).thenAnswer((invocation) async => onExec?.call(invocation));
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
      final runner = CommandRunner<void>('test', 'can commit ticket')
        ..addCommand(
          CanCommitCommand(
            ggLog: ggLog,
            ticketLocalizer: inSyncTicketLocalizer(),
            ggCanCommit: mockCanCommit(),
            ggDidCommit: mockDidCommit(false),
          ),
        );
      await runner.run(['commit', '--input', ticketDir.path]);
      expect(messages.first.split('\n'), ['', 'A']);

      // Something is still open, so the repos only *can* be committed.
      expect(messages.last, '\nAll repos can be committed\n');
    });

    test('reports »committed« when every repo is committed already', () async {
      final runner = CommandRunner<void>('test', 'can commit ticket')
        ..addCommand(
          CanCommitCommand(
            ggLog: ggLog,
            ticketLocalizer: inSyncTicketLocalizer(),
            ggCanCommit: mockCanCommit(),
            ggDidCommit: mockDidCommit(true),
          ),
        );
      await runner.run(['commit', '--input', ticketDir.path]);
      expect(messages.last, '\nAll repos committed\n');
    });

    test('passes --force on to every repo', () async {
      final forced = <bool?>[];
      final mockGgCanCommit = mockCanCommit((invocation) async {
        forced.add(invocation.namedArguments[#force] as bool?);
      });

      final runner = CommandRunner<void>('test', 'can commit ticket')
        ..addCommand(
          CanCommitCommand(
            ggLog: ggLog,
            ticketLocalizer: inSyncTicketLocalizer(),
            ggCanCommit: mockGgCanCommit,
            ggDidCommit: mockDidCommit(false),
          ),
        );

      // Without the flag the repos may reuse an earlier success.
      await runner.run(['commit', '--input', ticketDir.path]);
      expect(forced, [false, false]);

      forced.clear();
      await runner.run(['commit', '--input', ticketDir.path, '--force']);
      expect(forced, [true, true]);

      forced.clear();
      await runner.run(['commit', '--input', ticketDir.path, '-f']);
      expect(forced, [true, true]);
    });

    test('refuses unlocalized references before checking any repo', () async {
      final sampleTicket = await createSampleTicket(tempDir);
      await addDependency(sampleRepo(sampleTicket, 'a'), 'b', commit: true);
      final ggCanCommit = mockCanCommit();

      final runner = CommandRunner<void>('test', 'can commit ticket')
        ..addCommand(
          CanCommitCommand(
            ggLog: ggLog,
            ggCanCommit: ggCanCommit,
            ggDidCommit: mockDidCommit(false),
          ),
        );
      await expectLater(
        () async => await runner.run(['commit', '--input', sampleTicket.path]),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls('$e'),
            'message',
            'Exception: References not localized in a.',
          ),
        ),
      );
      expect(messages, [
        '\na',
        '✗ a uses the published b instead of its checkout',
        '\nPlease run gg do localize '
            '(or gg do commit, which localizes itself).\n',
      ]);
      verifyNever(
        () => ggCanCommit.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          force: any(named: 'force'),
        ),
      );
    });

    test('only warns about a repo missing between the ticket repos', () async {
      // a reaches its ticket sibling b only through the ocean's c.
      final sampleTicket = await createSampleTicket(tempDir);
      await addDependency(sampleRepo(sampleTicket, 'a'), 'c', commit: true);
      addOceanRepo(tempDir, 'c', 'b');
      final ggCanCommit = mockCanCommit();

      final runner = CommandRunner<void>('test', 'can commit ticket')
        ..addCommand(
          CanCommitCommand(
            ggLog: ggLog,
            ggCanCommit: ggCanCommit,
            ggDidCommit: mockDidCommit(false),
          ),
        );
      await runner.run(['commit', '--input', sampleTicket.path]);

      expect(messages.take(3), [
        '\n⚠️ Repos between the ticket repos, but not in it:',
        '  - c',
        'Run gg do add c to add them.\n',
      ]);
      expect(messages.last, '\nAll repos can be committed\n');
      verify(
        () => ggCanCommit.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          force: any(named: 'force'),
        ),
      ).called(2);
    });

    test('aborts on first repo that fails', () async {
      final mockGgCanCommit = mockCanCommit((invocation) async {
        final repoDir = invocation.namedArguments[#directory] as Directory;
        if (path.basename(repoDir.path) == 'B') {
          throw Exception('Failed to commit B');
        }
      });

      final runner = CommandRunner<void>('test', 'can commit ticket')
        ..addCommand(
          CanCommitCommand(
            ggLog: ggLog,
            ticketLocalizer: inSyncTicketLocalizer(),
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
