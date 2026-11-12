<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Let each repository decide on major upgrades

## Motivation

- `gg do push` and `gg do upgrade deps` always forwarded
  `majorVersions: true` to each repository's upgrade, unless
  `--no-major-versions` was given
- A repository can now forbid crossing majors in its `.gg/gg_rc`
  (`do.upgrade.deps.majorVersions: false`); a forwarded `true` would
  have overruled it, because an explicit value wins over the file
- The bookkeeping commit after the upgrade named `--major-versions` for
  every repository, also where the upgrade ran without it

## Strategy

- Forward `--[no-]major-versions` only when it was given on the command
  line; otherwise forward nothing and let each repository's `.gg/gg_rc`
  decide
- Name the flag in the commit message per repository, from the same
  decision the upgrade made

## do upgrade deps and do push

- `argResults.wasParsed('major-versions')` tells a given flag from its
  default; without it `majorVersions` stays `null`
- gg_one_commit's `DoUpgradeDeps` then reads the repository setting
- The help of `--major-versions` says that the repository file decides
  when the flag is left out

## The upgrade commit of do push

- The message is built per repository with
  `DoUpgradeDeps.effectiveMajorVersions(repo, explicit:)`
- »#gg: dart pub upgrade --major-versions --tighten« where majors were
  crossed, »#gg: dart pub upgrade --tighten« where they were not
- A new test covers a repository whose `.gg/gg_rc` forbids majors

## Dependency updates

- gg_one_core: `GgRc` reads the repository's `.gg/gg_rc`
- gg_one_commit: `DoUpgradeDeps` follows `do.upgrade.deps.majorVersions`
  and exposes `effectiveMajorVersions`

## Open Points

- None
