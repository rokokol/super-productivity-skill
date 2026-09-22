#!/usr/bin/env bash
# Every check below is followed by proof that it can go red, because a check that has
# never failed is a decoration: each linter and gate against a known-bad input, the
# behaviour assertions through a probe their own helper has to reject
set -euo pipefail

usage() {
  cat <<'EOF'
check.sh — the whole gate

  check.sh [lint|behaviour|all]

  -h, --help   print this and exit

lint needs shellcheck, shfmt, actionlint and jq, behaviour needs jq alone — from PATH;
CI provides them through nix develop. behaviour is also what the macOS job runs, under
the bash and date that system ships, since the linters say the same on every platform:

  /bin/bash ./tests/check.sh behaviour        # on a macOS runner

Nothing here reaches the network or a package registry
Exit 0 when everything holds, 1 on a finding, 2 on a usage error
EOF
}

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$HERE"

fail() {
  echo "check: $1" >&2
  exit 1
}

mode="${1:-all}"
case "$mode" in
  lint | behaviour | all) ;;
  -h | --help | help)
    usage
    exit 0
    ;;
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

  echo "== this repository declares no marketplace of its own"
  # A marketplace answers to the name it declares, and a user registers one per name. Two
  # repositories declaring the same name replace each other, together with whatever was
  # installed from the one that lost. One repository holds the list, and it holds the check
  # that every entry names a skill by the name that skill answers to
  [ ! -e .claude-plugin ] ||
    fail ".claude-plugin is back — the entry for this skill belongs to the marketplace repository"

  echo "== the vendored checkers are byte-equal to their source"
  # check-skill.sh comes from the skill-authoring skill
  # (https://github.com/rokokol/skill-authoring-skill) and check-pins.sh from the ci skill
  # (https://github.com/rokokol/ci-skill): every copy must still be the blob
  # .github/vendor.lock records, so one edited here instead of at its source fails by name
  ./vendor-sync.sh check

  echo "== the workflows take no tool from a registry"
  # The ci skill's pin guard, which proves on every run that it catches each unpinned shape
  ./check-pins.sh

  echo "== SKILL.md loads, every reference is reachable, and every link and anchor resolves"
  # The one gate every skill repository shares, each check proven able to fail on a planted
  # copy on every run
  ./check-skill.sh -n super-productivity .

  echo "== sp.sh's help, and every sp.sh the docs spell, agree with its dispatcher"
  # The bash-best-practices skill's check-sh.sh, vendored: the subcommands, the flags and
  # the SP_ variables sp.sh reads must all be in its help, and every `sp.sh …` that
  # SKILL.md and the readme spell must be a real one. Both send the reader to the help for
  # the full list, so they are held with -m, which demands no list. It plants its own
  # defects on every run
  ./check-sh.sh -e SP_ -m SKILL.md -m README.md sp.sh

  echo "== every API field the docs name is one Super Productivity declares"
  # The docs teach the API's own field names — a parent's derived timeEstimate, the backlog
  # as a project's backlogTaskIds — and a rename in the app would leave them teaching a field
  # that is gone. The app is not on a runner, so the gate reads tests/sp-fields.txt, what
  # tests/sp-fields.sh printed from one version's app.asar; with SP_ASAR pointing at an
  # installed app.asar the recording is first held to it, so the day the app moves the gate
  # says the recording is stale
  if [ -n "${SP_ASAR:-}" ]; then
    tests/sp-fields.sh "$SP_ASAR" | diff tests/sp-fields.txt - >"$work/fields.diff" ||
      fail "tests/sp-fields.txt is not what $SP_ASAR declares; regenerate it with: tests/sp-fields.sh \"\$SP_ASAR\" >tests/sp-fields.txt"$'\n'"$(head -n 20 "$work/fields.diff")"
  else
    echo "   against the recording of $(head -n 1 tests/sp-fields.txt | cut -d' ' -f2 | tr -d :); set SP_ASAR to hold it to an installed app"
  fi
  # The ci skill's check-interface.sh, vendored: a code span that is wholly a camelCase word
  # is a field the docs claim, and it plants its own defects on every run
  ./check-interface.sh -d tests/sp-fields.txt -s '[a-z]+[A-Z][A-Za-z]*' SKILL.md README.md

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
}, {
  id: "parent", title: "Parent", projectId: "p-notes", tagIds: [], isDone: false,
  timeSpent: 3600000, timeEstimate: 0, subTaskIds: ["child"]
}, {
  id: "child", title: "Child", parentId: "parent", projectId: "p-notes", tagIds: [],
  isDone: false, timeSpent: 3600000, timeEstimate: 0, subTaskIds: []
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
  sp ./sp.sh set t1 --tag +home >/dev/null
  expect_tags "set --tag +name adds to the set" '["t-home","t-foobar"]'
  sp ./sp.sh set t1 --tag -foo-bar >/dev/null
  expect_tags "set --tag -name removes from the set" '["t-home"]'
  before=$(wc -l <"$fake/api/requests")
  expect_rc 2 "set --tag mixing a bare name with +/-" sp ./sp.sh set t1 --tag foo-bar,+home
  grep -q '^PATCH ' <(tail -n +"$((before + 1))" "$fake/api/requests") &&
    problem "set --tag mixing a bare name with +/- still sent a PATCH"
  # A name resolves to one id or to nothing: never to the first of several, never to itself,
  # and never by dropping the one in a list that missed. Cyrillic folds its case and ё to е
  before=$(wc -l <"$fake/api/requests")
  expect_rc 3 "a tag name two tags share" sp ./sp.sh set t1 --tag o
  expect_rc 3 "a project name no project has" sp ./sp.sh set t1 --project Nowhere
  expect_rc 3 "one unknown tag in a list" sp ./sp.sh set t1 --tag Home,Nowhere
  grep -q '^PATCH ' <(tail -n +"$((before + 1))" "$fake/api/requests") &&
    problem "a name that did not resolve to exactly one id still sent a PATCH"
  sp ./sp.sh set t1 --tag +важное >/dev/null 2>&1 || problem "a Cyrillic tag in another case did not resolve"
  expect_tags "a Cyrillic tag in another case" '["t-home","t-important"]'
  sp ./sp.sh set t1 --tag +еще >/dev/null 2>&1 || problem "a tag spelt with е for ё did not resolve"
  expect_tags "a tag spelt with е for ё" '["t-home","t-important","t-again"]'
  expect_rc 0 "a tag set the app stores in another order" sp FAKE_SP_REVERSE_TAGS=1 ./sp.sh set t1 --tag Home,foo-bar
  sp ./sp.sh set t1 --tag Home >/dev/null

  expect_rc 2 "list --limit abc" sp ./sp.sh list --limit abc
  [ "$(sp ./sp.sh list --limit 1 | wc -l | tr -d ' ')" = 1 ] || problem "list --limit 1 did not print exactly one task"
  last_list() { grep '^GET /tasks?' "$fake/api/requests" | tail -n1 | cut -d' ' -f2; }
  sp ./sp.sh list --source archived >/dev/null
  [[ $(last_list) == *includeDone=true* ]] || problem "list --source archived asked for open tasks only: $(last_list)"
  sp ./sp.sh list --all >/dev/null
  [[ $(last_list) == *source=all* ]] || problem "list --all left the archive out: $(last_list)"
  sp ./sp.sh list --today >/dev/null
  [[ $(last_list) == *tagId=TODAY* ]] || problem "list --today did not ask for today's tasks: $(last_list)"
  sp ./sp.sh list --query 'a b&c' >/dev/null
  [[ $(last_list) == *query=a%20b%26c* ]] || problem "list --query sent the text unencoded: $(last_list)"
  # Refused before anything is sent: each would otherwise reach the API as something else
  expect_rc 2 "TODAY given as a tag" sp ./sp.sh add dated --tag TODAY
  expect_rc 2 "a subtask with a project of its own" sp ./sp.sh add sub --parent parent --project Notes
  expect_rc 2 "set --parent" sp ./sp.sh set t1 --parent parent
  expect_rc 2 "set with nothing to change" sp ./sp.sh set t1
  expect_rc 2 "--due +3xd" sp ./sp.sh add dated --due +3xd
  expect_rc 2 "--est 1hxm" sp ./sp.sh set t1 --est 1hxm
  sp ./sp.sh set t1 --est 1h30m >/dev/null 2>&1 || problem "set --est 1h30m failed"
  [ "$(jq -r '.timeEstimate' <<<"$(last_patch)")" = 5400000 ] || problem "--est 1h30m sent $(last_patch)"
  expect_rc 2 "list --limit with no value" sp ./sp.sh list --limit
  expect_rc 2 "stats --days abc" sp ./sp.sh stats --days abc
  expect_rc 2 "stats --days 0" sp ./sp.sh stats --days 0
  expect_rc 0 "set --notes with an empty value clears the notes" sp ./sp.sh set t1 --notes ''

  before=$(wc -l <"$fake/api/requests")
  sp ./sp.sh set t1 --notes saved >/dev/null 2>&1 || problem "set failed while verifying a persisted field"
  tail -n +"$((before + 1))" "$fake/api/requests" | grep -qE '^GET /tasks/t1 ' ||
    problem "set did not read the task back after PATCH"
  expect_rc 7 "set detects a field silently discarded after an optimistic response" \
    sp FAKE_SP_DISCARD_FIELD=notes ./sp.sh set t1 --notes discarded

  before=$(wc -l <"$fake/api/requests")
  sp ./sp.sh add verified >/dev/null 2>&1 || problem "add failed while verifying a persisted task"
  created_id=$(tail -n +"$((before + 1))" "$fake/api/requests" | grep '^GET /tasks/' | tail -n1 | cut -d' ' -f2)
  [ -n "$created_id" ] || problem "add did not read the new task back after POST"

  expect_rc 0 "archive verifies the task reached the archived list" sp ./sp.sh archive t1
  expect_rc 7 "restore detects a task left archived after an optimistic response" \
    sp FAKE_SP_SKIP_RESTORE=1 ./sp.sh restore t1
  expect_rc 0 "restore verifies the task came back to the active list" sp ./sp.sh restore t1
  expect_rc 7 "archive detects a task left active after an optimistic response" \
    sp FAKE_SP_SKIP_ARCHIVE=1 ./sp.sh archive t1
  expect_rc 7 "archive detects an app that serves the archived task as active too" \
    sp FAKE_SP_ARCHIVE_LINGERS=1 ./sp.sh archive t1
  expect_rc 7 "archive detects a task that reached neither list" \
    sp FAKE_SP_ARCHIVE_SWALLOWS=1 ./sp.sh archive "$(sp ./sp.sh add swallowed --json | jq -r '.id')"
  before=$(wc -l <"$fake/api/requests")
  sp ./sp.sh restore t1 >/dev/null 2>&1 || problem "restore left t1 archived after the lingering archive"
  sent=$(tail -n +"$((before + 1))" "$fake/api/requests")
  grep -qE '^GET /tasks\?.*source=active' <<<"$sent" || problem "restore did not read the active list back"
  grep -qE '^GET /tasks\?.*source=archived' <<<"$sent" || problem "restore did not check the archived list"

  expect_rc 0 "moving a parent verifies its descendants" sp ./sp.sh set parent --project INBOX_PROJECT
  sp ./sp.sh set parent --project Notes >/dev/null
  expect_rc 7 "moving a parent detects a child left in the old project" \
    sp FAKE_SP_SKIP_CASCADE=1 ./sp.sh set parent --project INBOX_PROJECT

  disposable=$(sp ./sp.sh add disposable --json | jq -r '.id')
  expect_rc 0 "rm verifies that the task disappeared" sp ./sp.sh rm "$disposable"
  stubborn=$(sp ./sp.sh add stubborn --json | jq -r '.id')
  expect_rc 7 "rm detects a task left behind after an optimistic response" \
    sp FAKE_SP_SKIP_DELETE=1 ./sp.sh rm "$stubborn"
  expect_rc 0 "done verifies isDone" sp ./sp.sh "done" "$(sp ./sp.sh add finished --json | jq -r '.id')"
  expect_rc 7 "done detects a task left open after an optimistic response" \
    sp FAKE_SP_DISCARD_FIELD=isDone ./sp.sh "done" "$(sp ./sp.sh add unfinished --json | jq -r '.id')"

  expect_out "stats --by day --days 7 reaches six days back" "^$(day_offset -6) " sp ./sp.sh stats --by day --days 7
  expect_no "stats --by day --days 7 stops short of seven days back" "^$(day_offset -7) " sp ./sp.sh stats --by day --days 7
  # A parent stores the sum of its subtasks' time, so counting it beside them counts it twice
  expect_out "stats --by project without --days is all-time" '^Notes  4h spent' sp ./sp.sh stats --by project
  expect_out "stats counts leaf tasks only" ' tracked 4h$' sp ./sp.sh stats --by project
  expect_out "stats --by project --days 1 is today only" '^Notes  1h spent' sp ./sp.sh stats --by project --days 1
  expect_out "stats --by tag --days 1 is today only" '^Home  1h spent' sp ./sp.sh stats --by tag --days 1

  expect_rc 1 "curl cannot connect" sp FAKE_CURL_EXIT=7 ./sp.sh health
  expect_rc 1 "curl gets an empty reply" sp FAKE_CURL_EXIT=52 ./sp.sh health
  expect_rc 2 "curl rejects SP_API as a URL" sp FAKE_CURL_EXIT=3 ./sp.sh health
  expect_rc 6 "a payload of the wrong shape" sp FAKE_SP="$fake/broken" ./sp.sh list --project Notes
  expect_rc 5 "a rejected token" \
    sp FAKE_SP_REPLY='401 {"ok":false,"error":{"code":"UNAUTHORIZED","message":"invalid token"}}' ./sp.sh health
  # A reply that is not JSON exits as an API error either way; what the guard adds is saying
  # what came back instead of relaying jq's parse error
  nonjson_rc=0
  nonjson_out=$(sp FAKE_SP_REPLY='502 <html>bad gateway</html>' ./sp.sh health 2>&1) || nonjson_rc=$?
  [ "$nonjson_rc" = 4 ] || problem "a reply that is not JSON: exited $nonjson_rc, want 4"
  grep -qxF 'HTTP 502: unexpected non-JSON response' <<<"$nonjson_out" ||
    problem "a reply that is not JSON was not named as such: $nonjson_out"
  expect_rc 4 "a task the API does not have" sp ./sp.sh get no-such-task

  expect_out "projects --json prints the payload" '"title": "Notes"' sp ./sp.sh projects --json
  expect_out "tags --json prints the payload" '"title": "Home"' sp ./sp.sh tags --json
  expect_out "help lists itself" '^  sp\.sh help ' sp ./sp.sh help
  expect_rc 2 "an unknown subcommand" sp ./sp.sh bogus

  # Task ids are nanoids, whose alphabet has "-" in it, so one can open with a dash. Taken for
  # an unknown flag, it made every command on that task a usage error, while an id copied
  # from `list` is exactly what an agent passes
  dash_id=-3PluTV--NWbvqa0eL_VM
  sp ./sp.sh set "$dash_id" --est 2h >/dev/null 2>&1 || problem "set on a task whose id opens with a dash failed"
  [ "$(grep '^PATCH ' "$fake/api/requests" | tail -n1 | cut -d' ' -f2)" = "/tasks/$dash_id" ] ||
    problem "set on a dash-led id did not PATCH /tasks/$dash_id"
  expect_rc 0 "get on a dash-led id" sp ./sp.sh get "$dash_id"
  expect_rc 0 "get on a dash-led id after --" sp ./sp.sh get -- "$dash_id"
  expect_rc 2 "an unknown long flag is still refused" sp ./sp.sh list --bogus
  expect_rc 2 "an unknown short flag is still refused" sp ./sp.sh list -x

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
    expect_rc 2 "$kind date: --due on a day that does not exist" on_date ./sp.sh add dated --due 2026-02-30
    on_date ./sp.sh add dated --at "2026-09-12 10:00" >/dev/null 2>&1 || problem "$kind date: --at failed"
    [ "$(jq -r '.dueWithTime' <<<"$(last_post)")" = "$(($(epoch_at '2026-09-12 10:00') * 1000))" ] ||
      problem "$kind date: --at sent $(last_post)"
    expect_rc 2 "$kind date: --at on an hour that does not exist" on_date ./sp.sh add dated --at "2026-09-12 25:00"
    expect_rc 2 "$kind date: --at on a day that does not exist" on_date ./sp.sh add dated --at "2026-02-30 10:00"
    expect_out "$kind date: stats --by day reaches six days back" "^$(day_offset -6) " \
      on_date ./sp.sh stats --by day --days 7
    expect_no "$kind date: stats --by day stops short of seven days back" "^$(day_offset -7) " \
      on_date ./sp.sh stats --by day --days 7
  done

  [ "$problems" = 0 ] || fail "$problems behaviour check(s) failed — see above"
fi

echo
echo "check: everything holds"
