# Changelog

Kept in the shape of [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), dated rather than numbered, and with no `Unreleased` section — a skill is read at whatever revision you have checked out, so whatever is on the default branch is what every reader already has, and a section for work that has landed but not shipped would never close. The rule lives in the [versioning](https://github.com/rokokol/versioning-skill) skill, which owns what has no version

Written after the fact from the repository's history, so the entries below say what each change did rather than reproducing the reasoning; the commit bodies carry that

## 2026-09-10

### Added

- a `macos` job in CI that runs the behaviour half of `tests/check.sh` on a macOS runner, under the `/bin/bash` 3.2 and the BSD `date` that system ships, with `jq` from the image, printing each one's version first. It gates pull requests: what turns it red is nearly always a change that uses something only GNU or bash 4 has. `tests/check.sh` takes `lint`, `behaviour` or `all`, and works its expected dates out on whichever `date` the machine has, since the test's own arithmetic had used GNU's `-d`
- the fake BSD `date` behind the Linux half now takes a time field the value leaves out from the current time, as BSD `date` does, instead of zero; the expectations' BSD branch is held to the GNU one through it

### Fixed

- **on macOS, `set --tag +a` and `set --tag -a` died with "unbound variable".** The bash 3.2 macOS ships calls an empty array unbound under `set -u`, and a merge that only adds leaves the removals empty, as one that only removes leaves the additions. The new macOS job found it on its first run; every list sp.sh walks now expands safely when empty
- the private `user/` context is placed beside `sp.sh` explicitly, not in whatever directory the session happens to be in
- **`set <id> --tag foo-bar` was a silent no-op.** A hyphen anywhere in the value switched `set` into merge mode, where only items starting with `+` or `-` count, so the task's current tags were sent back unchanged. Only an item's first character decides its role now, and a value mixing both forms is refused
- `stats --by project` and `--by tag` ignored `--days`; with it they now count only the time spent inside that window
- `--days 7` covered eight days
- exit codes that meant something else: a failing jq surfaced as 3 ("name unresolved") or 5 ("token rejected") and now exits 6; `list --limit abc` and a malformed `--days` are usage errors; an `SP_API` that curl cannot parse exits 1 rather than 2 ("app unreachable")
- `projects` and `tags` ignored `--json`, while the readme said every command honoured it
- the plugin manifest carried `"version": "0.1.0"` and never bumped it, and Claude Code skips an update whose version it already has, so a plugin install stayed at its first copy. The manifest now has no version, and Claude Code versions the plugin by commit
- the gate had said since 2026-09-03 that every check was proven able to fail, while `bash -n`, shellcheck, shfmt and the frontmatter check had never been shown a bad input
- **a task whose id opens with `-` could not be named.** Ids are nanoids, whose alphabet has `-` in it, and every command took such an id for an unknown flag, so `set`, `get`, `done` and the rest failed with a usage error on an id copied straight from `list`. A word of an id's shape is taken as an id now, and `help` and `SKILL.md` say that `--` ends the options

### Changed

- `SKILL.md` says why a decomposed task is estimated on its subtasks — the app recomputes a parent's estimate from them — which subtask to delete last so flattening a tree keeps its tracked time, and when a note renders as a checklist
- the token and the `user/` notes stay in the skill directory only when it already holds them, as a synced clone does, and otherwise go to `$XDG_CONFIG_HOME/super-productivity-skill` — `sp.sh home` prints which, `SP_HOME` overrides it, and the layout is `secrets/token` and `user/` in both. A plugin or `npx skills` update replaces the skill's directory whole, and with the manifest no longer pinning a version every update would have taken them along
- dates work with BSD `date`, the one macOS ships: `--due`, `--at` and the `stats` window used GNU's `date -d`, and the script found itself with `readlink -f`, which older macOS lacks. `--at` now takes exactly the documented `YYYY-MM-DD HH:MM`, and a day that does not exist is refused on both kinds of `date`
- the readme points at `sp.sh help` and at `SKILL.md`'s API limits instead of keeping its own copies, which had drifted: the command table had no `get` and offered `--parent` to `set`, and the four lists of API limits disagreed
- the description names the capabilities it lacked and says it means the Super Productivity list rather than the agent's own checklist; its Russian triggers are phrases from ordinary speech
- the gate finds scripts by shebang and docs by extension rather than from hand lists, holds the manifest to `SKILL.md`, and drives `sp.sh` against a fake API standing in for `curl`

### Security

- **the token could land in some other repository, and in the transcript.** The setup snippet wrote to a relative `secrets/token`, so run from any other directory it created the file where no `.gitignore` covered it, and it put the token itself on the command line — into shell history, and for an agent into the transcript — which the very next paragraph forbade. The token now never passes through the agent: the user types it at a prompt that does not echo, into the `secrets/` beside `sp.sh`. The README carried the same snippet and claimed it kept the token out of shell history

## 2026-09-07

### Added

- a private, git-ignored `user/` context for durable tool preferences and conventions associated with existing Super Productivity projects; the context is a cache of explicit user guidance rather than a copy of live API state
- a CI guard that rejects every tracked path covered by `.gitignore`, including private files forced into the index with `git add -f`, with an end-to-end negative test proving the guard can fail
- task-tree safety rules measured against the live API: plain output is not hierarchical, a done parent can be hidden while its open children remain visible, project moves cascade from parent to children, and complete audits must include done and archived tasks

### Changed

- `SKILL.md` now follows one operating flow from private context and live reads through safe writes and verification, with task semantics, API limits, commands, and diagnostics grouped by purpose instead of accumulated in one rules list

## 2026-09-04

### Added

- the rule that the backlog is out of the API's reach, measured against 18.20.1 on a real project and rolled back afterwards. The backlog is not a task field but `backlogTaskIds` on the project, and the API has no project write at all — `PATCH` and `PUT` on `/projects/<id>` both answer NOT_FOUND, and there is no move endpoint, so every task the API creates lands in `taskIds`
- the rule that follows from it and matters more: **read the state back rather than trusting the status code.** `PATCH /tasks/<id>` with `{"isBacklog":true}` answers `ok: true` and moves nothing, because writes go through an allow-list and a key outside it is silently dropped. That is the allow-list working as designed, so a client trusting the status code announces a move that never happened — which is exactly what happened before this was written down

## 2026-09-03

### Added

- a CI gate, where the repository had none: a broken `sp.sh`, a dangling readme link or a token pasted into a doc would all have shipped unnoticed. `tests/check.sh` lints and parses the scripts, holds `SKILL.md` to the frontmatter an agent loads it by, resolves every relative link and heading anchor, and lints the workflow — each followed by a known-bad fixture it has to redden on, so none of them can quietly become a decoration
- the secret gate, exercised end to end in a throwaway repository: clean while scanning only its own source, then red on each of the ten planted shapes in turn. The fixture generates every value from a split prefix, since a literal key committed here would be a finding for the gate itself and for push protection

### Changed

- the readme took the family shape

## 2026-08-22

### Fixed

- a multiline `--notes` value is kept in one JSON string rather than being split

## 2026-08-21

### Changed

- the access token is read from a git-ignored secrets file instead of being passed around

## 2026-08-06

### Added

- the skill itself: managing Super Productivity tasks over its Local REST API — list, create, edit, schedule, complete, delete, run the timer, report tracked time
