// @license
// Copyright (c) 2025 Göran Hegenberg. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:gg_multi_commit/src/commands/do/upgrade/deps.dart';
import 'package:gg_one/gg_one.dart' as gg;
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

class MockGgDoUpgradeDeps extends Mock implements gg.DoUpgradeDeps {}

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

  /// A [gg.DoUpgradeDeps] stub that succeeds — or throws for the
  /// repos named in [failingRepos].
  MockGgDoUpgradeDeps upgradeStub({List<String> failingRepos = const []}) {
    final mock = MockGgDoUpgradeDeps();
    when(
      () => mock.exec(
        directory: any(named: 'directory'),
        ggLog: any(named: 'ggLog'),
        majorVersions: any(named: 'majorVersions'),
      ),
    ).thenAnswer((invocation) async {
      final directory = invocation.namedArguments[#directory] as Directory;
      final repoName = path.basename(directory.path);
      if (failingRepos.contains(repoName)) {
        throw Exception('Upgrade of $repoName failed.');
      }
    });
    return mock;
  }

  setUp(() {
    messages.clear();
    tempDir = Directory.systemTemp.createTempSync('do_upgrade_ticket_test_');
    ticketsDir = Directory(path.join(tempDir.path, 'tickets'))..createSync();
    ticketDir = Directory(path.join(ticketsDir.path, 'TICKU'))..createSync();
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

  group('UpgradeDepsCommand (ticket-wide)', () {
    test('fails outside any ticket folder', () async {
      final runner = CommandRunner<void>('test', 'do upgrade dependencies')
        ..addCommand(UpgradeDepsCommand(ggLog: ggLog));
      await expectLater(
        () async => await runner.run(['deps', '--input', tempDir.path]),
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
      final runner = CommandRunner<void>('test', 'do upgrade dependencies')
        ..addCommand(UpgradeDepsCommand(ggLog: ggLog));
      await runner.run(['deps', '--input', emptyTicket.path]);
      expect(messages, contains('⚠️ No repos in this ticket'));
    });

    test('upgrades all repos in order and forwards majorVersions: true '
        'by default', () async {
      final mock = upgradeStub();
      final runner = CommandRunner<void>('test', 'do upgrade dependencies')
        ..addCommand(UpgradeDepsCommand(ggLog: ggLog, ggDoUpgradeDeps: mock));
      await runner.run(['deps', '--input', ticketDir.path]);

      expect(
        messages,
        containsAllInOrder([
          '\nUpgrading dependencies ...',
          '\nA',
          '\nB',
          '\nAll repos upgraded\n',
        ]),
      );

      verify(
        () => mock.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          majorVersions: true,
        ),
      ).called(2);
    });

    test('forwards --no-major-versions', () async {
      final mock = upgradeStub();
      final runner = CommandRunner<void>('test', 'do upgrade dependencies')
        ..addCommand(UpgradeDepsCommand(ggLog: ggLog, ggDoUpgradeDeps: mock));
      await runner.run([
        'deps',
        '--input',
        ticketDir.path,
        '--no-major-versions',
      ]);

      verify(
        () => mock.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          majorVersions: false,
        ),
      ).called(2);
    });

    test('forwards majorVersions passed programmatically', () async {
      final mock = upgradeStub();
      final command = UpgradeDepsCommand(ggLog: ggLog, ggDoUpgradeDeps: mock);
      await command.exec(
        directory: ticketDir,
        ggLog: ggLog,
        majorVersions: false,
      );

      verify(
        () => mock.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          majorVersions: false,
        ),
      ).called(2);
    });

    test('reports the repos that failed and still tries the others', () async {
      final mock = upgradeStub(failingRepos: ['A']);
      final command = UpgradeDepsCommand(ggLog: ggLog, ggDoUpgradeDeps: mock);

      await expectLater(
        () async => await command.exec(directory: ticketDir, ggLog: ggLog),
        throwsA(
          isA<Exception>().having(
            (e) => rmControls(e.toString()),
            'message',
            'Exception: Failed to upgrade.',
          ),
        ),
      );

      expect(
        messages,
        containsAllInOrder([
          '\nA',
          '✗ Failed to upgrade\nException: Upgrade of A failed.',
          '\nB',
          '\nPlease fix the issues above.\n',
        ]),
      );

      // B was still upgraded although A failed.
      verify(
        () => mock.exec(
          directory: any(named: 'directory'),
          ggLog: any(named: 'ggLog'),
          majorVersions: true,
        ),
      ).called(2);
    });

    test('should have a code coverage of 100%', () {
      expect(() => UpgradeDepsCommand(ggLog: ggLog), returnsNormally);
      expect(MockUpgradeDepsCommand(), isNotNull);
    });
  });
}
