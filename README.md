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
| `can commit [--force]`   | run `gg can commit` in every ticket repo (analyze + format + tests)                 |
| `can push`               | check that every ticket repo is push-ready                                          |
| `can review`             | check that every repo is on a feature branch and committed                          |
| `do commit [-m <msg>]`   | commit every ticket repo; without `-m` all messages are edited on one sheet         |
| `do push`                | merge the main branches into the feature branches, upgrade deps, verify and push    |
| `do review`              | push, open a pull request per repo, print the urls and record the review            |
| `do upgrade deps`        | upgrade the dependencies of every ticket repo in dependency order                   |
| `did commit`             | report which repos have new commits since the last reference                        |
| `did push`               | report which repos have new pushed commits                                          |
| `did review`             | report whether the current ticket state was reviewed                                |

Hand-added dependencies between ticket repos are kept localized:
`can commit` refuses a ticket whose references are out of sync (and tells
you to run `gg do localize`), `do commit` localizes them first and commits
gg's own override/lock changes as a `#gg:` commit — your manifest edit
stays in your own commit — and `do push` localizes whatever the merged main
branch brought in. A ticket in sync is left untouched. A repo of the ocean
that lies between two ticket repos but is missing in the ticket is a
warning, never a stop: run `gg do add <repo>`.

`do push` is the single way a ticket reaches the remote: it checks for
uncommitted changes, merges the remote main into every feature branch,
localizes new references, resolves and upgrades the dependencies,
re-verifies with `can commit`,
records the upgrade as a `#gg:` system commit, integrates the remote
feature branch (recognizing obsolete branches left over from squash
merges) and pushes every repo. The ticket hash is recorded as `doPush`, so a
second run on an unchanged ticket returns right away — `--force` runs it
anyway, `--git-force` is what force-pushes.

`do review` runs `can review`, then `do push`, opens (or reuses) a pull
request per repo — linking directly to the diff — and records the
hash-based `didReview` flag that `gg do publish` requires. That flag also
skips the run: a state that was reviewed already returns right away, and a
version increment answered once is not asked for again. `do review --force`
ignores the flag and reviews anyway; `do review --reask-version` asks the
version increment and merge message again, with the recorded answer
pre-selected.

**One sheet instead of one prompt per repo.** Without `-m`, `do commit`
opens the commit and merge messages of every repo that has something to
commit as one `.jsonc` file in the editor (VS Code via `code --wait`, else
`GG_EDITOR`, `VISUAL` or `EDITOR`); `do review` does the same with the merge
messages and version increments of the repos it releases. Each message is a
list of lines, the first line sums it up. Save and close the file to go on;
a field left empty keeps its default — the proposal of `publish_config.json`,
else the ticket description. Without an editor the questions are asked one
by one as before. `--no-interactive` — and a run without a terminal — asks
nothing and takes the defaults; an open version increment is left to
`do publish`, which fails rather than guess it.

`publish_config.json` keeps only what actually happened and what you
changed: a commit is recorded once it was made, a merge message only when
you edited it — a confirmed default keeps following the ticket description.
When a repo fails to commit, its edited messages are kept for the next run.

## License

`gg_multi_commit` is licensed under the terms specified in the
`LICENSE` file.
