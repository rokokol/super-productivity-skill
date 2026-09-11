<div align="center">

# Super Productivity skill

**Your task list, driven from the agent's side of the desk (๑˃ᴗ˂)ﻭ**

[![Agent Skill](https://img.shields.io/badge/Agent_Skill-6E56CF?style=flat)](https://agentskills.io)
![Bash](https://img.shields.io/badge/Bash-4EAA25?style=flat&logo=gnubash&logoColor=white)
![curl](https://img.shields.io/badge/curl-073551?style=flat&logo=curl&logoColor=white)
![jq](https://img.shields.io/badge/jq-1E90FF?style=flat)
[![license](https://img.shields.io/badge/MIT-3DA639?style=flat)](LICENSE)
[![ci](https://github.com/rokokol/super-productivity-skill/actions/workflows/build.yml/badge.svg)](https://github.com/rokokol/super-productivity-skill/actions/workflows/build.yml)

</div>

Lets an agent manage your [Super Productivity](https://super-productivity.com/) tasks through the app's **Local REST API** — no MCP server, no plugin inside SP, no background process. One `SKILL.md` and one bash script over `curl` and `jq`

Everything the agent does is a command you can run yourself, and every argument reads the way you would say it out loud: projects and tags by name, `--due tomorrow`, `--est 30m`. Where the API has no endpoint the skill refuses instead of improvising, which is the whole reason it can be trusted with a list you actually rely on

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [What it does](#what-it-does)
- [What it cannot do](#what-it-cannot-do)
- [Private context](#private-context)
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

Lists, creates, edits, schedules, completes, archives and deletes tasks, runs the built-in timer, and reports where the time went by project, tag or day. `./sp.sh help` is the complete command and flag reference — it is printed by the script itself, so it cannot drift from what the script accepts

Projects and tags are passed by **name**, not id — resolution is case-insensitive, accepts a unique substring, and folds Cyrillic ё/е, so `--project note --tag hob,craft` hits "Notes" tagged "Hobby" and "Craft". An unknown or ambiguous name exits non-zero with the candidate list instead of guessing

The script is usable on its own:

```bash
./sp.sh add "Buy bread" --due tomorrow --tag Home --est 30m
./sp.sh list --today
./sp.sh stats --by day --days 14
```

## What it cannot do

Where the REST API has no endpoint — a project or a tag cannot be created through it, for one — the skill refuses rather than pretending. The complete list, with what the agent tells you to do instead, is [API limits](SKILL.md#api-limits) in `SKILL.md`, and the quirks worth knowing, such as `TODAY` being a date query rather than a real tag, are under [Task model](SKILL.md#task-model) there

## Private context

The skill can keep durable personal conventions in `user/` inside its private directory, which `./sp.sh home` prints: the skill's own directory when it already holds `secrets/` or `user/`, so a clone you sync between machines keeps them with it, and `~/.config/super-productivity-skill` otherwise, where a plugin or `npx skills` update, which replaces the skill directory whole, cannot reach them. `SP_HOME` overrides both: `preferences.md` describes how you prefer to work with the tool, while `projects/*.md` records what belongs in existing projects, their usual tags, estimation style, or scheduling policy. These notes are a local cache rather than API state, so they never contain tokens, ids, task snapshots, or statistics, and live API data always wins when a note becomes stale

## Tests

```bash
nix develop -c ./tests/check.sh
```

Lints every bash script in the repository, found by its shebang rather than by a list; checks that `SKILL.md` still carries the frontmatter an agent loads it by, and that the plugin manifest describes it the same way and pins no version; resolves every relative link and heading anchor in the docs; holds `sp.sh help` to the script's own dispatcher, flags and variables, and every `sp.sh …` the docs spell to the same code, with the [bash-best-practices](https://github.com/rokokol/bash-best-practices-skill) skill's `check-sh.sh`; holds every API field the docs name to the fields Super Productivity declares, recorded in `tests/sp-fields.txt` from one version's `app.asar` by `tests/sp-fields.sh`, with the [ci](https://github.com/rokokol/ci-skill) skill's `check-interface.sh` — `SP_ASAR=<path to app.asar>` compares the recording with an installed app first; and drives `sp.sh` against a fake API that stands in for `curl`, asserting what it sends and which exit code it picks. Each linter and gate is shown going red on a known-bad input, one per tool, and the behaviour assertions on a probe their own helper has to reject. The secret gate is exercised end to end in throwaway repositories: red on a git-ignored path forced into the index, then red on each planted key shape in turn

## Security

Every request carries a bearer token, issued by the app under Settings → Misc → **Access Token**. The script reads it from `$SP_TOKEN`, and otherwise from `secrets/token` in the private directory above — git-ignored when that is the skill's own directory, outside any repository when it is the XDG one. Run this from the skill's directory; the value is typed at a prompt that does not echo, so it stays out of your shell history too:

```bash
read -rs t && [ -n "$t" ] && d=$(./sp.sh home)/secrets && mkdir -p "$d" && chmod 700 "$d" && (umask 077 && printf '%s\n' "$t" >"$d/token") && unset t
```

To keep the token in a clone you sync, run `mkdir secrets` in it first, so `sp.sh home` picks the clone

`SP_TOKEN_FILE` points at another file, `SP_API` overrides the base URL. A rejected or missing token exits 5 with the path to fix

> [!IMPORTANT]
> The token grants full read and write access to your tasks, so treat it like a password and keep the API bound to `127.0.0.1`
