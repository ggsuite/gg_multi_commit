# Changelog

## 3.1.1 - 2026-08-11

### Changed

- Provide gg via npm
- Fix shell changes

## 3.1.0 - 2026-08-10

### Changed

- `do commit` proposes a repository's own `nextCommitMessage`, enforces the 60-character first line and records the commit in that repository's `commits`
- `do review` stores the answers per repository and passes the recorded commits as the pull-request description
- Refactor commit messages, version increment

## 3.0.1 - 2026-08-10

### Changed

- Make sure »dart pub upgrade --tighten --major-versions« is called before publishing

## 3.0.0 - 2026-08-10

## 2.3.1 - 2026-08-10

### Fixed

- Various log and color fixes across the gg command output

## 2.3.0 - 2026-08-10

### Changed

- Don't review skipped packages
- Merge origin/main

## 2.2.1 - 2026-08-10

### Removed

- Merge .ticket with ticket.json. Remove usage of .ticket

## 2.2.0 - 2026-08-09

### Changed

- Improve commit behavior
- Move gg commit conventions from gg_git to gg_one_core
- Move the git and process plumbing to gg_git
- Record the doCommit state in system commits again

## 2.1.0 - 2026-08-09

## 2.0.0 - 2026-08-08

### Changed

- Allow to pass custom options to exec of dir commands.

## 1.0.2 - 2026-08-07

### Fixed

- Fix issue with azure URLs
- Fix: The pull request for »dna« was created, but its url could not be read

## 1.0.1 - 2026-08-05

### Changed

- Make pana work: 1.0.0 changelog headings, examples, shorter description

## 1.0.0 - 2026-08-05

### Added

- Initial boilerplate.

### Changed

- Split gg_multi into multiple packages
