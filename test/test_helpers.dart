// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_git/gg_git_test_helpers.dart';
import 'package:gg_local_package_dependencies/gg_local_package_dependencies.dart';
import 'package:gg_multi_core/gg_multi_core.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as path;

/// The ticket of `test/sample_folder/hand_added_dependency`: two repos `a`
/// and `b` without dependencies, each a git repo on the feature branch `TICK`
/// whose initial commit is tagged `sample`.
Future<Directory> createSampleTicket(Directory tempDir) async {
  final ticketDir = Directory(path.join(tempDir.path, 'tickets', 'TICK'))
    ..createSync(recursive: true);
  final sample = Directory(
    path.join('test', 'sample_folder', 'hand_added_dependency'),
  );
  for (final file in sample.listSync(recursive: true).whereType<File>()) {
    final target = File(
      path.join(ticketDir.path, path.relative(file.path, from: sample.path)),
    )..parent.createSync(recursive: true);
    file.copySync(target.path);
  }
  for (final repo in ['a', 'b']) {
    final repoDir = sampleRepo(ticketDir, repo);
    await initGit(repoDir);
    await commitFile(repoDir, '.', message: 'Initial commit');
    await runGit(repoDir, ['tag', 'sample']);
    await runGit(repoDir, ['checkout', '-b', 'TICK']);
  }
  return ticketDir;
}

// .............................................................................
/// The repo [name] of the sample ticket in [ticketDir].
Directory sampleRepo(Directory ticketDir, String name) =>
    Directory(path.join(ticketDir.path, name));

// .............................................................................
/// Adds [dependency] to the pubspec of [repo] — the edit a user makes by
/// hand and the ticket flows have to localize. [commit] commits it.
Future<void> addDependency(
  Directory repo,
  String dependency, {
  bool commit = false,
}) async {
  File(path.join(repo.path, 'pubspec.yaml')).writeAsStringSync(
    '\ndependencies:\n  $dependency: ^1.0.0\n',
    mode: FileMode.append,
  );
  if (commit) {
    await commitFile(repo, 'pubspec.yaml', message: 'Add $dependency');
  }
}

// .............................................................................
/// The trimmed output of `git <args>` in [repo]; throws when git fails.
Future<String> runGit(Directory repo, List<String> args) async {
  final result = await Process.run('git', args, workingDirectory: repo.path);
  if (result.exitCode != 0) {
    throw Exception('git ${args.join(' ')} failed: ${result.stderr}');
  }
  return (result.stdout as String).trim();
}

// .............................................................................
/// A [TicketLocalizer] finding every ticket in sync, so the tests of the
/// other steps run no real localization.
MockTicketLocalizer inSyncTicketLocalizer() {
  registerFallbackValue(Directory(''));
  registerFallbackValue(<Node>[]);
  final localizer = MockTicketLocalizer();
  when(
    () => localizer.throwWhenOutOfSync(
      ticketDir: any(named: 'ticketDir'),
      repos: any(named: 'repos'),
      ggLog: any(named: 'ggLog'),
    ),
  ).thenAnswer((_) async {});
  when(
    () => localizer.localizeUnlocalized(
      ticketDir: any(named: 'ticketDir'),
      repos: any(named: 'repos'),
      ggLog: any(named: 'ggLog'),
      warnMissingRepos: any(named: 'warnMissingRepos'),
    ),
  ).thenAnswer((_) async => <String>[]);
  return localizer;
}

// .............................................................................
/// Puts the repo [name] depending on [dependency] into the ocean next to the
/// tickets of [tempDir], so it lies between two ticket repos.
void addOceanRepo(Directory tempDir, String name, String dependency) {
  File(path.join(tempDir.path, '.ocean', 'org', name, 'pubspec.yaml'))
    ..createSync(recursive: true)
    ..writeAsStringSync(
      'name: $name\nversion: 1.0.0\n'
      'dependencies:\n  $dependency: ^1.0.0\n',
    );
}

// .............................................................................
/// The subjects of the commits made in [repo] since the sample was created,
/// newest first.
Future<List<String>> commitSubjects(Directory repo) async {
  final log = await runGit(repo, ['log', '--format=%s', 'sample..HEAD']);
  return [
    for (final line in log.split('\n'))
      if (line.isNotEmpty) line,
  ];
}

// .............................................................................
/// The paths `git status` reports as changed in [repo].
Future<List<String>> dirtyFiles(Directory repo) async {
  final result = await Process.run('git', [
    'status',
    '--porcelain',
    '--untracked-files=all',
  ], workingDirectory: repo.path);
  final status = result.stdout as String;
  return [
    for (final line in status.split('\n'))
      if (line.trim().isNotEmpty) line.substring(3),
  ];
}
