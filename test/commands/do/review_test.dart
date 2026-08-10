// @license
// Copyright (c) 2019 - 2025 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:gg_local_package_dependencies/gg_local_package_dependencies.dart';
import 'package:gg_multi_core/gg_multi_core.dart';
import 'package:gg_multi_commit/src/commands/can/review.dart';
import 'package:gg_multi_commit/src/commands/did/review.dart';
import 'package:gg_multi_commit/src/commands/do/push.dart';
import 'package:gg_multi_commit/src/commands/do/review.dart';
import 'package:gg_one/gg_one.dart' as gg;
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as path;
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:test/test.dart';

class MockSortedProcessingList extends Mock implements SortedProcessingList {}

class MockCanReviewCommand extends Mock implements CanReviewCommand {}

class MockDoPushCommand extends Mock implements DoPushCommand {}

class MockCreatePullRequest extends Mock implements gg.CreatePullRequest {}

class FakeDirectory extends Fake implements Directory {}

/// A [MockCreatePullRequest] that answers every repo with [url] — null when
/// the repo has no provider gg can open a pull request on.
MockCreatePullRequest stubCreatePullRequest({
  String? url = 'https://github.com/ggsuite/A/pull/1',
}) {
  final mock = MockCreatePullRequest();
  when(
    () => mock.get(
      directory: any(named: 'directory'),
      ggLog: any(named: 'ggLog'),
      message: any(named: 'message'),
    ),
  ).thenAnswer((_) async => url);
  return mock;
}

/// All collaborators of a [DoReviewCommand], each pre-stubbed to succeed so a
/// test only has to override the one it is about.
typedef ReviewTestBed = ({
  DoReviewCommand command,
  MockCanReviewCommand canReview,
  MockDoPushCommand doPush,
  MockCreatePullRequest createPullRequest,
  MockTicketState ticketState,
});

