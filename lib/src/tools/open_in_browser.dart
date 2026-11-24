// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_process/gg_process.dart';

/// Starts [executable] with [arguments] and does not wait for it.
typedef StartDetached = Future<void> Function(
  String executable,
  List<String> arguments,
);

/// Opens web pages in the default browser of the system.
///
/// Every url is handed to the system on its own, so each one opens in a tab
/// of its own. The browser is started detached: gg neither waits for it nor
/// keeps it alive.
class OpenInBrowser {
  /// Constructor
  ///
  /// [operatingSystem] and [startDetached] replace the platform and the
  /// process start in tests.
  OpenInBrowser({String? operatingSystem, StartDetached? startDetached})
    : _operatingSystem = operatingSystem ?? Platform.operatingSystem,
      _startDetached = startDetached ?? _defaultStartDetached;

  final String _operatingSystem;
  final StartDetached _startDetached;

  /// Opens every url of [urls] in a tab of its own, in the given order.
  Future<void> open(Iterable<String> urls) async {
    for (final url in urls) {
      final [executable, ...arguments] = command(url);
      await _startDetached(executable, arguments);
    }
  }

  /// The command line that opens [url] on the current operating system:
  /// the executable first, its arguments after it.
  ///
  /// Windows uses `rundll32` instead of `cmd /c start`: `cmd` would split
  /// the url at every `&` of its query.
  List<String> command(String url) => switch (_operatingSystem) {
    'windows' => ['rundll32', 'url.dll,FileProtocolHandler', url],
    'macos' => ['open', url],
    _ => ['xdg-open', url],
  };

  // coverage:ignore-start
  static Future<void> _defaultStartDetached(
    String executable,
    List<String> arguments,
  ) => ggStartProcess(executable, arguments, mode: ProcessStartMode.detached);
  // coverage:ignore-end
}
