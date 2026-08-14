// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:gg_local_package_dependencies/gg_local_package_dependencies.dart';
import 'package:gg_multi_core/gg_multi_core.dart';
import 'package:gg_multi_commit/src/commands/can/review.dart';
import 'package:gg_one/gg_one.dart' as gg;
import 'package:gg_publish/gg_publish.dart' as gg_publish;
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as path;
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:test/test.dart';

class MockSortedProcessingList extends Mock implements SortedProcessingList {}

class MockProcessRunner extends Mock {
  Future<ProcessResult> call(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool? runInShell,
  });
}

class MockIsFeatureBranch extends Mock implements gg_publish.IsFeatureBranch {}

class FakeDirectory extends Fake implements Directory {}

gg.MockPubGetOffline _stubbedPubGetOffline() {
  final mock = gg.MockPubGetOffline();
  when(
    () => mock.exec(
      directory: any(named: 'directory'),
      ggLog: any(named: 'ggLog'),
    ),
  ).thenAnswer((_) async {});
  return mock;
}

MockTicketState _stubbedTicketState() {
  final mock = MockTicketState();
  when(
    () => mock.readSuccess(
      ticketDir: any(named: 'ticketDir'),
      subs: any(named: 'subs'),
      key: any(named: 'key'),
      ignoreUnstaged: any(named: 'ignoreUnstaged'),
    ),
  ).thenAnswer((_) async => false);
  when(
    () => mock.writeSuccess(
      ticketDir: any(named: 'ticketDir'),
      subs: any(named: 'subs'),
      key: any(named: 'key'),
      ignoreUnstaged: any(named: 'ignoreUnstaged'),
    ),
  ).thenAnswer((_) async {});
  return mock;
}

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
    tempDir = Directory.systemTemp.createTempSync('can_review_ticket_test_');
    ticketsDir = Directory(path.join(tempDir.path, 'tickets'))..createSync();
    ticketDir = Directory(path.join(ticketsDir.path, 'TICKR'))..createSync();
    Directory(path.join(ticketDir.path, 'A')).createSync();
    Directory(path.join(ticketDir.path, 'B')).createSync();
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('CanReviewCommand (ticket-wide)', () {
    test('fails outside any ticket folder', () async {
      final runner = CommandRunner<void>('test', 'can review ticket')
        ..addCommand(CanReviewCommand(ggLog: ggLog));
      await expectLater(
        () async => await runner.run(['review', '--input', tempDir.path]),
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
      final runner = CommandRunner<void>('test', 'can review ticket')
        ..addCommand(CanReviewCommand(ggLog: ggLog));
      await runner.run(['review', '--input', emptyTicket.path]);
      expect(messages, contains('⚠️ No repos in this ticket'));
    });

    test('checks all repos successfully', () async {
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      final mockIsFeatureBranch = MockIsFeatureBranch();

      when(
        () => mockSortedProcessingList.get(
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
          Node(
            name: 'B',
            directory: Directory(path.join(ticketDir.path, 'B')),
            manifest: DartPackageManifest(pubspec: Pubspec('B')),
          ),
        ],
      );

      when(
        () => mockProcessRunner('git', [
          'status',
          '--porcelain',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(1, 0, '', ''));

      when(
        () => mockIsFeatureBranch.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async => true);

      final runner = CommandRunner<void>('test', 'can review ticket')
        ..addCommand(
          CanReviewCommand(
            ggLog: ggLog,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            ggIsFeatureBranch: mockIsFeatureBranch,
            ggPubGetOffline: _stubbedPubGetOffline(),
            ticketState: _stubbedTicketState(),
          ),
        );
      await runner.run(['review', '--input', ticketDir.path]);
      expect(messages, contains('\nAll repos can be reviewed\n'));
      verify(
        () => mockIsFeatureBranch.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).called(2);
    });

    test('runs "dart pub get --offline" for every repo before the '
        'uncommitted-changes check', () async {
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      final mockIsFeatureBranch = MockIsFeatureBranch();
      final mockPubGetOffline = _stubbedPubGetOffline();

      when(
        () => mockSortedProcessingList.get(
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
          Node(
            name: 'B',
            directory: Directory(path.join(ticketDir.path, 'B')),
            manifest: DartPackageManifest(pubspec: Pubspec('B')),
          ),
        ],
      );

      when(
        () => mockProcessRunner('git', [
          'status',
          '--porcelain',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(1, 0, '', ''));

      when(
        () => mockIsFeatureBranch.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async => true);

      final runner = CommandRunner<void>('test', 'can review ticket')
        ..addCommand(
          CanReviewCommand(
            ggLog: ggLog,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            ggIsFeatureBranch: mockIsFeatureBranch,
            ggPubGetOffline: mockPubGetOffline,
            ticketState: _stubbedTicketState(),
          ),
        );
      await runner.run(['review', '--input', ticketDir.path]);

      verify(
        () => mockPubGetOffline.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).called(2);
      expect(messages, contains('\nAll repos can be reviewed\n'));
    });

    test('runs "dart pub get --offline" for bridge repos too '
        '(they carry a Dart pubspec.lock)', () async {
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      final mockIsFeatureBranch = MockIsFeatureBranch();
      final mockPubGetOffline = _stubbedPubGetOffline();

      // Repo A: a plain Dart repo (no files on disk -> not a bridge).
      // Repo B: a bridge repo carrying pubspec.yaml + package.json + tsconfig.
      final repoADir = Directory(path.join(ticketDir.path, 'A'));
      final repoBDir = Directory(path.join(ticketDir.path, 'B'));
      repoBDir.createSync(recursive: true);
      File(path.join(repoBDir.path, 'pubspec.yaml'))
          .writeAsStringSync('name: B\n');
      File(path.join(repoBDir.path, 'package.json'))
          .writeAsStringSync('{"name":"B"}');
      File(path.join(repoBDir.path, 'tsconfig.json')).writeAsStringSync('{}');

      when(
        () => mockSortedProcessingList.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer(
        (_) async => [
          Node(
            name: 'A',
            directory: repoADir,
            manifest: DartPackageManifest(pubspec: Pubspec('A')),
          ),
          Node(
            name: 'B',
            directory: repoBDir,
            manifest: DartPackageManifest(pubspec: Pubspec('B')),
          ),
        ],
      );

      when(
        () => mockProcessRunner('git', [
          'status',
          '--porcelain',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(1, 0, '', ''));

      when(
        () => mockIsFeatureBranch.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async => true);

      final runner = CommandRunner<void>('test', 'can review ticket')
        ..addCommand(
          CanReviewCommand(
            ggLog: ggLog,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            ggIsFeatureBranch: mockIsFeatureBranch,
            ggPubGetOffline: mockPubGetOffline,
            ticketState: _stubbedTicketState(),
          ),
        );
      await runner.run(['review', '--input', ticketDir.path]);

      // pub get runs for BOTH repos: the plain Dart repo A and the bridge B
      // (PubGetOffline itself skips only repos without a pubspec.yaml).
      verify(
        () => mockPubGetOffline.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).called(2);
      expect(messages, contains('\nAll repos can be reviewed\n'));
    });

    test('fails if "dart pub get --offline" fails in a repo', () async {
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      final mockIsFeatureBranch = MockIsFeatureBranch();
      final mockPubGetOffline = gg.MockPubGetOffline();

      when(
        () => mockSortedProcessingList.get(
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

      when(
        () => mockIsFeatureBranch.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async => true);

      when(
        () => mockPubGetOffline.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenThrow(Exception('pub get failed'));

      final runner = CommandRunner<void>('test', 'can review ticket')
        ..addCommand(
          CanReviewCommand(
            ggLog: ggLog,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            ggIsFeatureBranch: mockIsFeatureBranch,
            ggPubGetOffline: mockPubGetOffline,
            ticketState: _stubbedTicketState(),
          ),
        );

      await expectLater(
        () async => await runner.run(['review', '--input', ticketDir.path]),
        throwsA(isA<Exception>()),
      );

      // The uncommitted-changes check must not run when pub get fails first.
      verifyNever(
        () => mockProcessRunner('git', [
          'status',
          '--porcelain',
        ], workingDirectory: any(named: 'workingDirectory')),
      );
    });

    test('fails if a repo is not on a feature branch', () async {
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      final mockIsFeatureBranch = MockIsFeatureBranch();

      when(
        () => mockSortedProcessingList.get(
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
          Node(
            name: 'B',
            directory: Directory(path.join(ticketDir.path, 'B')),
            manifest: DartPackageManifest(pubspec: Pubspec('B')),
          ),
        ],
      );

      when(
        () => mockProcessRunner('git', [
          'status',
          '--porcelain',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(1, 0, '', ''));

      // B's branch is some non-default branch (not main/master), so it is a
      // genuine "not on a feature branch" error rather than an already-merged
      // repo to skip.
      when(
        () => mockProcessRunner('git', [
          'rev-parse',
          '--abbrev-ref',
          'HEAD',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 0, 'detached-thing', ''));

      // A is on a feature branch, B is not
      when(
        () => mockIsFeatureBranch.get(
          directory: any(
            named: 'directory',
            that: predicate<Directory>((d) => path.basename(d.path) == 'A'),
          ),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async => true);
      when(
        () => mockIsFeatureBranch.get(
          directory: any(
            named: 'directory',
            that: predicate<Directory>((d) => path.basename(d.path) == 'B'),
          ),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async => false);

      final runner = CommandRunner<void>('test', 'can review ticket')
        ..addCommand(
          CanReviewCommand(
            ggLog: ggLog,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            ggIsFeatureBranch: mockIsFeatureBranch,
            ggPubGetOffline: _stubbedPubGetOffline(),
            ticketState: _stubbedTicketState(),
          ),
        );
      await expectLater(
        () async => await runner.run([
          'review',
          '--verbose',
          '--input',
          ticketDir.path,
        ]),
        throwsA(isA<Exception>()),
      );
      expect(
        messages.any((m) => m.contains('Not on a feature branch:')),
        isTrue,
      );
      expect(messages.any((m) => m.contains(' - B')), isTrue);
    });

    test('skips repos already merged to main or master', () async {
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      final mockIsFeatureBranch = MockIsFeatureBranch();

      when(
        () => mockSortedProcessingList.get(
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
          Node(
            name: 'B',
            directory: Directory(path.join(ticketDir.path, 'B')),
            manifest: DartPackageManifest(pubspec: Pubspec('B')),
          ),
        ],
      );

      // No uncommitted changes anywhere.
      when(
        () => mockProcessRunner('git', [
          'status',
          '--porcelain',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(0, 0, '', ''));

      // A is already merged to main, B to master (trailing newline is trimmed).
      when(
        () => mockProcessRunner(
          'git',
          ['rev-parse', '--abbrev-ref', 'HEAD'],
          workingDirectory: any(
            named: 'workingDirectory',
            that: predicate<String>((p) => path.basename(p) == 'A'),
          ),
        ),
      ).thenAnswer((_) async => ProcessResult(0, 0, 'main\n', ''));
      when(
        () => mockProcessRunner(
          'git',
          ['rev-parse', '--abbrev-ref', 'HEAD'],
          workingDirectory: any(
            named: 'workingDirectory',
            that: predicate<String>((p) => path.basename(p) == 'B'),
          ),
        ),
      ).thenAnswer((_) async => ProcessResult(0, 0, 'master\n', ''));

      // Neither is on a feature branch.
      when(
        () => mockIsFeatureBranch.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async => false);

      final runner = CommandRunner<void>('test', 'can review ticket')
        ..addCommand(
          CanReviewCommand(
            ggLog: ggLog,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            ggIsFeatureBranch: mockIsFeatureBranch,
            ggPubGetOffline: _stubbedPubGetOffline(),
            ticketState: _stubbedTicketState(),
          ),
        );

      await runner.run(['review', '--verbose', '--input', ticketDir.path]);

      expect(
        messages.any((m) => m.contains('A is on main — already merged')),
        isTrue,
      );
      expect(
        messages.any((m) => m.contains('B is on master — already merged')),
        isTrue,
      );
      expect(
        messages.any((m) => m.contains('All repos can be reviewed')),
        isTrue,
      );
    });

    test('fails if uncommitted changes', () async {
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      final mockIsFeatureBranch = MockIsFeatureBranch();

      when(
        () => mockSortedProcessingList.get(
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
          Node(
            name: 'B',
            directory: Directory(path.join(ticketDir.path, 'B')),
            manifest: DartPackageManifest(pubspec: Pubspec('B')),
          ),
        ],
      );

      when(
        () => mockIsFeatureBranch.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async => true);

      // Simulate uncommitted changes in A
      when(
        () => mockProcessRunner('git', [
          'status',
          '--porcelain',
        ], workingDirectory: path.join(ticketDir.path, 'A')),
      ).thenAnswer((_) async => ProcessResult(1, 0, ' M file.txt', ''));
      when(
        () => mockProcessRunner('git', [
          'status',
          '--porcelain',
        ], workingDirectory: path.join(ticketDir.path, 'B')),
      ).thenAnswer((_) async => ProcessResult(2, 0, '', ''));

      final runner = CommandRunner<void>('test', 'can review ticket')
        ..addCommand(
          CanReviewCommand(
            ggLog: ggLog,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            ggIsFeatureBranch: mockIsFeatureBranch,
            ggPubGetOffline: _stubbedPubGetOffline(),
            ticketState: _stubbedTicketState(),
          ),
        );
      await expectLater(
        () async => await runner.run([
          'review',
          '--verbose',
          '--input',
          ticketDir.path,
        ]),
        throwsA(isA<Exception>()),
      );
      expect(messages.any((m) => m.contains('Uncommitted changes in')), isTrue);
      expect(messages.any((m) => m.contains(' - A')), isTrue);
    });

    test(
      'short-circuits when ticket state already cached as success',
      () async {
        final mockSortedProcessingList = MockSortedProcessingList();
        final mockProcessRunner = MockProcessRunner();
        final mockIsFeatureBranch = MockIsFeatureBranch();
        final mockTicketState = MockTicketState();

        when(
          () => mockSortedProcessingList.get(
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

        when(
          () => mockTicketState.readSuccess(
            ticketDir: any(named: 'ticketDir'),
            subs: any(named: 'subs'),
            key: any(named: 'key'),
            ignoreUnstaged: any(named: 'ignoreUnstaged'),
          ),
        ).thenAnswer((_) async => true);

        final runner = CommandRunner<void>('test', 'can review ticket')
          ..addCommand(
            CanReviewCommand(
              ggLog: ggLog,
              sortedProcessingList: mockSortedProcessingList,
              processRunner: mockProcessRunner.call,
              ggIsFeatureBranch: mockIsFeatureBranch,
              ggPubGetOffline: _stubbedPubGetOffline(),
              ticketState: mockTicketState,
            ),
          );

        await runner.run(['review', '--input', ticketDir.path]);

        expect(messages, contains('\nAll repos can be reviewed\n'));
        verifyNever(
          () => mockIsFeatureBranch.get(
            directory: any(named: 'directory'),
            ggLog: any(named: 'ggLog'),
          ),
        );
        verifyNever(
          () => mockTicketState.writeSuccess(
            ticketDir: any(named: 'ticketDir'),
            subs: any(named: 'subs'),
            key: any(named: 'key'),
            ignoreUnstaged: any(named: 'ignoreUnstaged'),
          ),
        );
      },
    );

    test('--force bypasses the cached success', () async {
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      final mockIsFeatureBranch = MockIsFeatureBranch();
      final mockTicketState = MockTicketState();

      when(
        () => mockSortedProcessingList.get(
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
      when(
        () => mockProcessRunner('git', [
          'status',
          '--porcelain',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(1, 0, '', ''));
      when(
        () => mockIsFeatureBranch.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async => true);
      when(
        () => mockTicketState.readSuccess(
          ticketDir: any(named: 'ticketDir'),
          subs: any(named: 'subs'),
          key: any(named: 'key'),
          ignoreUnstaged: any(named: 'ignoreUnstaged'),
        ),
      ).thenAnswer((_) async => true);
      when(
        () => mockTicketState.writeSuccess(
          ticketDir: any(named: 'ticketDir'),
          subs: any(named: 'subs'),
          key: any(named: 'key'),
          ignoreUnstaged: any(named: 'ignoreUnstaged'),
        ),
      ).thenAnswer((_) async {});

      final runner = CommandRunner<void>('test', 'can review ticket')
        ..addCommand(
          CanReviewCommand(
            ggLog: ggLog,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            ggIsFeatureBranch: mockIsFeatureBranch,
            ggPubGetOffline: _stubbedPubGetOffline(),
            ticketState: mockTicketState,
          ),
        );

      await runner.run(['review', '--force', '--input', ticketDir.path]);

      verify(
        () => mockIsFeatureBranch.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).called(1);
      verify(
        () => mockTicketState.writeSuccess(
          ticketDir: any(named: 'ticketDir'),
          subs: any(named: 'subs'),
          key: 'canReview',
          ignoreUnstaged: any(named: 'ignoreUnstaged'),
        ),
      ).called(1);
    });

    test('--no-save-state skips persisting success', () async {
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      final mockIsFeatureBranch = MockIsFeatureBranch();
      final mockTicketState = _stubbedTicketState();

      when(
        () => mockSortedProcessingList.get(
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
      when(
        () => mockProcessRunner('git', [
          'status',
          '--porcelain',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(1, 0, '', ''));
      when(
        () => mockIsFeatureBranch.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async => true);

      final runner = CommandRunner<void>('test', 'can review ticket')
        ..addCommand(
          CanReviewCommand(
            ggLog: ggLog,
            sortedProcessingList: mockSortedProcessingList,
            processRunner: mockProcessRunner.call,
            ggIsFeatureBranch: mockIsFeatureBranch,
            ggPubGetOffline: _stubbedPubGetOffline(),
            ticketState: mockTicketState,
          ),
        );

      await runner.run([
        'review',
        '--no-save-state',
        '--input',
        ticketDir.path,
      ]);

      verifyNever(
        () => mockTicketState.writeSuccess(
          ticketDir: any(named: 'ticketDir'),
          subs: any(named: 'subs'),
          key: any(named: 'key'),
          ignoreUnstaged: any(named: 'ignoreUnstaged'),
        ),
      );
    });

    test('uses quiet taskLog when verbose is false', () async {
      final mockSortedProcessingList = MockSortedProcessingList();
      final mockProcessRunner = MockProcessRunner();
      final mockIsFeatureBranch = MockIsFeatureBranch();

      when(
        () => mockSortedProcessingList.get(
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

      when(
        () => mockProcessRunner('git', [
          'status',
          '--porcelain',
        ], workingDirectory: any(named: 'workingDirectory')),
      ).thenAnswer((_) async => ProcessResult(1, 0, '', ''));

      when(
        () => mockIsFeatureBranch.get(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
        ),
      ).thenAnswer((_) async => true);

      final localMessages = <String>[];
      void localLog(String msg) => localMessages.add(rmControls(msg));

      final command = CanReviewCommand(
        ggLog: localLog,
        sortedProcessingList: mockSortedProcessingList,
        processRunner: mockProcessRunner.call,
        ggIsFeatureBranch: mockIsFeatureBranch,
        ggPubGetOffline: _stubbedPubGetOffline(),
        ticketState: _stubbedTicketState(),
      );

      await command.get(directory: ticketDir, ggLog: localLog, verbose: false);

      expect(localMessages.last, contains('\nAll repos can be reviewed\n'));
    });
  });
}
