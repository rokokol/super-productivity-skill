#!/usr/bin/env bash
# Prints one line per shape tests/no-secrets.sh claims to catch, so check.sh can
# plant each in a throwaway repository and require the gate to go red on it.
#
# Every body is GENERATED and every literal prefix is split by a format string:
# a key-shaped value committed here would be a real finding for the gate itself
# and for GitHub's push protection, and a fixture that cannot be pushed is not a
# fixture. What is committed matches nothing on its own.
set -euo pipefail

rep() { # rep CHAR COUNT
  printf "%${2}s" '' | tr ' ' "$1"
}

printf -- '-----BEGIN %s PRIVATE %s-----\n' OPENSSH KEY
printf 'ghp%s%s\n' _ "$(rep A 32)"
printf 'github%spat_%s\n' _ "$(rep A 62)"
printf 'glpat%s%s\n' - "$(rep A 22)"
printf 'npm%s%s\n' _ "$(rep A 36)"
printf 'sk%sant-api03-%s\n' - "$(rep A 90)"
printf 'sk%sproj-%s\n' - "$(rep A 24)"
printf 'sk%s%s\n' - "$(rep A 48)"
printf 'AIza%s\n' "$(rep A 35)"
printf 'SP%sTOKEN=%s\n' _ "$(rep A 32)"
