# gg_multi_commit

Daily ticket flows of the gg_multi tool family - committing, pushing,
reviewing and upgrading dependencies across all repos of a ticket in
dependency order.

`gg_multi` manages multi-package workspaces and orchestrates editing,
reviewing and publishing across all repos of a ticket. This package
holds the flows a ticket goes through every day; the workspace model
lives in `gg_multi_core`.

## Commands

| Command                  | Purpose                                                                             |
| ------------------------ | ----------------------------------------------------------------------------------- |
| `can commit`             | run `gg can commit` in every ticket repo (analyze + format + tests)                 |
| `can push`               | check that every ticket repo is push-ready                                          |
| `can review`             | check that every repo is on a feature branch and committed                          |
| `do commit [-m <msg>]`   | commit every ticket repo with the same message (defaults to the ticket description) |
| `do push`                | merge the main branches into the feature branches, upgrade deps, verify and push    |
| `do review`              | push, open a pull request per repo, print the urls and record the review            |
| `do upgrade deps`        | upgrade the dependencies of every ticket repo in dependency order                   |
| `did commit`             | report which repos have new commits since the last reference                        |
| `did push`               | report which repos have new pushed commits                                          |
| `did review`             | report whether the current ticket state was reviewed                                |

`do push` is the single way a ticket reaches the remote: it checks for
uncommitted changes, merges the remote main into every feature branch,
resolves and upgrades the dependencies, re-verifies with `can commit`,
records the upgrade as a `#gg:` system commit, integrates the remote
feature branch (recognizing obsolete branches left over from squash
merges) and pushes every repo.

`do review` runs `can review`, then `do push`, opens (or reuses) a pull
request per repo — linking directly to the diff — and records the
hash-based `didReview` flag that `gg do publish` requires.

## License

`gg_multi_commit` is licensed under the terms specified in the
`LICENSE` file.
