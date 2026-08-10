# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

`gg_multi_commit` holds the daily ticket flows of the gg_multi tool family: committing, pushing, reviewing and upgrading dependencies across all repos of a ticket, resolved in dependency order. The workspace *model* (ticket detection, ticket state, git snapshot helpers, the publish skip check) lives in `gg_multi_core`; workspace management in `gg_multi_workspace`; the publish orchestrator in `gg_multi_do_publish`.

All commands extend `DirCommand<T>` from `gg_args`; the primary logic lives in `get()`, and `exec()` delegates to it. `ggLog` is constructor-injected everywhere for testability. Per-repo work delegates to gg_one's commands.

## Behavior notes

### `do commit`

`DoCommitCommand` (in `lib/src/commands/do/commit.dart`) commits every ticket repo in dependency order with one shared message, delegating to gg_one's `gg do commit` per repo.

**Message resolution**: an explicit `-m`/`--message` is used as-is. Without one, the ticket description — read from the root `ticket.json` via `readTicketDescription` (gg_multi_core) — seeds the interactive editor (`interact`'s `Input`, guarded by gg_one's `throwWhenNotATerminal` so headless runs fail fast). The edited text wins; clearing it falls back to the description. When nothing resolves, `null` is forwarded and gg_one decides — it only demands a message from repos that actually have something to commit. The prompt is skipped for an empty ticket and whenever a message was passed, so `do commit -m …` stays non-interactive.

**gg's own bookkeeping commits never write a CHANGELOG entry.** Every internal `gg do commit` — the `#gg:` commits of the flows — passes `updateChangeLog: false`. The `#gg: ` prefix alone does **not** suppress the entry.

### `do push`

`DoPushCommand` (in `lib/src/commands/do/push.dart`) is the single way a ticket reaches the remote. It works standalone at any time; `do review` and `do publish`'s ticket checks run it automatically.

