#!/usr/bin/env bash
# Every relative link in the given markdown files must resolve: a path that
# exists, or an anchor some heading in the target file actually produces.
#
# Links to the network are deliberately not checked. A dead external URL is
# someone else's outage, and a check that depends on someone else's uptime is a
# drift detector, never a pull-request gate.
set -euo pipefail

fail=0
report() {
  printf 'links: %s\n' "$1" >&2
  fail=1
}

# Fenced blocks are content, not prose: a shell comment inside one is not a
# heading, and a bracketed example is not a link
body() {
  awk '/^[[:space:]]*```/ { inside = !inside; next } !inside' "$1"
}

# GitHub's heading slug: lowercase, drop punctuation, spaces to hyphens
slugs() {
  body "$1" |
    sed -n 's/^#\{1,6\}[[:space:]]\{1,\}//p' |
    tr '[:upper:]' '[:lower:]' |
    sed -e 's/[^a-z0-9 _-]//g' -e 's/[[:space:]]\{1,\}/-/g'
}

has_slug() { # has_slug FILE ANCHOR
  slugs "$1" | grep -qxF "$2"
}

for file in "$@"; do
  [ -f "$file" ] || {
    report "$file: no such file"
    continue
  }
  dir=$(dirname "$file")
  while IFS= read -r target; do
    case $target in
      '' | http://* | https://* | mailto:*) continue ;;
      '#'*)
        has_slug "$file" "${target#\#}" ||
          report "$file: no heading makes the anchor $target"
        continue
        ;;
    esac
    path=${target%%#*}
    frag=${target#"$path"}
    if [ ! -e "$dir/$path" ]; then
      report "$file: $path does not exist"
      continue
    fi
    case $frag in
      '#'*)
        case $path in
          *.md)
            has_slug "$dir/$path" "${frag#\#}" ||
              report "$file: $path has no heading making $frag"
            ;;
        esac
        ;;
    esac
  done < <(body "$file" | grep -oE '\]\([^)[:space:]]+\)' | sed -e 's/^](//' -e 's/)$//')
done

exit "$fail"
