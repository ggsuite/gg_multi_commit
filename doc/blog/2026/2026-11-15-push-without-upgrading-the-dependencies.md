<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Push without upgrading the dependencies

## Motivation

- `gg do push` merged the main branches, resolved, **upgraded every
  dependency of every repo** (`dart pub upgrade --major-versions
  --tighten`), checked and pushed
- So every push of a ticket could bring in new versions — major versions
  included — that had nothing to do with the ticket, mixed into its change
- New versions should come in through maintenance, where they are the whole
  point of the run; a push should change only what the merged main branch
  brought in

## Strategy

- Turn the upgrade of `gg do push` off by default; keep it behind
  `--upgrade`
- Keep every other step: merge, localize, `pub get`, `can commit`, the
  system commit, the push
- Name the status line after what really happens

## Off by default

- The flag `--upgrade` defaults to `false`, and so does the parameter
  `upgrade` of `exec`/`get` when nothing is passed
- Without it, step 5 (`do upgrade deps`) is skipped; the `pub get` after the
  merge still runs, and its changes are committed as `#gg: dart pub get`
- `gg do push --upgrade` upgrades as before; `--[no-]major-versions` is
  forwarded only when given, otherwise each repository's `.gg/gg_rc`
  decides
- `gg do upgrade deps` stays the way to upgrade a ticket without pushing

## The status line

- The commit phase said »Committing upgrade changes« even when nothing was
  upgraded
- Without `--upgrade` it says »Committing the resolved dependencies«

## Tests

- A push without flags upgrades nothing, still runs `can commit` and the
  push, and shows the new status line
- The tests of the upgrade phase pass `--upgrade`
- The system commit names `--major-versions` only when the repository's
  `.gg/gg_rc` allows it — the default does not

## Dependency updates

- gg_one_core: `do.upgrade.deps.majorVersions` defaults to `false`, which is
  why the commit message of an upgrade without a flag is
  `#gg: dart pub upgrade --tighten` now

## Open Points

- None
