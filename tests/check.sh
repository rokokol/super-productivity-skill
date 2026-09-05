#!/usr/bin/env bash
# The whole gate. Nothing here reaches the network or a package registry, so it
# is safe to run on pull requests — and every check below is followed by proof
# that it can go red, because a check that has never failed is a decoration.
#
# Needs: shellcheck, shfmt — from PATH; CI provides them through nix develop
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$HERE"

fail() {
  echo "check: $1" >&2
  exit 1
}

# One source of truth for what gets linted: this list, read by nothing else
scripts=(sp.sh tests/check.sh tests/check-links.sh tests/no-secrets.sh tests/fixtures/planted-secrets.sh)
docs=(README.md SKILL.md CHANGELOG.md)

echo "== the scripts parse and lint"
for s in "${scripts[@]}"; do bash -n "$s"; done
shellcheck "${scripts[@]}"
# sp.sh keeps its own one-line case arms on purpose; the test scripts are shfmt's
shfmt -d -i 2 -ci tests/check.sh tests/check-links.sh tests/no-secrets.sh tests/fixtures/planted-secrets.sh

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
head -1 SKILL.md | grep -qx -- '---' || fail "SKILL.md does not open with a frontmatter block"
front=$(sed -n '2,/^---$/p' SKILL.md)
for key in name description license; do
  printf '%s\n' "$front" | grep -q "^$key:" || fail "SKILL.md frontmatter has no $key"
done
printf '%s\n' "$front" | grep -q '^name: super-productivity$' ||
  fail "the skill's name is not what the plugin manifest and the readme call it"

echo "== every relative link in the docs resolves"
./tests/check-links.sh "${docs[@]}"

echo "== the link checker is able to fail"
if ./tests/check-links.sh tests/fixtures/broken-links.md >/dev/null 2>&1; then
  fail "tests/fixtures/broken-links.md passed the link checker — it cannot catch anything"
fi

echo "== the secret gate is quiet on this repository"
./tests/no-secrets.sh

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
# Clean first: the gate is now scanning its own source, so a pattern matching its
# own text would surface right here
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

echo
echo "check: everything holds"
