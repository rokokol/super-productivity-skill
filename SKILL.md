---
name: super-productivity
description: "Manage Super Productivity tasks through its Local REST API — list, create, edit, schedule, complete, delete, run the timer, and report tracked time. Use whenever the user talks about their tasks, TODOs, planner, deadlines or time tracking. Russian triggers: задачи, задача, таск, тудушка, туду, что у меня на сегодня, добавь задачу, поставь на завтра, отметь выполненной, закрой задачу, запусти таймер, сколько времени я потратил, статистика по задачам, супер продуктивити"
license: MIT
---

# Super Productivity

Use `sp.sh` beside this file for every Super Productivity API operation. It is not on `PATH`: resolve its full path once from the loaded skill directory and reuse it for the session. The examples call that path `sp.sh`

Run `sp.sh help` before using an unfamiliar command or flag. Do not guess the interface

## Session setup

The Local REST API requires the bearer token from **Settings → Misc → Access Token**. `sp.sh` reads `$SP_TOKEN`, then falls back to the git-ignored `secrets/token` beside the script — beside `sp.sh`, not in whatever directory the session happens to be in, where no `.gitignore` covers it

The token never passes through the agent. Ask the user to run this in their own terminal, with the directory of the resolved `sp.sh` in place of `DIR`. It reads the token without echoing it, so the value lands in neither a command line nor a transcript:

```bash
read -rs t && mkdir -p "DIR/secrets" && chmod 700 "DIR/secrets" && (umask 077 && printf '%s\n' "$t" >"DIR/secrets/token") && unset t
```

Never place the token in a command line, task, note, example, or tracked file, and never ask for it in the conversation. Exit 5 means the token is missing or rejected: ask the user to run the command above with a fresh one; never retry unauthenticated

## Operating loop

1. Read applicable private context
2. Inspect live state with `list`, `get`, `projects`, or `tags`; read-only calls need no confirmation
3. Resolve human project and tag names through `sp.sh`; never invent an id
4. Perform the smallest requested mutation
5. Read the changed state back before reporting success; an HTTP `200` alone proves nothing
6. Update private context only when the user supplied a durable preference or convention

For `set`, `done`, `archive`, `restore`, or `rm`, read the target first so its id and current state are known. Capture a newly created id with `add --json` and `.id`

## Private context

Keep durable user-specific guidance in the git-ignored `user/` directory beside `sp.sh` — never in the current directory, where it would land in someone else's repository:

```text
user/
├── preferences.md
└── projects/
    └── <local-name>.md
```

- `preferences.md` is a short bullet list of preferences for working with the tool
- Each project file starts with `# Exact project name`; match that heading rather than trusting its filename
- Read preferences before acting and the relevant project file before project-specific work
- The current request overrides cached guidance; live API state overrides stale cached facts
- Store explicit, durable preferences and conventions such as project boundaries, normal tags, estimation style, or scheduling policy. Do not infer a rule from one task
- Update an existing note instead of duplicating it. Create directories and files lazily
- Confirm a project exists with `sp.sh projects` before creating its note
- Never cache tokens, ids, task snapshots, statistics, or any fact available from the live API

## Task model

- A task belongs to one project and may have several tags
- Pass project and tag names, not ids. Resolution is case-insensitive, folds Cyrillic ё/е, and accepts a unique substring
- Exit 3 means a name is unknown or ambiguous: show the candidates and ask rather than selecting silently
- `TODAY` is a due-date query, not a real tag. Use `--due today`
- `--tag a,b` on `set` replaces the complete tag set. Use `+a` and `-b` to merge
- The plain display is flat, not hierarchical. A `sub` line is not guaranteed to belong to the nearest parent; use JSON `parentId` and `subTaskIds`
- An open subtask can outlive a done parent. If a listed task has `parentId`, fetch its parent before reorganizing the tree
- A complete audit requires `list --all --source all --json`; ordinary `list` omits done and archived tasks

## Safe writes

- Every write goes through an API allow-list. Unsupported fields can be discarded while the API still returns `ok: true`, so read back the exact fields that should have changed
- Moving a parent to another project cascades to its subtasks. Inspect the complete tree first, then verify the `projectId` of the parent and every child
- Prefer `done` or `archive` over deletion. Confirm `rm` with the user because it is irreversible
- Estimate executable leaf tasks in a decomposed task. `stats` omits parent estimates and counts leaf time only, so adding parent and child estimates double-counts the plan

## API limits

The API cannot create projects or tags, define recurring tasks, or re-parent a subtask. Ask the user to perform those actions in the app; do not simulate success

The backlog is a project-level `backlogTaskIds` list, not a task field, and the API exposes no project write. Every `add` lands in `taskIds`; `--due none` only clears the date. When asked to create a backlog task, create it normally and tell the user to drag it into the backlog in the app

Do not send guessed raw fields. For example, `PATCH /tasks/<id>` with `{"isBacklog":true}` returns success but changes nothing because the field is outside the allow-list; this is expected behavior, not an upstream defect

## Commands

```bash
sp.sh list --today
sp.sh list --project notes
sp.sh list --query docker --all
sp.sh add "Buy bread" --due tomorrow --tag home --est 30m
sp.sh add "Finish the chapter" --project notes --at "2026-08-07 09:00"
sp.sh set <id> --due +3d --tag +urgent
sp.sh done <id>
sp.sh start <id>
sp.sh stop
sp.sh stats --by project
sp.sh stats --by day --days 14
```

`stats` reads live and archived API data, never backup files. It counts leaf tasks only, which avoids counting a parent's aggregate time again

## Output and errors

```text
- <id>  <title>  @project  #tag  ~due  [spent/estimate]  (+subtasks)
```

`-` is open, `x` is done, and `sub` marks a subtask. `@project` is omitted for Inbox. Use `--json` whenever structure or exact fields matter

| Code | Meaning and response |
| ---: | --- |
| 1 | Bad usage: follow the command's diagnostic |
| 2 | App unreachable: ask the user to start the desktop app and enable **Settings → Misc → Enable local REST API** |
| 3 | Project or tag unresolved: relay the candidates and ask |
| 4 | API error: relay `code: message` verbatim |
| 5 | Token missing or rejected: ask the user to write a fresh one with the command in Session setup |
