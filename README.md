<div align="center">

# Super Productivity skill

**Your task list, driven from the agent's side of the desk (๑˃ᴗ˂)ﻭ**

![Claude Code](https://img.shields.io/badge/Claude_Code-D97757?style=flat&logo=anthropic&logoColor=white)
![Bash](https://img.shields.io/badge/Bash-4EAA25?style=flat&logo=gnubash&logoColor=white)
![curl](https://img.shields.io/badge/curl-073551?style=flat&logo=curl&logoColor=white)
![jq](https://img.shields.io/badge/jq-1E90FF?style=flat)
[![license](https://img.shields.io/badge/MIT-3DA639?style=flat)](LICENSE)
[![ci](https://github.com/rokokol/super-productivity-skill/actions/workflows/ci.yml/badge.svg)](https://github.com/rokokol/super-productivity-skill/actions/workflows/ci.yml)

</div>

Lets an agent manage your [Super Productivity](https://super-productivity.com/) tasks through the app's **Local REST API** — no MCP server, no plugin inside SP, no background process. One `SKILL.md` and one bash script over `curl` and `jq`

Everything the agent does is a command you can run yourself, and every argument reads the way you would say it out loud: projects and tags by name, `--due tomorrow`, `--est 30m`. Where the API has no endpoint the skill refuses instead of improvising, which is the whole reason it can be trusted with a list you actually rely on

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [What it does](#what-it-does)
- [What it cannot do](#what-it-cannot-do)
- [Tests](#tests)
- [Security](#security)

## Requirements

- Super Productivity **desktop** 18+ with Settings → Misc → **Enable local REST API** (the API listens on `127.0.0.1:3876`, desktop only — not web, not mobile)
- the access token from Settings → Misc → **Access Token** (see [Security](#security))
- `bash`, `curl`, `jq`

## Install

```bash
npx skills add -g rokokol/super-productivity-skill
```

`-g` installs it for you rather than into the directory you happen to be standing in — your task list is not a property of one repository. The files land in `.agents/skills/` and are symlinked into every agent found on the machine

Claude Code also takes it as a plugin:

```
/plugin marketplace add rokokol/super-productivity-skill
/plugin install super-productivity@rokokol-skills
```

or by hand — clone into whichever skills directory your agent reads:

```bash
git clone https://github.com/rokokol/super-productivity-skill \
  ~/.claude/skills/super-productivity
```

> [!NOTE]
> A skill has no version to pin — it is read at whatever revision you have checked out, so `git pull` is the whole upgrade path

## What it does

| Command | |
|---|---|
| `list` | filter by `--project`, `--tag`, `--query`, `--today`, `--done`, `--all`, `--source` |
| `add` | title plus `--project`, `--tag a,b`, `--due`, `--at`, `--est`, `--notes`, `--parent` |
| `set` | any of the above, plus `--title`, `--done`/`--undone`, and `+tag`/`-tag` merging |
| `done` / `rm` / `archive` / `restore` | accept several ids at once |
| `start` / `stop` | the built-in time tracker |
| `stats` | tracked time and open/done counts, `--by project\|tag\|day`, `--days N` |
| `projects` / `tags` / `health` / `current` | ids, titles, server state |

Projects and tags are passed by **name**, not id — resolution is case-insensitive, accepts a unique substring, and folds Cyrillic ё/е, so `--project note --tag hob,craft` hits "Notes" tagged "Hobby" and "Craft". An unknown or ambiguous name exits non-zero with the candidate list instead of guessing

The script is usable on its own:

```bash
./sp.sh add "Buy bread" --due tomorrow --tag Home --est 30m
./sp.sh list --today
./sp.sh stats --by day --days 14
```

`./sp.sh help` prints the full flag reference, and `--json` turns any command into machine-readable output

## What it cannot do

The REST API has no endpoint for these, so the skill refuses rather than pretending:

- creating or renaming projects and tags (`POST /projects` and `POST /tags` return 404) — make them in the app
- recurring tasks
- re-parenting a subtask (`parentId` is immutable on PATCH)
- notes as standalone entities, boards

Two more quirks worth knowing: `TODAY` is a due-date query rather than a real tag, so a task goes on today's list via `--due today`; and archived tasks are hidden from a plain `list` — reach them with `--source archived` or `--all`, which is also what makes `stats` span finished days

## Tests

```bash
nix develop -c ./tests/check.sh
```

Lints the scripts, checks that `SKILL.md` still carries the frontmatter an agent loads it by, and resolves every relative link and heading anchor in the docs — then proves each of those can go red against a known-bad fixture. The secret gate is exercised end to end in a throwaway repository: clean while scanning only its own source, then red on each planted key shape in turn

## Security

Every request carries a bearer token, issued by the app under Settings → Misc → **Access Token**. The script reads it from `$SP_TOKEN`, and otherwise from `secrets/token` beside the script — that path is git-ignored, which keeps the secret out of the repository and out of your shell history:

```bash
mkdir -p secrets && chmod 700 secrets
printf '%s\n' '<token>' > secrets/token && chmod 600 secrets/token
```

`SP_TOKEN_FILE` points somewhere else, `SP_API` overrides the base URL. A rejected or missing token exits 5 with the path to fix

> [!IMPORTANT]
> The token grants full read and write access to your tasks, so treat it like a password and keep the API bound to `127.0.0.1`
