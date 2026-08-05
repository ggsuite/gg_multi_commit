// @license
// Copyright (c) 2025 Göran Hegenberg. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:gg_local_package_dependencies/gg_local_package_dependencies.dart';
import 'package:gg_multi_core/gg_multi_core.dart';
import 'package:gg_multi_commit/src/commands/did/push.dart';
import 'package:gg_multi_commit/src/commands/did/review.dart';
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as path;
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:test/test.dart';

class MockSortedProcessingList extends Mock implements SortedProcessingList {}

class FakeDirectory extends Fake implements Directory {}

void main() {
  late Directory tempDir;
  late Directory ticketsDir;
  late Directory ticketDir;
  late MockSortedProcessingList sortedProcessingList;
  late MockTicketState ticketState;
  late MockDidPushCommand didPushCommand;
  final messages = <String>[];

  setUpAll(() {
    registerFallbackValue(FakeDirectory());
    registerFallbackValue(<Node>[]);
  });

  void ggLog(String msg) => messages.add(rmControls(msg));

  DidReviewCommand command() => DidReviewCommand(
    ggLog: ggLog,
    sortedProcessingList: sortedProcessingList,
    ticketState: ticketState,
    didPushCommand: didPushCommand,
  );

  CommandRunner<void> runner() =>
      CommandRunner<void>('test', 'did review ticket')..addCommand(command());

  setUp(() {
    messages.clear();
    tempDir = Directory.systemTemp.createTempSync('did_review_ticket_test_');
    ticketsDir = Directory(path.join(tempDir.path, 'tickets'))..createSync();
    ticketDir = Directory(path.join(ticketsDir.path, 'TICKDR'))..createSync();
    Directory(path.join(ticketDir.path, 'A')).createSync();

    sortedProcessingList = MockSortedProcessingList();
    when(
      () => sortedProcessingList.get(
        directory: any(named: 'directory'),
        ggLog: any(named: 'ggLog'),
      ),
    ).thenAnswer(
      (_) async => [
        Node(
          name: 'A',
          directory: Directory(path.join(ticketDir.path, 'A')),
          manifest: DartPackageManifest(pubspec: Pubspec('A')),
        ),
      ],
    );

    ticketState = MockTicketState();

    // The chained »did push« (which itself chains »did commit«) passes by
    // default; tests about the chain override it.
    didPushCommand = MockDidPushCommand();
    when(
      () => didPushCommand.exec(
        directory: any(named: 'directory'),
        ggLog: any(named: 'ggLog'),
      ),
    ).thenAnswer((_) async {});
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('DidReviewCommand', () {
    test('has the state key the other commands share', () {
      expect(DidReviewCommand.stateKey, 'didReview');
    });

    test('constructs its default collaborators', () {
      expect(() => DidReviewCommand(ggLog: ggLog), returnsNormally);
    });

    test('fails outside any ticket folder', () async {
      await expectLater(
        () async => await runner().run(['review', '--input', tempDir.path]),
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
      when(
        () => sortedProcessingList.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async => <Node>[]);

      await runner().run(['review', '--input', ticketDir.path]);

      expect(messages, contains('⚠️ No repos in this ticket'));
    });

    test('reports a missing push first and skips the review check', () async {
      // A review presupposes pushed commits: the chain surfaces the push
      // (or commit) error with its own suggestion first.
      when(
        () => didPushCommand.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenThrow(Exception('Please run gg do push.'));

      await expectLater(
        () async => await runner().run(['review', '--input', ticketDir.path]),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('Please run gg do push.'),
          ),
        ),
      );

      verifyNever(
        () => ticketState.readSuccess(
          ticketDir: any(named: 'ticketDir'),
          subs: any(named: 'subs'),
          key: any(named: 'key'),
        ),
      );
    });

    test('succeeds when the current state was reviewed', () async {
      when(
        () => ticketState.readSuccess(
          ticketDir: any(named: 'ticketDir'),
          subs: any(named: 'subs'),
          key: DidReviewCommand.stateKey,
        ),
      ).thenAnswer((_) async => true);

      await runner().run(['review', '--input', ticketDir.path]);

      expect(messages, contains('✓ The current state was reviewed'));
    });

    test('fails with a suggestion when the state was not reviewed', () async {
      when(
        () => ticketState.readSuccess(
          ticketDir: any(named: 'ticketDir'),
          subs: any(named: 'subs'),
          key: DidReviewCommand.stateKey,
        ),
      ).thenAnswer((_) async => false);

      await expectLater(
        () async => await runner().run(['review', '--input', ticketDir.path]),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('Please run gg do review.'),
          ),
        ),
      );

      expect(messages, contains('✗ The current state was reviewed'));
    });
  });
}
