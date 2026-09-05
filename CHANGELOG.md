# Changelog

Kept in the shape of [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), dated rather than numbered, and with no `Unreleased` section — a skill is read at whatever revision you have checked out, so whatever is on the default branch is what every reader already has, and a section for work that has landed but not shipped would never close. The rule lives in the [ci](https://github.com/rokokol/ci-skill) skill, which owns what has no version

Written after the fact from the repository's history, so the entries below say what each change did rather than reproducing the reasoning; the commit bodies carry that

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
