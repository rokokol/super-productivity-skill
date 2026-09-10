#!/usr/bin/env bash
# The whole gate. Nothing here reaches the network or a package registry, so it
# is safe to run on pull requests — and every check below is followed by proof
# that it can go red, because a check that has never failed is a decoration: each
# linter and gate against a known-bad input, the behaviour assertions through a
# probe their own helper has to reject
#
#   check.sh [lint|behaviour|all]
#
# lint needs shellcheck, shfmt, actionlint and jq, behaviour needs jq alone — from PATH;
# CI provides them through nix develop. behaviour is also what the macOS job runs, under
# the bash and date that system ships, since the linters say the same on every platform:
#
#   /bin/bash ./tests/check.sh behaviour        # on a macOS runner
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$HERE"

fail() {
  echo "check: $1" >&2
  exit 1
}

mode="${1:-all}"
case "$mode" in
  lint | behaviour | all) ;;
  *) fail "no such mode: '$mode' — lint, behaviour or all" ;;
esac

# What gets linted is read off the repository rather than kept in a list that a new
# file silently misses: every file git knows about (tracked, or new and not ignored)
# whose first line names bash is a script, every markdown file outside the fixtures is
# a doc. The must-fail fixtures are the exception, exercised on their own below
scripts=() docs=()
while IFS= read -r f; do
  [ -f "$f" ] || continue
  case $f in tests/fixtures/must-fail*) continue ;; esac
  case $f in tests/fixtures/*.md) ;; *.md) docs+=("$f") ;; esac
  first=''
  IFS= read -r first <"$f" || true
  [[ $first == '#!'*bash* ]] && scripts+=("$f")
done < <(git ls-files --cached --others --exclude-standard)
[[ " ${scripts[*]} " == *" sp.sh "* && " ${docs[*]} " == *" SKILL.md "* ]] ||
  fail "file discovery lost sp.sh or SKILL.md — it is broken, not the repository"
# sp.sh keeps its own one-line case arms on purpose; every other script is shfmt's
formatted=()
for s in "${scripts[@]}"; do [ "$s" = sp.sh ] || formatted+=("$s"); done

if [ "$mode" != behaviour ]; then
  echo "== the scripts parse and lint (${#scripts[@]} scripts)"
  for s in "${scripts[@]}"; do bash -n "$s"; done
  shellcheck "${scripts[@]}"
  shfmt -d -i 2 -ci "${formatted[@]}"

  echo "== each linter is able to fail, on a fixture only it should reject"
  # One fixture per tool, each clean for the others, so a linter that went quiet
  # cannot hide behind a neighbour that fails the same file for another reason
  for f in tests/fixtures/must-fail-lint.sh tests/fixtures/must-fail-format.sh; do
    bash -n "$f" || fail "$f is meant for shellcheck or shfmt, but does not even parse"
  done
  shellcheck tests/fixtures/must-fail-format.sh ||
    fail "the shfmt fixture trips shellcheck too, so it proves nothing about shfmt"
  if bash -n tests/fixtures/must-fail-parse.sh 2>/dev/null; then
    fail "bash -n passed tests/fixtures/must-fail-parse.sh — it cannot catch anything"
  fi
  if shellcheck tests/fixtures/must-fail-lint.sh >/dev/null; then
    fail "shellcheck passed tests/fixtures/must-fail-lint.sh — it cannot catch anything"
  fi
  if shfmt -d -i 2 -ci tests/fixtures/must-fail-format.sh >/dev/null; then
    fail "shfmt passed tests/fixtures/must-fail-format.sh — it cannot catch anything"
  fi

  echo "== the workflows pass actionlint"
  actionlint .github/workflows/*.yml

  echo "== the workflow lint is able to fail"
  bad=$(mktemp -d)
  mkdir -p "$bad/.github/workflows"
  cp tests/fixtures/must-fail.yml "$bad/.github/workflows/"
  if (cd "$bad" && actionlint .github/workflows/*.yml >/dev/null 2>&1); then
    rm -rf "$bad"
    fail "actionlint passed tests/fixtures/must-fail.yml — it cannot catch anything"
  fi
  rm -rf "$bad"

  # SKILL.md's frontmatter is the vendored check-skill.sh's to judge, further down, with its
  # own planted copies; what is left here is the manifest, which has to agree with it
  planted=$(mktemp -d)

  echo "== the plugin manifest describes the skill as SKILL.md does, and pins no version"
  # The manifest's description cannot reference SKILL.md's, so it is held to be the
  # first sentence of it. A version pins every user to that string until somebody
  # bumps it by hand; without one Claude Code versions the plugin by commit
  manifest_problem() { # manifest_problem MANIFEST — prints what is wrong, nothing if sound
    local want got
    if jq -e '.plugins[] | has("version")' "$1" >/dev/null; then
      echo "carries a version, which freezes every install at that string"
      return
    fi
    want=$(sed -n 's/^description: "\([^.]*\)\..*/\1/p' SKILL.md)
    got=$(jq -r '.plugins[0].description' "$1")
    [ "$want" = "$got" ] || echo "description \"$got\" is not the first sentence of SKILL.md's: \"$want\""
  }
  why=$(manifest_problem .claude-plugin/marketplace.json)
  [ -z "$why" ] || fail "marketplace.json $why"
  jq '.plugins[0].version = "1.0.0"' .claude-plugin/marketplace.json >"$planted/versioned.json"
  jq '.plugins[0].description += " and more"' .claude-plugin/marketplace.json >"$planted/drifted.json"
  for f in "$planted"/*.json; do
    [ -n "$(manifest_problem "$f")" ] || {
      rm -rf "$planted"
      fail "the manifest check passed a copy planted as ${f##*/}"
    }
  done
  rm -rf "$planted"

  echo "== the vendored checkers are byte-equal to their source"
  # check-skill.sh and check-pins.sh come from the ci skill: every copy must still be the
  # blob .github/vendor.lock records, so one edited here instead of at its source fails by name
  ./vendor-sync.sh check

  echo "== the workflows take no tool from a registry"
  # The ci skill's pin guard, which proves on every run that it catches each unpinned shape
  ./check-pins.sh

  echo "== SKILL.md loads, every reference is reachable, and every link and anchor resolves"
  # The one gate every skill repository shares, each check proven able to fail on a planted
  # copy on every run
  ./check-skill.sh -n super-productivity .

  echo "== the secret gate is quiet on this repository"
  ./tests/no-secrets.sh

  echo "== the secret gate rejects a tracked path covered by .gitignore"
  ignored=$(mktemp -d)
  git -C "$ignored" init -q
  git -C "$ignored" config user.email ci@example.invalid
  git -C "$ignored" config user.name ci
  mkdir -p "$ignored/tests" "$ignored/user"
  cp tests/no-secrets.sh "$ignored/tests/"
  printf 'user/\n' >"$ignored/.gitignore"
  printf 'private preference\n' >"$ignored/user/preferences.md"
  git -C "$ignored" add .gitignore tests/no-secrets.sh
  git -C "$ignored" add -f user/preferences.md
  if out=$(cd "$ignored" && ./tests/no-secrets.sh 2>&1); then
    rm -rf "$ignored"
    fail "the secret gate allowed an ignored path added with git add -f"
  fi
  if ! printf '%s\n' "$out" | grep -qxF "secret-gate: tracked path is covered by .gitignore: user/preferences.md"; then
    printf '%s\n' "$out" >&2
    rm -rf "$ignored"
    fail "the secret gate rejected an ignored tracked path without naming it"
  fi
  rm -rf "$ignored"

  echo "== the secret gate catches every shape it claims"
  # Exercised in a throwaway repository rather than by re-testing its regexes here:
  # the gate's subject is "what git tracks", and only a real repository answers that
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  git -C "$work" init -q
  git -C "$work" config user.email ci@example.invalid
  git -C "$work" config user.name ci
  mkdir -p "$work/tests"
  cp tests/no-secrets.sh "$work/tests/"
  git -C "$work" add -A
  # Clean first, with no .gitignore: the gate is now scanning its own source, so a
  # pattern matching its own text would surface right here
  (cd "$work" && ./tests/no-secrets.sh >/dev/null 2>&1) ||
    fail "the secret gate reddens on its own source — a pattern is matching its own text"
  # Then one planted value per shape, each alone, so one over-broad pattern cannot
  # cover for a dead one
  i=0
  while IFS= read -r line; do
    i=$((i + 1))
    printf '%s\n' "$line" >"$work/planted.txt"
    git -C "$work" add -A
    if (cd "$work" && ./tests/no-secrets.sh >/dev/null 2>&1); then
      printf 'the gate stayed green on: %s…\n' "${line:0:16}" >&2
      fail "a planted secret shape went unnoticed — see tests/fixtures/planted-secrets.sh"
    fi
    rm -f "$work/planted.txt"
    git -C "$work" add -A
  done < <(./tests/fixtures/planted-secrets.sh)
  [ "$i" -gt 0 ] || fail "planted-secrets.sh produced nothing to plant"
  echo "   $i shapes planted, $i caught"
