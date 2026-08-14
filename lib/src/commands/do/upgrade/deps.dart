// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_args/gg_args.dart';
import 'package:gg_console_colors/gg_console_colors.dart';
import 'package:gg_local_package_dependencies/gg_local_package_dependencies.dart';
import 'package:gg_log/gg_log.dart';
import 'package:gg_one/gg_one.dart' as gg;
import 'package:gg_status_printer/gg_status_printer.dart';
import 'package:path/path.dart' as path;

import 'package:gg_multi_core/gg_multi_core.dart';

/// Command to upgrade the dependencies of all repos in the current ticket.
///
/// Runs gg_one’s `gg do upgrade deps` — i.e.
/// »dart pub upgrade [--major-versions] --tighten« — in every ticket repo in
/// dependency order. Validation happens afterwards, in the `gg can commit`
/// step of the calling flow.
class UpgradeDepsCommand extends DirCommand<void> {
  /// Constructor
  UpgradeDepsCommand({
    required super.ggLog,
    super.name = 'deps',
    super.description = 'Upgrade the dependencies of all ticket repos',
    gg.DoUpgradeDeps? ggDoUpgradeDeps,
    SortedProcessingList? sortedProcessingList,
  }) : _ggDoUpgradeDeps = ggDoUpgradeDeps ?? gg.DoUpgradeDeps(ggLog: ggLog),
       _sortedProcessingList =
           sortedProcessingList ?? SortedProcessingList(ggLog: ggLog) {
    _addArgs();
  }

  /// Instance of gg DoUpgradeDeps to perform the upgrade action
  final gg.DoUpgradeDeps _ggDoUpgradeDeps;

  /// Sorted processing of repositories within a ticket
  final SortedProcessingList _sortedProcessingList;

  @override
  Future<void> exec({
    required Directory directory,
    required GgLog ggLog,
    bool? majorVersions,
    Map<String, dynamic> options = const {},
  }) => get(directory: directory, ggLog: ggLog, majorVersions: majorVersions);

  @override
  Future<void> get({
    required Directory directory,
    required GgLog ggLog,
    bool? majorVersions,
  }) async {
    ggLog(cH1('\nUpgrading dependencies ...'));

    majorVersions ??= argResults?['major-versions'] as bool? ?? true;

    // Detect if we are inside a ticket folder
    final String? ticketPath = WorkspaceUtils.detectTicketPath(
      path.absolute(directory.path),
    );
    if (ticketPath == null) {
      ggLog(cAction('Please run this command inside a ticket folder.'));
      throw Exception(cDetail('Not inside a ticket folder'));
    }

    final ticketDir = Directory(ticketPath);

    // Collect all repository directories in the ticket via SortedProcessingList
    final nodes = await _sortedProcessingList.get(
      directory: ticketDir,
      ggLog: ggLog,
    );

    if (nodes.isEmpty) {
      ggLog(cWarn('⚠️ No repos in this ticket'));
      return;
    }

    // Iterate over each repository and perform the upgrade
    final failedRepos = <String>[];
    for (final node in nodes) {
      final repoDir = node.directory;
      final repoName = path.basename(repoDir.path);
      ggLog('\n${cH1(repoName)}');
      try {
        await _ggDoUpgradeDeps.exec(
          directory: repoDir,
          ggLog: ggLog,
          majorVersions: majorVersions,
        );
      } catch (e) {
        ggLog(
          [cDetail('✗ Failed to upgrade'), cError(rmControls('$e'))].join('\n'),
        );
        failedRepos.add(repoName);
      }
    }

    // Summarize the results
    if (failedRepos.isEmpty) {
      ggLog('\nAll repos upgraded\n');
      return;
    }

    ggLog(cAction('\nPlease fix the issues above.\n'));
    throw Exception(cDetail('Failed to upgrade.'));
  }

  // Adds command line arguments
  void _addArgs() {
    argParser.addFlag(
      'major-versions',
      abbr: 'm',
      help: 'Upgrade packages to their latest versions.',
      defaultsTo: true,
      negatable: true,
    );
  }
}

/// Mock for [UpgradeDepsCommand]
class MockUpgradeDepsCommand extends MockDirCommand<void>
    implements UpgradeDepsCommand {}