1. **Uncommitted-changes check** across all repos, before anything is merged (gg_git's `IsCommitted` per repo).
2. **Merge main into the feature branches**: per repo `git fetch origin <main>` + `git merge origin/<main>` (`<main>` detected via gg_publish's `MainBranch`; a repo with neither is skipped). Runs for *every* repo before *any* repo is pushed. **Merge conflicts** throw `MergeConflictException` whose message carries the full report (conflicting files + `gg do commit -m 'Merge main' --no-log`); the half-merged tree survives for the user to resolve, and `do review`/`do publish` rethrow the exception unwrapped. Any other merge failure runs `git merge --abort` and fails the push.
3. **Resolve the dependencies** (`_pubGet`): per repo `dart pub get` (`flutter pub get` in a Flutter repo) before the upgrade. Pure TypeScript repos are skipped; a failure fails the push.
4. **Upgrade the dependencies** via `do upgrade deps` (ticket-wide, dependency order): »dart pub upgrade [--major-versions] --tighten«, no checks of its own. `--(no-)major-versions` (default: on) is forwarded. `--no-upgrade` skips this step — `do publish`'s ticket-wide checks pass `upgrade: false`. Output stays visible without `--verbose`.
5. **Re-verify with `gg can commit`** (the ticket-wide `CanCommitCommand`): merge and upgrade bring in changes, so the checks only make sense after them. An unchanged repo passes quickly via the `GgState` cache.
6. **Commit the upgrade changes** as a gg system commit: per repo, when `IsCommitted` reports a dirty tree, `GgSystemCommit` writes `#gg: dart pub upgrade [--major-versions ]--tighten` (`#gg: dart pub get` when the upgrade step was skipped) — pathspec-limited to gg-owned files, with any pending user work saved in its own prefix-less commit first. It carries `stateKey: GgState.doCommitKey`: the upgrade tightened the constraints in `pubspec.yaml`, which the recorded »everything is committed« hash covers, and `gg can merge` reads that hash through `gg did commit` right after this push.
7. **Integrating the remote feature branch** (`_integrateRemoteBranch`, per repo, on the repo's *current* branch; skipped in detached HEAD): a branch that does not exist on the remote, or whose remote tip is contained in the local history, needs nothing. Otherwise the local branch is rebased onto it (`git pull --rebase`, never a force push; a rebase conflict aborts the rebase and fails with a manual hint) — _unless_ the remote branch is **obsolete**: that happens when a ticket branch was squash-merged into `main`, the provider did not delete it, and the ticket is used again. `_remoteBranchIsObsolete` says yes only when `origin/main` is contained in `HEAD` **and** every commit the remote branch holds on top of `HEAD` is either already on `origin/main` by content (`git cherry` compares patch ids, so a squash merge is recognized) or one of gg's own bookkeeping commits. A single real, unmerged commit makes it fall back to the rebase. An obsolete branch is overwritten with `git push --force-with-lease=<branch>:<remote head>` — the lease pins the hash the analysis was made from; a rejected push fails with a hint to delete the leftover branch manually.
8. **Push** via gg_one's `gg do push` per repo. Push/integration failures are collected per repo and summarized; merge, upgrade, can-commit and system-commit failures abort before any repo is pushed.

There is no snapshot/rollback machinery: the push flips no refs, so its only mutations are the main merge and the upgrade with its `#gg:` system commit — both of which are what the user wants to keep anyway.

### `do upgrade deps`

`UpgradeDepsCommand` (in `lib/src/commands/do/upgrade/deps.dart`) upgrades the dependencies of every ticket repo in dependency order by delegating to gg_one's `gg do upgrade deps` — »dart pub upgrade [--major-versions] --tighten«. The upgrade runs no checks itself; validation happens in the `gg can commit` step of the calling flow. Failures are collected per repo and summarized. `gg do push` runs it automatically, so a standalone run is only needed to upgrade without pushing. It commits nothing itself.

### `do review`

`DoReviewCommand` (in `lib/src/commands/do/review.dart`) brings the ticket in front of a reviewer: run `can review` (feature branch, lockfile sync, uncommitted changes), run `do push` automatically, **plan the release**, **open a pull request per released repo and print its url**, and record the review as `didReview` in `<ticket>/.gg.json` (`TicketState.writeSuccess`).

**The review does not touch dependency references.** The feature branches keep the local path references `do add` wrote. Whoever checks a branch out recreates the whole setup from the ticket's `ticket.json` (`gg do import ticket <path|url>`).

**The release plan** (`_planRelease`, gg_multi_core's `PublishPlanner`) runs **after the push**: `do push` merges the main branches in and refreshes the dependencies, so only then can the skip check be trusted. It answers two things at once — which repos the ticket actually releases, and with which version increment and merge message — and stores the answers in `<ticket>/.gg/gg-publish.json`, where `gg do publish` finds them and asks nothing again. **This is where the version question lives.** Asking it at publish time asked it for repos the publish then skipped; a repo that is only in the ticket because it sits between two changed packages is neither released nor reviewed.

Its edges, all of them chosen so a review never fails over a question: only what an earlier run left unanswered is asked (`PublishConfig.forRepo` decides what counts as answered); a configuration still carrying the **progress markers of an unfinished publish** is left exactly as it is — its answers are used, nothing is asked, nothing is written, because overwriting it would strand the `--continue` meant to finish that run; an unreadable file is reported and ignored; and a run without a terminal asks nothing at all (`requireAnswers: false`) and leaves the questions to the publish. Nothing is written when the ticket releases nothing.

**The pull requests** (`_createPullRequests`, gg_one's `CreatePullRequest`): opened as soon as the branches are on the remote, with **no auto-merge flag** — that is `do publish`'s job. **Only repos the plan releases get one**: a pass-through repo carries no change of its own, so a reviewer would land on an empty diff; the plan reports each skipped repo with its reason instead. A ticket that releases nothing opens no pull request at all and says so — and is still recorded as reviewed. The title is the repo's **merge message** — the very text that will describe the change when it lands — with the ticket description and finally the ticket name as fallbacks for a plan that has none; an already open pull request keeps its title. A provider that cannot be reached is reported per repo in yellow and the remaining repos are still processed — it never fails the review, and the flag is still written. The urls are collected first and printed afterwards (`GgStatusPrinter` overwrites its own line). The printed urls link **directly to the changes** (`_changesUrl`): GitHub gets `/changes` appended, Azure DevOps `?_a=files`.

**The `didReview` flag** is the pivot of the workflow: `gg did review` reports whether the _current_ state was reviewed (hash-based), and `gg do publish` refuses a state that was not. `gg do push` itself is not gated. Re-running `do review` re-pushes, reuses the pull requests and refreshes the flag.

### `did` commands

`DidReviewCommand` (in `lib/src/commands/did/review.dart`) compares the `didReview` hash against the current aggregate ticket hash (`TicketState.readSuccess`). Its `stateKey` (`'didReview'`) is the shared constant `do review` writes and the publish gate reads.

**The did commands chain**: `did review` runs `did push` first, and `did push` runs `did commit` first. Each step presupposes the previous one, so the most fundamental missing step is what the user is told about, with its own suggestion — uncommitted work reports »Please run gg do commit«, not a misleading »not pushed«/»not reviewed«.

## Code Standards

- **Line length**: 80 characters maximum.
- **Quotes**: Single quotes (`prefer_single_quotes`).
- **Trailing commas**: Required in all parameter/argument lists.
- **Return types**: Always declared explicitly.
- **Public API docs**: All public members require dartdoc comments.
- **Strict analyzer**: `strict-casts`, `strict-inference`, `strict-raw-types` enabled.
- **Test coverage**: 100% required. Every file under `lib/src/` must have a matching test at the same relative path under `test/`.
- **Mocks**: Mock classes live in the same file as the class they mock, extending `MockDirCommand`.
- **Commits/pushes**: Always go through `gg do commit` / `gg do push`, never raw `git commit` / `git push`.
