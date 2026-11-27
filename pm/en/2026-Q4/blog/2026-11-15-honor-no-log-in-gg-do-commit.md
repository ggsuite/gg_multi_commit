<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Honor --no-log in gg do commit

## Motivation

- `gg do commit` commits every repo of a ticket and writes the commit
  message into the `CHANGELOG.md` of each repo
- Some commits do not belong there: a cleanup of the CHANGELOG itself, or the
  merge commit after a conflict. The conflict report of `gg do push` even
  suggests `gg do commit -m 'Merge <main>' --no-log`
- The command offered `--no-log` (`-l`, help »Do not add message to
  CHANGELOG.md.«), but every repo still got its entry
- The only way around was `gg one do commit --no-log` in every repo, without
  the ticket-wide messages

## Strategy

- Find the place where the flag gets lost
- Hand it on to every repo, the way `--force` is handed on
- Keep the interface for callers from code: a value they pass wins
- Test the value every repo receives and the real `CHANGELOG.md`

## The flag was declared, but never read

- `_addArgs` declares the flag `log`, negatable, `true` by default
- `get()` read `message`, `force` and `no-interactive` from the parsed
  arguments, but not `log`
- So `updateChangeLog` stayed `null` and went on as `null` to gg_one's
  `gg do commit` of every repo
- Called from code, that command has no arguments of its own and falls back
  to `true`: the entry was always written

## Hand it on to every repo

- `get()` now reads the flag next to `--force`:
  `updateChangeLog ??= argResults?['log'] as bool?;`
- It reaches every way a repo gets its message: the shared `-m` or ticket
  description, the repo's own `nextCommitMessage`, the sheet in the editor
  and `--no-interactive`
- Without the flag `true` goes on, so every repo logs as before
- A caller of `get()` or `exec()` passing `updateChangeLog` still wins over
  the flag. Without either, `null` goes on and each repo decides
- gg's own `#gg:` commits are unchanged: they pass `updateChangeLog: false`
  themselves

## Tests

- The `gg do commit` stub of the tests now records `updateChangeLog`
- Six tests check the value every repo receives: `true` without the flag,
  `false` with it, `false` for a repo with its own `nextCommitMessage` —
  edited or taken without asking —, `null` when called from code, and the
  caller's value winning over a parsed `--no-log`
- Three tests commit real git repos with gg_one's real `gg do commit`
  (`-f` skips the checks): without the flag the CHANGELOG gets the entry,
  with `--no-log` no CHANGELOG is written — with `-m` and with
  `nextCommitMessage`
- Without the fix seven of the new tests fail
- Coverage stays at 100%

## Dependency updates

- The constraint on gg_one_core was tightened to `^2.19.0`. Nothing in it
  changes `gg do commit`

## Open Points

- The flag works once this version is released and installed. Until then,
  `gg one do commit --no-log` in each repo is the way around
- `-l` alone means `--log`: an abbreviation cannot negate a flag, only
  `--no-log` turns the entry off