void main() {
  late Directory tempDir;
  late Directory ticketsDir;
  late Directory ticketDir;
  final messages = <String>[];

  setUpAll(() {
    registerFallbackValue(FakeDirectory());
    registerFallbackValue(<Node>[]);
  });

  void ggLog(String msg) => messages.add(rmControls(msg));

  setUp(() {
    messages.clear();
    tempDir = Directory.systemTemp.createTempSync('do_review_ticket_test_');
    ticketsDir = Directory(path.join(tempDir.path, 'tickets'))..createSync();
    ticketDir = Directory(path.join(ticketsDir.path, 'TICKDR'))..createSync();
    Directory(path.join(ticketDir.path, 'A')).createSync();
    Directory(path.join(ticketDir.path, 'B')).createSync();
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  /// Builds a [DoReviewCommand] whose collaborators all succeed for the
  /// single ticket repo A.
  ReviewTestBed makeCommand({MockCreatePullRequest? createPullRequest}) {
    final canReview = MockCanReviewCommand();
    when(
      () => canReview.exec(
        directory: any(named: 'directory'),
        ggLog: any(named: 'ggLog'),
      ),
    ).thenAnswer((_) async {});

    final doPush = MockDoPushCommand();
    when(
      () => doPush.exec(
        directory: any(named: 'directory'),
        ggLog: any(named: 'ggLog'),
        verbose: any(named: 'verbose'),
      ),
    ).thenAnswer((_) async {});

    final ticketState = MockTicketState();
    when(
      () => ticketState.writeSuccess(
        ticketDir: any(named: 'ticketDir'),
        subs: any(named: 'subs'),
        key: any(named: 'key'),
      ),
    ).thenAnswer((_) async {});

    final sortedProcessingList = MockSortedProcessingList();
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

    final pullRequest = createPullRequest ?? stubCreatePullRequest();

    final command = DoReviewCommand(
      ggLog: ggLog,
      canReviewCommand: canReview,
      sortedProcessingList: sortedProcessingList,
      doPushCommand: doPush,
      createPullRequest: pullRequest,
      ticketState: ticketState,
    );

    return (
      command: command,
      canReview: canReview,
      doPush: doPush,
      createPullRequest: pullRequest,
      ticketState: ticketState,
    );
  }

  CommandRunner<void> runner(DoReviewCommand command) =>
      CommandRunner<void>('test', 'do review ticket')..addCommand(command);

  group('DoReviewCommand (ticket-wide)', () {
    test('fails outside any ticket folder', () async {
      await expectLater(
        runner(
          DoReviewCommand(ggLog: ggLog),
        ).run(['review', '--input', tempDir.path]),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            'Exception: Not inside a ticket folder',
          ),
        ),
      );
      expect(messages, [
        '\n'
            'Reviewing ...',
        'Please run this command inside a ticket folder.',
      ]);
    });

    test('logs when there are no repositories', () async {
      final emptyTicket = Directory(path.join(ticketsDir.path, 'EMPTY'))
        ..createSync();
      await runner(
        DoReviewCommand(ggLog: ggLog),
      ).run(['review', '--input', emptyTicket.path]);
      expect(messages, contains('⚠️ No repos in this ticket'));
    });

    test('runs can review, pushes, opens the pull requests and records the '
        'review', () async {
      final bed = makeCommand(
        createPullRequest: stubCreatePullRequest(
          url: 'https://github.com/ggsuite/A/pull/7',
        ),
      );

      await runner(
        bed.command,
      ).run(['review', '--verbose', '--input', ticketDir.path]);

      verifyInOrder([
        () => bed.canReview.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
        () => bed.doPush.exec(
          directory: any(
            named: 'directory',
            that: isA<Directory>().having(
              (d) => d.path,
              'path',
              ticketDir.path,
            ),
          ),
          ggLog: any(named: 'ggLog'),
          verbose: true,
        ),
        () => bed.createPullRequest.get(
          directory: any(
            named: 'directory',
            that: isA<Directory>().having(
              (d) => d.path,
              'path',
              path.join(ticketDir.path, 'A'),
            ),
          ),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
        ),
        () => bed.ticketState.writeSuccess(
          ticketDir: any(
            named: 'ticketDir',
            that: isA<Directory>().having(
              (d) => d.path,
              'path',
              ticketDir.path,
            ),
          ),
          subs: any(named: 'subs'),
          key: DidReviewCommand.stateKey,
        ),
      ]);

      expect(messages, [
        '\nReviewing ...',
        '⌛️ Can review?',
        '✓ Can review?',
        '⌛️ Creating pull requests',
        '✓ Creating pull requests',
        '\n✓ Please open and review:',
        // The printed url leads directly to the changes of the pull request.
        '  https://github.com/ggsuite/A/pull/7/changes',
        '\n',
      ]);
    });

    test('fails and stops when can review fails', () async {
      final bed = makeCommand();
      when(
        () => bed.canReview.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenThrow(Exception('Uncommitted changes in A'));

      await expectLater(
        () async => await runner(
          bed.command,
        ).run(['review', '--input', ticketDir.path]),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('Uncommitted changes in A'),
          ),
        ),
      );

      // The reason is logged even without --verbose.
      expect(
        messages.any((m) => m.contains('Uncommitted changes in A')),
        isTrue,
      );
      verifyNever(
        () => bed.doPush.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          verbose: any(named: 'verbose'),
        ),
      );
      verifyNever(
        () => bed.ticketState.writeSuccess(
          ticketDir: any(named: 'ticketDir'),
          subs: any(named: 'subs'),
          key: any(named: 'key'),
        ),
      );
    });

    test('fails when the push fails and does not record the review', () async {
      final bed = makeCommand();
      when(
        () => bed.doPush.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          verbose: any(named: 'verbose'),
        ),
      ).thenThrow(Exception('Failed to push.'));

      await expectLater(
        () async => await runner(
          bed.command,
        ).run(['review', '--input', ticketDir.path]),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            contains('Failed to push.'),
          ),
        ),
      );

      verifyNever(
        () => bed.createPullRequest.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
        ),
      );
      verifyNever(
        () => bed.ticketState.writeSuccess(
          ticketDir: any(named: 'ticketDir'),
          subs: any(named: 'subs'),
          key: any(named: 'key'),
        ),
      );
    });

    test('passes a merge conflict of the push through unwrapped', () async {
      final bed = makeCommand();
      when(
        () => bed.doPush.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          verbose: any(named: 'verbose'),
        ),
      ).thenThrow(
        MergeConflictException(
          'Merging origin/main into A produced conflicts:\n'
          ' - A/CHANGELOG.md\n'
          'Please resolve the conflicts. Then execute: '
          "gg do commit -m 'Merge main' --no-log",
        ),
      );

      await expectLater(
        () async => await runner(
          bed.command,
        ).run(['review', '--input', ticketDir.path]),
        throwsA(
          isA<MergeConflictException>().having(
            (e) => rmControls(e.toString()),
            'message',
            allOf(
              contains(' - A/CHANGELOG.md'),
              contains("gg do commit -m 'Merge main' --no-log"),
            ),
          ),
        ),
      );

      verifyNever(
        () => bed.ticketState.writeSuccess(
          ticketDir: any(named: 'ticketDir'),
          subs: any(named: 'subs'),
          key: any(named: 'key'),
        ),
      );
    });

    test('does not touch the dependency references of any repo', () async {
      // The review must not rewrite manifests anymore: the feature branches
      // keep their local path references, and whoever checks them out
      // recreates the setup from ticket.json.
      final bed = makeCommand();
      final pubspec = File(path.join(ticketDir.path, 'A', 'pubspec.yaml'))
        ..writeAsStringSync('name: A\ndependencies:\n  b:\n    path: ../B\n');
      final overrides = File(
        path.join(ticketDir.path, 'A', 'pubspec_overrides.yaml'),
      )..writeAsStringSync('dependency_overrides:\n  b:\n    path: ../B\n');

      await runner(bed.command).run(['review', '--input', ticketDir.path]);

      expect(
        pubspec.readAsStringSync(),
        'name: A\ndependencies:\n  b:\n    path: ../B\n',
      );
      expect(
        overrides.readAsStringSync(),
        'dependency_overrides:\n  b:\n    path: ../B\n',
      );
    });
  });

  group('DoReviewCommand pull requests', () {
    test('use the ticket description as message', () async {
      File(path.join(ticketDir.path, ticketJsonFileName)).writeAsStringSync(
        jsonEncode(<String, String>{
          'issue_id': 'TICKDR',
          'description': 'Create pull requests while reviewing',
        }),
      );
      final bed = makeCommand();

      await runner(bed.command).run(['review', '--input', ticketDir.path]);

      verify(
        () => bed.createPullRequest.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: 'Create pull requests while reviewing',
        ),
      ).called(1);
    });

    test('fall back to the ticket name without a description', () async {
      final bed = makeCommand();

      await runner(bed.command).run(['review', '--input', ticketDir.path]);

      verify(
        () => bed.createPullRequest.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: 'TICKDR',
        ),
      ).called(1);
    });

    test('link directly to the changes of a GitHub pull request', () async {
      final bed = makeCommand(
        createPullRequest: stubCreatePullRequest(
          url: 'https://github.com/ggsuite/gg_multi/pull/59',
        ),
      );

      await runner(bed.command).run(['review', '--input', ticketDir.path]);

      expect(
        messages,
        contains('  https://github.com/ggsuite/gg_multi/pull/59/changes'),
      );
    });

    test(
      'link directly to the files of an Azure DevOps pull request',
      () async {
        final bed = makeCommand(
          createPullRequest: stubCreatePullRequest(
            url: 'https://dev.azure.com/org/p/_git/repo/pullrequest/42',
          ),
        );

        await runner(bed.command).run(['review', '--input', ticketDir.path]);

        expect(
          messages,
          contains(
            '  https://dev.azure.com/org/p/_git/repo/pullrequest/42?_a=files',
          ),
        );
      },
    );

    test('print the url of an unknown provider untouched', () async {
      final bed = makeCommand(
        createPullRequest: stubCreatePullRequest(
          url: 'https://gitlab.example.com/repo/-/merge_requests/7',
        ),
      );

      await runner(bed.command).run(['review', '--input', ticketDir.path]);

      expect(
        messages,
        contains('  https://gitlab.example.com/repo/-/merge_requests/7'),
      );
    });

    test('print nothing when the provider supports none', () async {
      final bed = makeCommand(
        createPullRequest: stubCreatePullRequest(url: null),
      );

      await runner(bed.command).run(['review', '--input', ticketDir.path]);

      expect(
        messages.any((m) => m.contains('Please open and review:')),
        isFalse,
      );
    });

    test('report a failure without failing the review', () async {
      final createPullRequest = MockCreatePullRequest();
      when(
        () => createPullRequest.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
        ),
      ).thenThrow(Exception('gh not installed'));
      final bed = makeCommand(createPullRequest: createPullRequest);

      await runner(bed.command).run(['review', '--input', ticketDir.path]);

      expect(
        messages.any(
          (m) =>
              m.contains('No pull request for A') &&
              m.contains('gh not installed'),
        ),
        isTrue,
      );
      // The review itself succeeded — the branch is on the remote — so the
      // review is still recorded.
      verify(
        () => bed.ticketState.writeSuccess(
          ticketDir: any(named: 'ticketDir'),
          subs: any(named: 'subs'),
          key: DidReviewCommand.stateKey,
        ),
      ).called(1);
    });
  });
}