fi

if [ "$mode" != lint ]; then
  # The expected dates are worked out on whichever date this machine has — GNU's -d, or the
  # -v and -j -f of the BSD date macOS ships — because the test's own arithmetic must not be
  # the GNU-only thing it exists to catch. BSD's -j -f takes any field the format leaves out
  # from the current time, seconds included, so epoch_at spells the seconds out
  gnu_day_offset() { date -d "$1 days" +%F; } # N -> the date N days from today
  gnu_epoch_at() { date -d "$1" +%s; }        # 'YYYY-MM-DD HH:MM' -> seconds since the epoch
  bsd_day_offset() {
    local sign=+
    [ "$1" -lt 0 ] && sign=''
    date -v"$sign$1"d +%F
  }
  bsd_epoch_at() { date -j -f '%Y-%m-%d %H:%M:%S' "$1:00" +%s; }
  if date -d now >/dev/null 2>&1; then
    host_date=gnu
    day_offset() { gnu_day_offset "$@"; }
    epoch_at() { gnu_epoch_at "$@"; }
  else
    host_date=bsd
    day_offset() { bsd_day_offset "$@"; }
    epoch_at() { bsd_epoch_at "$@"; }
  fi

  echo "== sp.sh against a fake API: what it sends and how it exits"
  # tests/fixtures/fake-curl stands in for curl and answers from files, so these run
  # with no Super Productivity and no network. Dates are relative to today because
  # the stats window is
  fake=$(mktemp -d)
  # work belongs to the lint half, which a behaviour-only run never creates
  trap 'rm -rf "${work:-}" "$fake"' EXIT
  mkdir -p "$fake/api" "$fake/broken"
  cp tests/fixtures/fake-sp/*.json "$fake/api/"
  jq -n --arg d0 "$(date +%F)" --arg d6 "$(day_offset -6)" --arg d7 "$(day_offset -7)" '[{
  id: "t1", title: "Water plants", projectId: "p-notes", tagIds: ["t-home"], isDone: false,
  timeSpent: 10800000, timeEstimate: 0, subTaskIds: [],
  timeSpentOnDay: {($d0): 3600000, ($d6): 3600000, ($d7): 3600000}
}, {
  id: "-3PluTV--NWbvqa0eL_VM", title: "An id that opens with a dash", projectId: "INBOX_PROJECT",
  tagIds: [], isDone: false, timeSpent: 0, timeEstimate: 0, subTaskIds: []
}]' >"$fake/api/tasks.json"
  # the same API with a projects payload of the wrong shape, for the internal-failure code
  cp "$fake/api"/*.json "$fake/broken/"
  printf '{"id":"not-an-array"}\n' >"$fake/broken/projects.json"

  sp() { # sp [VAR=value...] ARGS — sp.sh against the fake API
    env PATH="$HERE/tests/fixtures/fake-curl:$PATH" FAKE_SP="$fake/api" SP_TOKEN=test "$@"
  }
  problems=0
  problem() {
    echo "check:   $1" >&2
    problems=$((problems + 1))
  }
  expect_rc() { # expect_rc WANT WHAT CMD... — CMD must exit WANT
    local want=$1 what=$2 rc=0
    shift 2
    "$@" >/dev/null 2>&1 || rc=$?
    [ "$rc" = "$want" ] || problem "$what: exited $rc, want $want"
  }
  expect_out() { # expect_out WHAT PATTERN CMD... — CMD must succeed and print a line matching PATTERN
    local what=$1 pattern=$2 out
    shift 2
    out=$("$@" 2>&1) || {
      problem "$what: failed: $out"
      return
    }
    grep -qE -- "$pattern" <<<"$out" || problem "$what: no line matches /$pattern/ in: $out"
  }
  expect_no() { # expect_no WHAT PATTERN CMD... — CMD must succeed and print no line matching PATTERN
    local what=$1 pattern=$2 out
    shift 2
    out=$("$@" 2>&1) || {
      problem "$what: failed: $out"
      return
    }
    if grep -qE -- "$pattern" <<<"$out"; then problem "$what: /$pattern/ matched in: $out"; fi
  }
  last_patch() { grep '^PATCH ' "$fake/api/requests" | tail -n1 | cut -d' ' -f3-; }
  expect_tags() { # expect_tags WHAT JSON-ARRAY — the last PATCH set exactly these tags
    jq -e --argjson want "$2" '.tagIds | sort == ($want | sort)' <<<"$(last_patch)" >/dev/null ||
      problem "$1: sent $(last_patch), want tagIds $2"
  }

  # The helpers first: an assertion that cannot fail makes every line below a decoration
  expect_rc 0 "probe" false 2>/dev/null
  expect_out "probe" '^never$' echo something 2>/dev/null
  [ "$problems" = 2 ] || fail "the assertion helpers accepted a wrong exit code or output — nothing below can go red"
  problems=0

  sp ./sp.sh set t1 --tag foo-bar >/dev/null
  expect_tags "set --tag with a hyphen in the name replaces the set" '["t-foobar"]'
  sp ./sp.sh set t1 --tag +foo-bar >/dev/null
  expect_tags "set --tag +name adds to the set" '["t-home","t-foobar"]'
  sp ./sp.sh set t1 --tag -home >/dev/null
  expect_tags "set --tag -name removes from the set" '[]'
  before=$(wc -l <"$fake/api/requests")
  expect_rc 1 "set --tag mixing a bare name with +/-" sp ./sp.sh set t1 --tag foo-bar,+home
  grep -q '^PATCH ' <(tail -n +"$((before + 1))" "$fake/api/requests") &&
    problem "set --tag mixing a bare name with +/- still sent a PATCH"

  expect_rc 1 "list --limit abc" sp ./sp.sh list --limit abc
  expect_rc 0 "list --limit 1" sp ./sp.sh list --limit 1
  expect_rc 1 "stats --days abc" sp ./sp.sh stats --days abc
  expect_rc 1 "stats --days 0" sp ./sp.sh stats --days 0

  expect_out "stats --by day --days 7 reaches six days back" "^$(day_offset -6) " sp ./sp.sh stats --by day --days 7
  expect_no "stats --by day --days 7 stops short of seven days back" "^$(day_offset -7) " sp ./sp.sh stats --by day --days 7
  expect_out "stats --by project without --days is all-time" '^Notes  3h spent' sp ./sp.sh stats --by project
  expect_out "stats --by project --days 1 is today only" '^Notes  1h spent' sp ./sp.sh stats --by project --days 1
  expect_out "stats --by tag --days 1 is today only" '^Home  1h spent' sp ./sp.sh stats --by tag --days 1

  expect_rc 2 "curl cannot connect" sp FAKE_CURL_EXIT=7 ./sp.sh health
  expect_rc 2 "curl gets an empty reply" sp FAKE_CURL_EXIT=52 ./sp.sh health
  expect_rc 1 "curl rejects SP_API as a URL" sp FAKE_CURL_EXIT=3 ./sp.sh health
  expect_rc 6 "a payload of the wrong shape" sp FAKE_SP="$fake/broken" ./sp.sh list --project Notes

  expect_out "projects --json prints the payload" '"title": "Notes"' sp ./sp.sh projects --json
  expect_out "tags --json prints the payload" '"title": "Home"' sp ./sp.sh tags --json
  expect_out "help lists itself" '^  help ' sp ./sp.sh help

  # Task ids are nanoids, whose alphabet has "-" in it, so one can open with a dash. Taken for
  # an unknown flag, it made every command on that task a usage error, while an id copied
  # from `list` is exactly what an agent passes
  dash_id=-3PluTV--NWbvqa0eL_VM
  sp ./sp.sh set "$dash_id" --est 2h >/dev/null 2>&1 || problem "set on a task whose id opens with a dash failed"
  [ "$(grep '^PATCH ' "$fake/api/requests" | tail -n1 | cut -d' ' -f2)" = "/tasks/$dash_id" ] ||
    problem "set on a dash-led id did not PATCH /tasks/$dash_id"
  expect_rc 0 "get on a dash-led id" sp ./sp.sh get "$dash_id"
  expect_rc 0 "get on a dash-led id after --" sp ./sp.sh get -- "$dash_id"
  expect_rc 1 "an unknown long flag is still refused" sp ./sp.sh list --bogus
  expect_rc 1 "an unknown short flag is still refused" sp ./sp.sh list -x

  # Where the token and the notes live: in the skill directory when it already holds them —
  # a clone synced between machines carries them along — and otherwise in the XDG config
  # directory, which a plugin or `npx skills` update cannot wipe the way it replaces the
  # skill directory. Copies of sp.sh stand in for both kinds of install, so the secrets/
  # beside the developer's own sp.sh cannot decide the result
  cfg="$fake/config"
  mkdir -p "$cfg/super-productivity-skill/secrets" "$fake/synced/secrets" "$fake/fresh"
  printf 'config-token\n' >"$cfg/super-productivity-skill/secrets/token"
  printf 'synced-token\n' >"$fake/synced/secrets/token"
  cp sp.sh "$fake/synced/"
  cp sp.sh "$fake/fresh/"
  ln -s "$fake/synced/sp.sh" "$fake/linked-sp.sh"
  synced_dir=$(cd "$fake/synced" && pwd -P)
  sent_token() { # sent_token SCRIPT [VAR=value...] — the bearer token SCRIPT sends, if any
    local script=$1
    shift
    rm -f "$fake/api/auth"
    env -u SP_TOKEN -u SP_TOKEN_FILE -u SP_HOME PATH="$HERE/tests/fixtures/fake-curl:$PATH" \
      FAKE_SP="$fake/api" "$@" "$script" health >/dev/null 2>&1 || true
    cat "$fake/api/auth" 2>/dev/null || true
  }
  [ "$(sent_token "$fake/synced/sp.sh" XDG_CONFIG_HOME="$cfg")" = synced-token ] ||
    problem "a skill directory that holds its token lost it to the XDG one"
  [ "$(sent_token "$fake/fresh/sp.sh" XDG_CONFIG_HOME="$cfg")" = config-token ] ||
    problem "an install with nothing beside it did not read the token from the XDG directory"
  [ "$(sent_token "$fake/linked-sp.sh" XDG_CONFIG_HOME="$cfg")" = synced-token ] ||
    problem "sp.sh called through a symlink did not find the directory it lives in"
  [ "$(sent_token "$fake/fresh/sp.sh" SP_HOME="$fake/synced")" = synced-token ] ||
    problem "SP_HOME did not move the private directory"
  expect_out "home is the XDG directory for an install with nothing beside it" \
    "^$cfg/super-productivity-skill\$" env -u SP_HOME XDG_CONFIG_HOME="$cfg" "$fake/fresh/sp.sh" home
  expect_out "home is the skill directory once it holds secrets/" \
    "^$synced_dir\$" env -u SP_HOME XDG_CONFIG_HOME="$cfg" "$fake/synced/sp.sh" home

  # Dates on both kinds of date: GNU's, and BSD's as macOS ships it, played by a fake that
  # refuses -d and --version and translates -v and -j -f. Each kind owes the same answers
  real_date=$(command -v date)
  bsd_path="$HERE/tests/fixtures/fake-bsd-date"
  if [ "$host_date" = gnu ]; then
    if env PATH="$bsd_path:$PATH" REAL_DATE="$real_date" date -d now >/dev/null 2>&1; then
      problem "the BSD date fake accepts -d, so the runs through it prove nothing about macOS"
    fi
    # BSD date rolls an impossible day over instead of failing; a fake that failed instead
    # would let the impossible-day check below pass without the round trip that catches it
    [ "$(env REAL_DATE="$real_date" "$bsd_path/date" -j -f %Y-%m-%d 2026-02-30 +%F 2>/dev/null)" = 2026-03-02 ] ||
      problem "the BSD date fake does not roll 2026-02-30 over into March as BSD date does"
    # The expectations' own BSD branch runs only on macOS, so it is held to the GNU one here,
    # through the same fake: a wrong sign or a missing second would otherwise ship unseen
    on_bsd() { env PATH="$bsd_path:$PATH" REAL_DATE="$real_date" "$@"; }
    for n in -7 -6 1 3; do
      [ "$(on_bsd bash -c "$(declare -f bsd_day_offset); bsd_day_offset $n")" = "$(gnu_day_offset "$n")" ] ||
        problem "the BSD branch of day_offset disagrees with GNU's for $n"
    done
    [ "$(on_bsd bash -c "$(declare -f bsd_epoch_at); bsd_epoch_at '2026-09-12 10:00'")" = "$(gnu_epoch_at '2026-09-12 10:00')" ] ||
      problem "the BSD branch of epoch_at disagrees with GNU's"
    kinds="gnu bsd"
  else
    # On macOS the system date is BSD's own, and the fake would translate into the -d it lacks
    kinds=native
  fi
  last_post() { grep '^POST ' "$fake/api/requests" | tail -n1 | cut -d' ' -f3-; }
  for kind in $kinds; do
    date_path="$HERE/tests/fixtures/fake-curl:$PATH"
    [ "$kind" = bsd ] && date_path="$bsd_path:$date_path"
    on_date() { env PATH="$date_path" REAL_DATE="$real_date" FAKE_SP="$fake/api" SP_TOKEN=test "$@"; }
    due_sent() { # due_sent DUE — the dueDay sp.sh sends for add --due DUE
      on_date ./sp.sh add dated --due "$1" >/dev/null 2>&1 || return 1
      jq -r '.dueDay' <<<"$(last_post)"
    }
    [ "$(due_sent tomorrow)" = "$(day_offset 1)" ] || problem "$kind date: --due tomorrow"
    [ "$(due_sent +3d)" = "$(day_offset 3)" ] || problem "$kind date: --due +3d"
    [ "$(due_sent 2028-02-29)" = 2028-02-29 ] || problem "$kind date: --due on a real leap day"
    expect_rc 1 "$kind date: --due on a day that does not exist" on_date ./sp.sh add dated --due 2026-02-30
    on_date ./sp.sh add dated --at "2026-09-12 10:00" >/dev/null 2>&1 || problem "$kind date: --at failed"
    [ "$(jq -r '.dueWithTime' <<<"$(last_post)")" = "$(($(epoch_at '2026-09-12 10:00') * 1000))" ] ||
      problem "$kind date: --at sent $(last_post)"
    expect_rc 1 "$kind date: --at on an hour that does not exist" on_date ./sp.sh add dated --at "2026-09-12 25:00"
    expect_out "$kind date: stats --by day reaches six days back" "^$(day_offset -6) " \
      on_date ./sp.sh stats --by day --days 7
    expect_no "$kind date: stats --by day stops short of seven days back" "^$(day_offset -7) " \
      on_date ./sp.sh stats --by day --days 7
  done

  [ "$problems" = 0 ] || fail "$problems behaviour check(s) failed — see above"
fi

echo
echo "check: everything holds"
