#!/usr/bin/env bash
# The whole gate. Nothing here reaches the network or a package registry, so it
# is safe to run on pull requests — and every check below is followed by proof
# that it can go red, because a check that has never failed is a decoration: each
# linter and gate against a known-bad input, the behaviour assertions through a
# probe their own helper has to reject
#
# Needs: shellcheck, shfmt, actionlint, jq — from PATH; CI provides them through
# nix develop
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$HERE"

fail() {
  echo "check: $1" >&2
  exit 1
}

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

echo "== SKILL.md carries the frontmatter an agent loads it by"
frontmatter_problem() { # frontmatter_problem FILE — prints what is wrong, nothing if sound
  local front key
  [ "$(head -n1 -- "$1")" = --- ] || {
    echo "does not open with a frontmatter block"
    return
  }
  front=$(sed -n '2,/^---$/p' "$1")
  for key in name description license; do
    grep -q "^$key:" <<<"$front" || {
      echo "frontmatter has no $key"
      return
    }
  done
  grep -qx 'name: super-productivity' <<<"$front" ||
    echo "the skill's name is not what the plugin manifest and the readme call it"
}
why=$(frontmatter_problem SKILL.md)
[ -z "$why" ] || fail "SKILL.md $why"

echo "== the frontmatter check is able to fail"
planted=$(mktemp -d)
sed '1d' SKILL.md >"$planted/no-opener.md"
grep -v '^description:' SKILL.md >"$planted/no-description.md"
sed 's/^name: .*/name: something-else/' SKILL.md >"$planted/wrong-name.md"
for f in "$planted"/*.md; do
  [ -n "$(frontmatter_problem "$f")" ] || {
    rm -rf "$planted"
    fail "the frontmatter check passed a copy of SKILL.md planted with ${f##*/}"
  }
done

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

echo "== every relative link in the docs resolves"
./tests/check-links.sh "${docs[@]}"

echo "== the link checker is able to fail"
if ./tests/check-links.sh tests/fixtures/broken-links.md >/dev/null 2>&1; then
  fail "tests/fixtures/broken-links.md passed the link checker — it cannot catch anything"
fi

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

echo "== sp.sh against a fake API: what it sends and how it exits"
# tests/fixtures/fake-curl stands in for curl and answers from files, so these run
# with no Super Productivity and no network. Dates are relative to today because
# the stats window is
fake=$(mktemp -d)
trap 'rm -rf "$work" "$fake"' EXIT
mkdir -p "$fake/api" "$fake/broken"
cp tests/fixtures/fake-sp/*.json "$fake/api/"
jq -n --arg d0 "$(date +%F)" --arg d6 "$(date -d '6 days ago' +%F)" --arg d7 "$(date -d '7 days ago' +%F)" '[{
  id: "t1", title: "Water plants", projectId: "p-notes", tagIds: ["t-home"], isDone: false,
  timeSpent: 10800000, timeEstimate: 0, subTaskIds: [],
  timeSpentOnDay: {($d0): 3600000, ($d6): 3600000, ($d7): 3600000}
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

expect_out "stats --by day --days 7 reaches six days back" "^$(date -d '6 days ago' +%F) " sp ./sp.sh stats --by day --days 7
expect_no "stats --by day --days 7 stops short of seven days back" "^$(date -d '7 days ago' +%F) " sp ./sp.sh stats --by day --days 7
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

# The token lives in the XDG config directory, because a plugin or `npx skills` update
# replaces the skill directory whole; the old place beside the script is read only when
# the new one has nothing, so an install set up before the move keeps working
cfg="$fake/config"
mkdir -p "$cfg/super-productivity-skill" "$fake/old/secrets"
printf 'new-token\n' >"$cfg/super-productivity-skill/token"
cp sp.sh "$fake/old/"
printf 'old-token\n' >"$fake/old/secrets/token"
sent_token() { # sent_token SCRIPT [VAR=value...] — the bearer token SCRIPT sends, if any
  local script=$1
  shift
  rm -f "$fake/api/auth"
  env -u SP_TOKEN -u SP_TOKEN_FILE -u SP_HOME PATH="$HERE/tests/fixtures/fake-curl:$PATH" \
    FAKE_SP="$fake/api" "$@" "$script" health >/dev/null 2>&1 || true
  cat "$fake/api/auth" 2>/dev/null || true
}
[ "$(sent_token "$fake/old/sp.sh" XDG_CONFIG_HOME="$cfg")" = new-token ] ||
  problem "the token in the XDG config directory did not win over the one beside the script"
[ "$(sent_token "$fake/old/sp.sh" XDG_CONFIG_HOME="$fake/nowhere")" = old-token ] ||
  problem "an install set up before the move lost the token beside its script"
[ "$(sent_token "$fake/old/sp.sh" XDG_CONFIG_HOME="$fake/nowhere" SP_HOME="$cfg/super-productivity-skill")" = new-token ] ||
  problem "SP_HOME did not move the private directory"
expect_out "home prints the private directory" "^$cfg/super-productivity-skill\$" sp XDG_CONFIG_HOME="$cfg" ./sp.sh home

[ "$problems" = 0 ] || fail "$problems behaviour check(s) failed — see above"

echo
echo "check: everything holds"
