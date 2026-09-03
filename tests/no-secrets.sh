#!/usr/bin/env bash
# Refuse to ship a secret that slipped past .gitignore.
#
# .gitignore keeps secrets/ out of the repository; this keeps a value out of a
# file that belongs here — a token pasted into a doc, an example or a default is
# the leak that actually happens.
#
# Every pattern is written so it cannot match its own source line: a literal
# prefix is always followed by a bracket expression the pattern text itself does
# not satisfy. Keep that property when adding one, or the gate goes red on the
# commit that introduces it.
set -euo pipefail

cd "$(dirname "$0")/.."

fail=0
report() {
  printf 'secret-gate: %s\n' "$1" >&2
  fail=1
}

mapfile -t tracked < <(git ls-files)
[ ${#tracked[@]} -gt 0 ] || {
  echo "secret-gate: nothing tracked yet" >&2
  exit 0
}

scan() { # scan DESCRIPTION ERE
  if git grep -nIE "$2" -- "${tracked[@]}" >&2; then
    report "$1"
  fi
}

# The token lives in secrets/, which is git-ignored — a tracked file under that
# path means the ignore was bypassed with git add -f
if git ls-files --error-unmatch secrets >/dev/null 2>&1; then
  report "something under secrets/ is tracked"
fi

scan "private key material" \
  'BEGIN ([A-Z]+ )*PRIVATE KEY'

scan "forge or registry token" \
  '(gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{60,}|glpat-[A-Za-z0-9_-]{20,}|npm_[A-Za-z0-9]{36})'

scan "model-provider API key" \
  '(sk-ant-[a-z0-9]+-[A-Za-z0-9_-]{80,}|sk-proj-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{48}|AIza[A-Za-z0-9_-]{35})'

# Super Productivity's own token: a long opaque string assigned to the variable
# the script reads, or written into a documented example as if it were real
scan "an access token spelled out in a file" \
  'SP_TOKEN[=:][[:space:]]*["'\'']?[A-Za-z0-9_.-]{24,}'

exit "$fail"
