// @license
// Copyright (c) 2019 - 2026 Dr. Gabriel Gatzsche. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_multi_commit/gg_multi_commit.dart';
import 'package:test/test.dart';

void main() {
  group('GgMultiCommit()', () {
    group('foo()', () {
      test('should return foo', () async {
        const ggMultiCommit = GgMultiCommit();
        expect(ggMultiCommit.foo(), 'foo');
      });
    });
  });
}
