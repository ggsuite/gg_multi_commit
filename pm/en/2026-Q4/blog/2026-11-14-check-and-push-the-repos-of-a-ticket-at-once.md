<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Check and push the repos of a ticket at once

## Motivation

- The commands of this package walk all repos of a ticket: `gg can commit`,
  `gg can push`, `gg did commit`, `gg did push`, `gg do push` and
  `gg do review`. They handled one repo after the other
- Most of that time is waiting: for git, for a remote, for the test run of
  another repo. The checks of one repo do not need those of another
- A repo that passed its checks before only confirms that. Still it waited
  behind the test runs of the repos before it
- A git host limits what one client may send at once, so »everything at
  once« is no answer either

## Strategy

- Run the per-repo steps through gg_one_core's `runInParallel`: several
  repos at the same time, reported one after the other in processing order.
  The output reads as before
- Use one limit per kind of work from gg_one_core's `GgParallelism`: test
  runs follow the machine, work at a remote gets small fixed numbers
- End a check on the first repo that fails. Let steps that change something
  finish
- Keep one by one what cannot be separated: the merges of the main branches
  and the dependency upgrade

## can commit: confirm at once, test in shared slots

- The recorded `canCommit` state of every repo is read up front
  (`GgState.readSuccess`); `--force` skips that
- A repo that passed before only confirms it and goes through with the
  `light` limit. It never waits behind a test run
- The repos that really run analyzer and tests share the
  `GgParallelism.heavy` slots: a quarter of the processors, at least one and
  at most four. A machine with fewer than eight processors checks one repo
  at a time
- Test runs side by side share the test files one run would start. Without
  that share, suites pushed each other into their test timeouts
- The share follows the repos that really have to be checked. When a single
  repo of the ticket changed, its test run gets the whole machine
- The first repo that fails ends the run. The checks of the repos after it
  are cancelled, their test runs are killed, and they are not reported
- `GG_PARALLEL=<n>` sets the number, `GG_PARALLEL=1` checks one repo after
  the other
- `can push`, `did commit` and `did push` work the same way

## do push: wait for all remotes together

- The check for uncommitted changes asks all repos at the same time
- `git fetch origin <main>` runs in all repos at the same time. The merges
  follow one by one; a failed fetch is reported where the merge of its repo
  would have followed
- `dart pub get` before the upgrade runs through gg_multi_core's
  `runInstalls`: several repos at a time where that is safe
- The `#gg:` commits of the upgrade are written at the same time
- The pushes go four at a time, whatever the machine
  (`GgParallelism.pushes`), and are reported in repo order. Failures are
  still collected per repo and summed up

## do review: ten pull requests at a time

- The pull requests of the released repos are created side by side, ten at
  a time (`GgParallelism.pullRequests`). Each belongs to a repository of its
  own
- A provider counts the requests that create something per client. GitHub
  takes 80 within a minute and 500 within an hour and locks a client out
  that sends more
- That count is not kept here. gg_merge's `MergeGit` lets a pull request
  start only while the count of the whole process allows one more
- So a review of a hundred repos creates 80 pull requests as fast as ten at
  a time go, and the rest a minute later
- A request that is turned away all the same is repeated after a wait
- The urls and the failures are reported in the order of the repos

## Open Points

- The merges of the main branches and `do upgrade deps` stay one repo after
  the other
- `do commit` and `can review` were not touched; they still walk the repos
  one by one
