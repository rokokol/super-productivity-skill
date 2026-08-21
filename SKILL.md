---
name: super-productivity
description: "Manage Super Productivity tasks through its Local REST API — list, create, edit, schedule, complete, delete, run the timer, and report tracked time. Use whenever the user talks about their tasks, TODOs, planner, deadlines or time tracking. Russian triggers: задачи, задача, таск, тудушка, туду, что у меня на сегодня, добавь задачу, поставь на завтра, отметь выполненной, закрой задачу, запусти таймер, сколько времени я потратил, статистика по задачам, супер продуктивити"
license: MIT
---

# Super Productivity

Run everything through `sp.sh`, the script sitting next to this file. It is not on `PATH`, so resolve its full path once from the location this skill was read from, and reuse that for the session — the examples below write it as plain `sp.sh`

`sp.sh help` prints the full flag reference — read it instead of guessing a flag

## Access token

The API authenticates every request with a bearer token from **Settings → Misc → Access Token**. `sp.sh` takes it from `$SP_TOKEN`, otherwise from `secrets/token` next to the script — a git-ignored file, so the secret never reaches the repository or the shell history:

```bash
mkdir -p secrets && chmod 700 secrets
printf '%s\n' '<token>' > secrets/token && chmod 600 secrets/token
```

Never paste the token into a command line, a task title, or this file. On exit 5 the token is missing or stale — ask the user for a fresh one and write it to that file, do not fall back to running without it

## Common calls

```bash
sp.sh list --today                          # what is due today
sp.sh list --project notes                  # one project
sp.sh list --query docker --all             # search everywhere, done included
sp.sh add "Buy bread" --due tomorrow --tag home --est 30m
sp.sh add "Finish the chapter" --project notes --at "2026-08-07 09:00"
sp.sh set <id> --due +3d --tag +urgent      # reschedule and add one tag
sp.sh done <id>                             # or several ids at once
sp.sh start <id> ; sp.sh stop               # timer
sp.sh stats --by project ; sp.sh stats --by day --days 14
```

## Rules

- Pass human names to `--project` and `--tag` — the script resolves them case-insensitively, ignores ё/е, and accepts a unique substring. Never invent an id
- On exit 3 (unknown or ambiguous name) show the user the candidate list and ask — never pick one silently
- The API cannot create projects or tags, define recurring tasks, or re-parent a subtask. Ask the user to do it in the app, do not fake it
- `TODAY` is a due-date query, not a real tag: put a task on today with `--due today`
- `--tag a,b` on `set` **replaces** every tag; use `+a` / `-b` to add or remove
- Confirm with the user before `rm` — it is irreversible. Prefer `done` (reversible) or `archive`
- To capture a new task's id, use `--json` and read `.id`
- Read-only commands are free; run `list` before `set`/`rm` so the id is real

## Output

```
- <id>  <title>  @project  #tag  ~due  [spent/estimate]  (+subtasks)
```

`-` open, `x` done, `sub` marks a subtask, `@project` is omitted for the inbox. Add `--json` for the raw payload

## Exit codes

|     |                                                                                                               |
| --- | ------------------------------------------------------------------------------------------------------------- |
| 1   | bad usage — the message says which flag                                                                       |
| 2   | Super Productivity unreachable — tell the user to start it and enable Settings → Misc → Enable local REST API |
| 3   | a project or tag name did not resolve — relay the candidates                                                  |
| 4   | API error — relay `code: message` verbatim                                                                    |
| 5   | the token is missing or rejected — see "Access token" above                                                   |

## Caveats

- `stats` is computed from the live API, not from the app's backup dumps — nothing on disk is read
- it counts leaf tasks only: a parent task stores the sum of its subtasks time, so counting both would double it
- it spans the archive too: `--source all` returns live plus archived tasks, so finishing a day does not erase history from the report
- plain `list` shows only what is not archived; reach archived work with `--source archived` or `--all`
