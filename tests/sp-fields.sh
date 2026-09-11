#!/usr/bin/env bash
# Print the field names Super Productivity declares for a task and a project, one per line,
# read from the TypeScript the app ships in its app.asar: the plugin API's Task and Project
# interfaces and the app's own TaskCopy, which the Local REST API returns. The first line
# names the version, taken from the store path or the file's directory.
#
#   tests/sp-fields.sh ASAR
#
# tests/sp-fields.txt is this script's output for the version it names, so the gate can
# hold the documents to the fields without the app on the runner; tests/check.sh compares
# the two again when SP_ASAR points at an installed app.asar.
#
# Exit 0 with the list, 1 when the file declares none of the three interfaces, 2 on a
# usage error. Needs bash 3.2 and POSIX tools only.
set -euo pipefail

usage() { sed -n '2,/^[^#]/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; }

case "${1:-}" in
  -h | --help | help)
    usage
    exit 0
    ;;
  "")
    usage >&2
    exit 2
    ;;
esac
asar=$1
[[ -f "$asar" && -r "$asar" ]] || {
  printf 'sp-fields: %s is not a readable file\n' "$asar" >&2
  exit 2
}

# A version-bearing directory such as super-productivity-18.21.2 somewhere in the path
version=$(printf '%s\n' "$asar" | grep -oE 'super-?productivity-[0-9][0-9.]*' | head -n 1 || true)
# Each interface sits in the bundle as a string with its newlines escaped, and one match can
# run on from Task into Project, which share a source file; so every line is read, a field
# being a line indented by exactly two spaces inside one of the three and before the line
# that closes it
fields=$(LC_ALL=C grep -aoE '(export interface (Task|Project) \{|interface TaskCopy[^{]*\{)(\\n[^\\]*){1,200}' "$asar" |
  awk '{
    n = split($0, line, /\\n/)
    inside = 0
    for (i = 1; i <= n; i++) {
      if (line[i] ~ /^(export )?interface (Task|Project) \{/ || line[i] ~ /^(export )?interface TaskCopy/) {
        inside = 1
        continue
      }
      if (line[i] ~ /^}/) inside = 0
      if (inside && match(line[i], /^  [a-zA-Z][a-zA-Z0-9]*\??:/)) {
        f = substr(line[i], 3, RLENGTH - 3)
        sub(/\?$/, "", f)
        print f
      }
    }
  }' | sort -u)
[[ -n "$fields" ]] || {
  printf 'sp-fields: %s declares no Task, TaskCopy or Project interface\n' "$asar" >&2
  exit 1
}
printf '# %s: the fields of Task, TaskCopy and Project in its app.asar, printed by tests/sp-fields.sh\n' "${version:-super-productivity}"
printf '%s\n' "$fields"
