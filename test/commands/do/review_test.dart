// @license
// Copyright (c) ggsuite
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
import 'package:gg_publish/gg_publish.dart'
    show PublishedVersion, VersionIncrement;
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as path;
import 'package:pub_semver/pub_semver.dart';
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:test/test.dart';

class MockSortedProcessingList extends Mock implements SortedProcessingList {}

class MockCanReviewCommand extends Mock implements CanReviewCommand {}

class MockDoPushCommand extends Mock implements DoPushCommand {}

class MockCreatePullRequest extends Mock implements gg.CreatePullRequest {}

class MockPublishedVersion extends Mock implements PublishedVersion {}

class FakeDirectory extends Fake implements Directory {}

class FakeNode extends Fake implements Node {}

/// A deterministic [gg.InteractAdapter] that always picks [index].
class _StubAdapter implements gg.InteractAdapter {
  _StubAdapter(this.index);

  final int index;

  @override
  Future<int> choose({
    required String message,
    required List<String> options,
    int initialIndex = 0,
  }) async => index;
}

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
  MockPublishSkipCheck skipCheck,
});

void main() {
  late Directory tempDir;
  late Directory ticketsDir;
  late Directory ticketDir;
  final messages = <String>[];

  setUpAll(() {
    registerFallbackValue(FakeDirectory());
    registerFallbackValue(FakeNode());
    registerFallbackValue(<Node>[]);
    registerFallbackValue(<String, String>{});
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
  /// ticket repos [repos] — every one of which the ticket releases, unless
  /// it is named in [skipped].
  ReviewTestBed makeCommand({
    MockCreatePullRequest? createPullRequest,
    List<String> repos = const ['A'],
    Set<String> skipped = const <String>{},
    EditMessage? editMessage,
    bool hasTerminal = true,
  }) {
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
        for (final name in repos)
          Node(
            name: name,
            directory: Directory(path.join(ticketDir.path, name)),
            manifest: DartPackageManifest(pubspec: Pubspec(name)),
          ),
      ],
    );

    final skipCheck = MockPublishSkipCheck();
    when(
      () => skipCheck.get(
        repo: any(named: 'repo'),
        refVersions: any(named: 'refVersions'),
      ),
    ).thenAnswer((invocation) async {
      final repo = invocation.namedArguments[#repo] as Node;
      return skipped.contains(repo.name)
          ? const PublishSkipDecision(
              skip: true,
              reason: 'Nothing changed. Skip publishing.',
            )
          : const PublishSkipDecision(
              skip: false,
              reason: 'the repo contains the manual commit »Fix bug«',
            );
    });

    final publishedVersion = MockPublishedVersion();
    when(
      () => publishedVersion.get(
        directory: any(named: 'directory'),
        ggLog: any(named: 'ggLog'),
      ),
    ).thenAnswer((_) async => Version(1, 0, 0));

    final pullRequest = createPullRequest ?? stubCreatePullRequest();

    final command = DoReviewCommand(
      ggLog: ggLog,
      canReviewCommand: canReview,
      sortedProcessingList: sortedProcessingList,
      doPushCommand: doPush,
      createPullRequest: pullRequest,
      ticketState: ticketState,
      publishPlanner: PublishPlanner(
        ggLog: ggLog,
        publishSkipCheck: skipCheck,
        publishedVersion: publishedVersion,
        readManifestVersion: (_) async => '1.0.0',
        versionSelector: gg.VersionSelector(adapter: _StubAdapter(0)),
        editMessage: editMessage ?? (initial) async => initial,
        hasTerminal: () => hasTerminal,
      ),
    );

    return (
      command: command,
      canReview: canReview,
      doPush: doPush,
      createPullRequest: pullRequest,
      ticketState: ticketState,
      skipCheck: skipCheck,
    );
  }

  CommandRunner<void> runner(DoReviewCommand command) =>
      CommandRunner<void>('test', 'do review ticket')..addCommand(command);

  group('DoReviewCommand (ticket-wide)', () {
    test('fails outside any ticket folder', () async {
      await expectLater(
        runner(DoReviewCommand(ggLog: ggLog))
            .run(['review', '--input', tempDir.path]),
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
            'Prepare review',
        'Please run this command inside a ticket folder.',
      ]);
    });

    test('logs when there are no repositories', () async {
      final emptyTicket = Directory(path.join(ticketsDir.path, 'EMPTY'))
        ..createSync();
      await runner(DoReviewCommand(ggLog: ggLog))
          .run(['review', '--input', emptyTicket.path]);
      expect(messages, contains('⚠️ No repos in this ticket'));
    });

    test('runs can review, pushes, opens the pull requests and records the '
        'review', () async {
      final bed = makeCommand(
        createPullRequest: stubCreatePullRequest(
          url: 'https://github.com/ggsuite/A/pull/7',
        ),
      );

      await runner(bed.command)
          .run(['review', '--verbose', '--input', ticketDir.path]);

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
        '\nPrepare review',
        '⌛️ Can review?',
        '✓ Can review?',
        // The planning pass announces the repo it asks the publish
        // questions for.
        '\nA',
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
        () async =>
            await runner(bed.command)
                .run(['review', '--input', ticketDir.path]),
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
        () async =>
            await runner(bed.command)
                .run(['review', '--input', ticketDir.path]),
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
          body: any(named: 'body'),
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
        () async =>
            await runner(bed.command)
                .run(['review', '--input', ticketDir.path]),
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

    test('use the generic merge message when the ticket has no '
        'description', () async {
      // Nothing seeds the merge message, so the plan falls back to the
      // generic »Publish <repo>« — and that is the pull request's title.
      final bed = makeCommand();

      await runner(bed.command).run(['review', '--input', ticketDir.path]);

      verify(
        () => bed.createPullRequest.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: 'Publish A',
        ),
      ).called(1);
    });

    test('fall back to the ticket name when the plan has no message', () async {
      // A headless review asks nothing, so no merge message exists yet — the
      // ticket description, else the ticket name, titles the pull request.
      final bed = makeCommand(hasTerminal: false);

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

  group('DoReviewCommand release plan', () {
    /// The publish configuration `do review` writes for one repository.
    File configFile(String repo) =>
        gg.repoPublishConfigFile(Directory(path.join(ticketDir.path, repo)));

    /// The answers `do review` recorded for [repo].
    gg.RepoPublishConfig configOf(String repo) => gg.RepoPublishConfig.tryLoad(
      Directory(path.join(ticketDir.path, repo)),
    )!;

    test('opens no pull request for a repo that is not released', () async {
      // B only sits between two changed packages: it carries no change of
      // its own, so it is neither released nor worth a reviewer's time.
      Directory(path.join(ticketDir.path, 'B')).createSync(recursive: true);
      final bed = makeCommand(repos: ['A', 'B'], skipped: {'B'});

      await runner(bed.command).run(['review', '--input', ticketDir.path]);

      final opened = verify(
        () => bed.createPullRequest.get(
          directory: captureAny(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          body: any(named: 'body'),
        ),
      ).captured.map((d) => path.basename((d as Directory).path)).toList();
      expect(opened, ['A']);

      // And the user is told why B was left out.
      expect(
        messages.any(
          (m) =>
              m.contains('Not published — no pull request.') &&
              m.contains('Nothing changed.'),
        ),
        isTrue,
      );
    });

    test('asks the publish questions only for the released repos', () async {
      final seeds = <String>[];
      final bed = makeCommand(
        repos: ['A', 'B'],
        skipped: {'B'},
        editMessage: (initial) async {
          seeds.add(initial);
          return 'answered';
        },
      );

      await runner(bed.command).run(['review', '--input', ticketDir.path]);

      // Exactly one question round — for A.
      expect(seeds, hasLength(1));

      expect(configOf('A').versionIncrement, VersionIncrement.patch);
      expect(configOf('A').mergeMessage, 'answered');
      // B gets a file too — it is where the AI records B's commits — but the
      // questions were never asked for it, so it holds no answers.
      expect(configOf('B').mergeMessage, isNull);
      expect(configOf('B').versionIncrement, isNull);
    });

    test('the merge message becomes the pull request title', () async {
      final bed = makeCommand(editMessage: (_) async => 'Fix the login flow');

      await runner(bed.command).run(['review', '--input', ticketDir.path]);

      verify(
        () => bed.createPullRequest.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: 'Fix the login flow',
          body: any(named: 'body'),
        ),
      ).called(1);
    });

    test('asks again, pre-filled with what an earlier review '
        'recorded', () async {
      Directory(path.join(ticketDir.path, 'B')).createSync(recursive: true);
      await gg.RepoPublishConfig(
        versionIncrement: VersionIncrement.major,
        mergeMessage: 'kept',
      ).save(file: configFile('A'));

      final seeds = <String>[];
      final bed = makeCommand(
        repos: ['A', 'B'],
        editMessage: (initial) async {
          seeds.add(initial);
          return initial.isEmpty ? 'fresh' : initial;
        },
      );

      await runner(bed.command).run(['review', '--input', ticketDir.path]);

      // Both repos are asked — A's editor pre-filled with its recorded
      // answer, B's with nothing.
      expect(seeds, ['kept', '']);
      expect(configOf('A').mergeMessage, 'kept');
      expect(configOf('B').mergeMessage, 'fresh');
    });

    test('carries the recorded commits into the pull request body', () async {
      await gg.RepoPublishConfig(
        commits: [gg.CommitMessage(firstLine: 'Add tracking')],
      ).save(file: configFile('A'));

      final bed = makeCommand(editMessage: (_) async => 'Title');

      await runner(bed.command).run(['review', '--input', ticketDir.path]);

      verify(
        () => bed.createPullRequest.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: 'Title',
          body: '- Add tracking',
        ),
      ).called(1);
    });

    test('writes no configuration when nothing is released', () async {
      final bed = makeCommand(skipped: {'A'});

      await runner(bed.command).run(['review', '--input', ticketDir.path]);

      expect(configFile('A').existsSync(), isFalse);
      verifyNever(
        () => bed.createPullRequest.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          body: any(named: 'body'),
        ),
      );
      expect(
        messages.any((m) => m.contains('the ticket releases nothing')),
        isTrue,
      );
      // The review is still recorded — the state was pushed and looked at.
      verify(
        () => bed.ticketState.writeSuccess(
          ticketDir: any(named: 'ticketDir'),
          subs: any(named: 'subs'),
          key: DidReviewCommand.stateKey,
        ),
      ).called(1);
    });

    test('leaves the config of an unfinished publish untouched', () async {
      // A `--continue` is waiting to finish that run; rewriting its answers
      // would strand it.
      await gg.RepoPublishConfig(
        versionIncrement: VersionIncrement.patch,
        mergeMessage: 'from the publish',
      ).save(file: configFile('A'));
      final before = configFile('A').readAsStringSync();
      await gg.PublishState(status: 'published').save(
        file: gg.publishStateFile(Directory(path.join(ticketDir.path, 'A'))),
      );

      final asked = <String>[];
      final bed = makeCommand(
        editMessage: (initial) async {
          asked.add(initial);
          return initial;
        },
      );

      await runner(bed.command).run(['review', '--input', ticketDir.path]);

      expect(asked, isEmpty);
      expect(configFile('A').readAsStringSync(), before);
      expect(
        messages.any((m) => m.contains('An unfinished publish is in progress')),
        isTrue,
      );
    });

    test('reads the answers of a legacy ticket-level config', () async {
      legacyTicketPublishConfigFile(ticketDir)
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'repos': {
              'A': {'version_increment': 'major', 'merge_message': 'legacy'},
            },
          }),
        );

      final seeds = <String>[];
      final bed = makeCommand(
        editMessage: (initial) async {
          seeds.add(initial);
          return initial;
        },
      );

      await runner(bed.command).run(['review', '--input', ticketDir.path]);

      expect(seeds, ['legacy']);
      // Only the new per-repo file is written from now on.
      expect(configOf('A').mergeMessage, 'legacy');
    });

    test('never fails the review when no question can be answered', () async {
      // stdin is no terminal: `gg do publish` will ask instead — the review
      // still filters the pull requests and records itself.
      final bed = makeCommand(hasTerminal: false);

      await runner(bed.command).run(['review', '--input', ticketDir.path]);

      verify(
        () => bed.createPullRequest.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          message: any(named: 'message'),
          body: any(named: 'body'),
        ),
      ).called(1);
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
