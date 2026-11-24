// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:gg_multi_commit/src/tools/open_in_browser.dart';
import 'package:test/test.dart';

void main() {
  group('OpenInBrowser', () {
    const url = 'https://dev.azure.com/o/p/_git/r/pullrequest/1?_a=files&x=1';

    for (final (os, command) in [
      ('linux', ['xdg-open', url]),
      ('macos', ['open', url]),
      // rundll32 keeps the & of the url, cmd /c start would split there.
      ('windows', ['rundll32', 'url.dll,FileProtocolHandler', url]),
    ]) {
      test('opens a url on $os with ${command.first}', () {
        expect(OpenInBrowser(operatingSystem: os).command(url), command);
      });
    }

    test('defaults to the current operating system', () {
      expect(
        OpenInBrowser().command(url),
        OpenInBrowser(operatingSystem: Platform.operatingSystem).command(url),
      );
    });

    test('starts one process per url, in the given order', () async {
      final started = <List<String>>[];
      final open = OpenInBrowser(
        operatingSystem: 'linux',
        startDetached: (executable, arguments) async =>
            started.add([executable, ...arguments]),
      );

      await open.open(['https://a', 'https://b']);

      expect(started, [
        ['xdg-open', 'https://a'],
        ['xdg-open', 'https://b'],
      ]);
    });
  });
}
