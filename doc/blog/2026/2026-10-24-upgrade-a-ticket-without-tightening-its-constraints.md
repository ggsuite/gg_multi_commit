<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Upgrade a ticket without tightening its constraints

## Motivation

- `do push` upgrades the dependencies of every ticket repo before it
  pushes, and `do review` runs `do push`
- The upgrade ran `dart pub upgrade --major-versions --tighten` and could
  crash inside pub (`Entrypoint.tighten`):
  `Minimum version ("0.5.3") must be less than maximum ("0.5.0-0")`
- Inside a ticket `pubspec_overrides.yaml` points the siblings at their
  local checkouts
- A sibling `--major-versions` does not raise, like a git dependency
  declared `^0.4.0`, got its lower bound tightened to the local 0.5.3,
  while its upper bound stayed below 0.5.0
- The overrides exist as long as a ticket is worked on, so such a ticket
  could not be pushed or reviewed at all
- Besides, `do commit` asked for a message even for repos with nothing
  left to commit, and recorded that message in their publish config

## Strategy

- Never tighten inside a ticket; leave it to the publish, once the
  references point at the registry again
- Tell the per-repo upgrade explicitly not to tighten
- Name the system commit of the upgrade after what really ran
- Ask every repo whether it needs a message before prompting for one

## Implementation 1: Upgrade without `--tighten`

- `do upgrade deps` passes `tighten: false` to the upgrade of each ticket
  repo and offers no flag to change that
- `do push`, and with it `do review`, upgrades with
  `dart pub upgrade [--major-versions]` only
- Its system commit now reads `#gg: dart pub upgrade --major-versions`,
  or `#gg: dart pub upgrade` with `--no-major-versions`
- The commit still records the `doCommit` state: a major-version upgrade
  rewrites the constraints in `pubspec.yaml`
- README.md, CLAUDE.md and the code docs say why the ticket never tightens
- Tests expect `tighten: false` for every repo and the new commit messages

## Implementation 2: Ask no message of repos with nothing to commit

- Before it prompts, `do commit` asks `DoCommit.needsMessage` for each
  repo and hands `--force` on
- A repo with nothing to commit gets no prompt and records no message in
  the `commits` of its `.gg/publish_config.json`
- The shared message, the ticket description in the editor, is asked only
  when a repo without a proposal of its own needs it
- When no repo has anything to commit, no editor opens at all
- A repo that cannot tell is asked anyway, so its commit reports the error
- With `-m` the same holds: a committed repo records nothing

## Dependency updates

- `gg_one_commit`, through `gg_one`: `do upgrade deps` tightens only on
  request, with the new parameter `tighten` and flag `--[no-]tighten`; its
  mock takes `tighten`, too
- `gg_one_commit`: the new `DoCommit.needsMessage` tells whether a commit
  uses a message
- `dna_ggsuite` ^1.0.0 regenerated the guides, skills and `CLAUDE.md`
  block: a `/gg-review` skill, the rules to describe every repo in its own
  terms and to keep every repo in its scope and its `index.jsonc` current,
  and hooks that keep the prompts in the project management repo
- The routine upgrade raised `gg_multi_core`, `gg_one` and
  `pubspec_parse` to their current releases

## Result

- A ticket whose overrides point at newer siblings is pushed and reviewed
  without a crash in pub
- Committing a ticket asks only for the messages that are really used

## Open Points

- The constraints stay loose on the feature branches; the review does not
  show the tightened ones
- `do upgrade deps` offers no way to tighten on purpose; a user who wants
  tight bounds inside a ticket has to edit `pubspec.yaml` by hand
