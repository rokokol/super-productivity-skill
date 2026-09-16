#!/usr/bin/env bash
# The defect list for this repository, read by the tests skill's harness, vendored beside
# it, and run by .github/workflows/falsify.yml:
#
#   tests/t.sh falsify -- ./tests/check.sh behaviour
#
# Each entry breaks one guard of sp.sh and requires the behaviour suite to notice. The
# CONSEQUENCE is what goes wrong for the user when that guard stops working; when an entry
# survives, that sentence is the report.
#
#   defect NAME FILE FIND REPLACE CONSEQUENCE [expect survived REASON | expect caught FRAGMENT]
#
# A FIND or REPLACE that holds a $ or a quote is a quoted heredoc: it keeps the line exactly
# as sp.sh spells it, with no escaping to get wrong

# Where the token comes from, and whether it is sent
defect 'token/file' 'sp.sh' \
  "$(
    cat <<'EOF'
  SP_TOKEN=$(tr -d '[:space:]' <"$SP_TOKEN_FILE")
EOF
  )" \
  "  SP_TOKEN=''" \
  'the token written to the private directory is never read, and every call is rejected as unauthenticated'

defect 'token/header' 'sp.sh' \
  "$(
    cat <<'EOF'
  [ -n "$SP_TOKEN" ] && args+=(-H "Authorization: Bearer $SP_TOKEN")
EOF
  )" \
  '  true' \
  'the token is read but never sent, and every call is rejected as unauthenticated'

defect 'home/synced' 'sp.sh' \
  "$(
    cat <<'EOF'
  if [ -e "$HERE/secrets" ] || [ -e "$HERE/user" ]; then
EOF
  )" \
  '  if false; then' \
  'a clone synced between machines loses its token and notes to an empty XDG directory'

defect 'home/symlink' 'sp.sh' \
  "$(
    cat <<'EOF'
while [ -L "$src" ]; do
EOF
  )" \
  'while false; do' \
  'sp.sh called through a symlink looks for its token beside the link and finds none'

# Exit codes: each tells the agent what to do next, so a wrong one sends it the wrong way
defect 'exit/jq-internal' 'sp.sh' \
  "$(
    cat <<'EOF'
    2 | 3 | 5) die $E_DATA "jq failed with code $rc: the API sent data of an unexpected shape, or sp.sh has a bug" ;;
EOF
  )" \
  '    2 | 3 | 5) ;;' \
  "a payload of the wrong shape exits 5, and the agent asks the user for a fresh token that was never the problem"

defect 'exit/bad-url' 'sp.sh' \
  "$(
    cat <<'EOF'
    1 | 3) die $E_USAGE
EOF
  )" \
  "$(
    cat <<'EOF'
    1 | 3) die $E_CONN
EOF
  )" \
  'an SP_API curl cannot parse is reported as the app being down, and the user is sent to start an app that is running'

defect 'exit/unreachable' 'sp.sh' \
  "$(
    cat <<'EOF'
    6 | 7 | 28) die $E_CONN
EOF
  )" \
  "$(
    cat <<'EOF'
    6 | 7 | 28) die $E_USAGE
EOF
  )" \
  'the app not running is reported as a usage error, and the agent rewrites a correct command instead of asking to start the app'

defect 'exit/token-rejected' 'sp.sh' \
  "$(
    cat <<'EOF'
    if [ "$code" = 401 ]; then
EOF
  )" \
  '    if false; then' \
  'a rejected token exits as a plain API error, and the agent relays it instead of asking for a fresh token'

defect 'api/non-json' 'sp.sh' \
  "$(
    cat <<'EOF'
  if [ -z "$json" ] || ! command jq -e . >/dev/null 2>&1 <<<"$json"; then
EOF
  )" \
  '  if false; then' \
  'a reply that is not JSON, from a proxy or another service on the port, is reported as a bug in sp.sh instead of as what came back'

defect 'api/refusal' 'sp.sh' \
  "$(
    cat <<'EOF'
  if [ "$(jq -r '.ok' <<<"$json")" != "true" ]; then
EOF
  )" \
  '  if false; then' \
  'an API refusal passes for data and exits 0, so a request the app turned down is reported as done'

# Every write is read back; a write that did not land must not be reported as done
defect 'verify/fields' 'sp.sh' \
  "$(
    cat <<'EOF'
  [ "$differences" = '[]' ] ||
EOF
  )" \
  '  true ||' \
  'a field the API silently dropped is reported as saved'

defect 'verify/tags-unordered' 'sp.sh' \
  "$(
    cat <<'EOF'
        then ((.value // []) | sort) != (($got[.key] // []) | sort)
EOF
  )" \
  "$(
    cat <<'EOF'
        then .value != $got[.key]
EOF
  )" \
  'a tag set the app stores in another order is reported as a failed write, and the agent retries a write that landed'

defect 'verify/done' 'sp.sh' \
  "$(
    cat <<'EOF'
      verify_task "$id" '{"isDone":true}' | fmt
EOF
  )" \
  "$(
    cat <<'EOF'
      api GET "/tasks/$id" | fmt
EOF
  )" \
  'a task the app left open is reported as done'

defect 'verify/project-tree' 'sp.sh' \
  "$(
    cat <<'EOF'
  [ "$wrong" = '[]' ] ||
EOF
  )" \
  '  true ||' \
  'a subtask left behind in the old project is reported as moved with its parent'

defect 'verify/project-tree-read' 'sp.sh' \
  "$(
    cat <<'EOF'
    if project_id=$(jq -er '.projectId // empty' <<<"$BODY"); then
EOF
  )" \
  '    if false; then' \
  "a move to another project never checks the parent's subtasks"

defect 'verify/absent' 'sp.sh' \
  "$(
    cat <<'EOF'
  [ "$found" = '[]' ] || die $E_VERIFY "delete verification failed: task $id is still present"
EOF
  )" \
  '  true' \
  'a task the app kept is reported as deleted'

defect 'verify/archive' 'sp.sh' \
  "$(
    cat <<'EOF'
  [ "$found" != '[]' ] || die $E_VERIFY "write verification failed: task $id is not in the $want list"
EOF
  )" \
  '  true' \
  'a task the app left where it was is reported as archived or restored'

defect 'verify/archive-partition' 'sp.sh' \
  "$(
    cat <<'EOF'
  [ "$found" = '[]' ] || die $E_VERIFY "write verification failed: task $id is still in the $other list"
EOF
  )" \
  '  true' \
  'an app that serves the task from both lists, having ignored source, is reported as having moved it'

defect 'verify/add' 'sp.sh' \
  "$(
    cat <<'EOF'
    verify_task "$id" "$BODY" | fmt ;;
EOF
  )" \
  "$(
    cat <<'EOF'
    printf '%s' "$created" | fmt ;;
EOF
  )" \
  "a new task is reported from the app's optimistic answer, with fields it never stored"

# Names to ids: never a guess
defect 'resolve/by-id' 'sp.sh' \
  "$(
    cat <<'EOF'
    if $byId then "ok\t" + $byId
EOF
  )" \
  "$(
    cat <<'EOF'
    if false then "ok\t" + $byId
EOF
  )" \
  'a project or tag given by its id, as list prints it, is refused as unknown'

defect 'resolve/ambiguous' 'sp.sh' \
  "$(
    cat <<'EOF'
    ambiguous) die $E_NAME "${kind%s} \"$needle\" is ambiguous: $rest" ;;
EOF
  )" \
  "$(
    cat <<'EOF'
    ambiguous) printf '%s' "${rest%%, *}" ;;
EOF
  )" \
  'a name two tags or projects share picks one of them, and the task lands where the user did not mean'

defect 'resolve/unknown' 'sp.sh' \
  "$(
    cat <<'EOF'
    else "none\t" + (map(.title) | join(", ")) end') || exit $?
EOF
  )" \
  "$(
    cat <<'EOF'
    else "ok\t" + $n end') || exit $?
EOF
  )" \
  'an unknown name is sent as an id, and the task is moved into a project or tagged with a tag that does not exist'

defect 'resolve/list' 'sp.sh' \
  "$(
    cat <<'EOF'
    id=$(resolve "$kind" "$item") || exit $?
EOF
  )" \
  "$(
    cat <<'EOF'
    id=$(resolve "$kind" "$item") || continue
EOF
  )" \
  'an unknown tag in --tag a,b is dropped silently, and the task is saved with only the tags that did resolve'

defect 'resolve/cyrillic-case' 'sp.sh' \
  '    if . >= 1040 and . <= 1071 then . + 32' \
  '    if false then . + 32' \
  'a Cyrillic name typed in another case, "важное" for "Важное", is refused as unknown'

defect 'resolve/yo' 'sp.sh' \
  '    elif . == 1025 or . == 1105 then 1077' \
  '    elif false then 1077' \
  'a name typed with е where the app spells it with ё is refused as unknown'

defect 'tag/today' 'sp.sh' \
  "$(
    cat <<'EOF'
      TODAY | today | Today) die $E_USAGE
EOF
  )" \
  "$(
    cat <<'EOF'
      never-a-tag) die $E_USAGE
EOF
  )" \
  'TODAY given as a tag is sent to the API as a name, and the agent never learns it is a due-date filter'

# What a write is allowed to carry
defect 'subtask/no-project' 'sp.sh' \
  "$(
    cat <<'EOF'
      die $E_USAGE "a subtask inherits its parent's project and tags — drop --project/--tag"
EOF
  )" \
  '      true' \
  "a subtask is created with a project or tags of its own, disagreeing with its parent's"

defect 'set/no-reparent' 'sp.sh' \
  "$(
    cat <<'EOF'
    [ -n "$OPT_PARENT" ] && die $E_USAGE "the API cannot re-parent a task — delete and recreate it"
EOF
  )" \
  '    true' \
  'set --parent sends a field the API ignores, instead of saying a subtask cannot be moved'

defect 'set/nothing' 'sp.sh' \
  "$(
    cat <<'EOF'
    [ "$BODY" = '{}' ] && die $E_USAGE "set needs at least one option to change"
EOF
  )" \
  '    true' \
  'set with nothing to change sends an empty write and reports success'

defect 'set/tag-mixed' 'sp.sh' \
  "$(
    cat <<'EOF'
        [ ${#bare[@]} -eq 0 ] ||
EOF
  )" \
  '        true ||' \
  '--tag a,+b both replaces and edits the set, and the result is neither'

defect 'set/tag-current' 'sp.sh' \
  "$(
    cat <<'EOF'
        cur=$(api GET "/tasks/${POS[0]}" | jq -c '.tagIds // []') || exit $?
EOF
  )" \
  "        cur='[]'" \
  "--tag +name replaces the task's tags instead of adding one"

defect 'set/tag-remove' 'sp.sh' \
  "'. + \$a - \$d | unique'" \
  "'. + \$a | unique'" \
  '--tag -name leaves the tag on the task'

# Values: a bad one is refused, a good one is sent as meant
defect 'due/relative' 'sp.sh' \
  "$(
    cat <<'EOF'
    +[0-9]*d) [[ ${1%d} =~ ^\+[0-9]+$ ]] || die $E_USAGE "bad --due value \"$1\""; day_offset "${1%d}" ;;
EOF
  )" \
  "$(
    cat <<'EOF'
    +[0-9]*d) day_offset "${1%d}" ;;
EOF
  )" \
  'a mistyped --due such as +3xd reaches date and exits as the app being unreachable'

defect 'due/day-exists' 'sp.sh' \
  "$(
    cat <<'EOF'
is_day "$1" || die $E_USAGE "bad date: $1"; printf '%s' "$1"
EOF
  )" \
  "$(
    cat <<'EOF'
printf '%s' "$1"
EOF
  )" \
  'a day that does not exist, 2026-02-30, is sent as a due date'

defect 'due/round-trip' 'sp.sh' \
  "$(
    cat <<'EOF'
  [ "$got" = "$1" ]
}
EOF
  )" \
  "$(
    cat <<'EOF'
  true
}
EOF
  )" \
  "on macOS a day that does not exist rolls over into the next month, and the task is due on a day nobody asked for"

defect 'at/round-trip' 'sp.sh' \
  "$(
    cat <<'EOF'
  [ "$got" = "$1" ] || return 1
EOF
  )" \
  '  true' \
  'on macOS an hour that does not exist rolls over into the next day, and the task is due then'

defect 'est/value' 'sp.sh' \
  "$(
    cat <<'EOF'
  printf '%s' "$(((h * 60 + m) * 60000))"
EOF
  )" \
  "  printf '0'" \
  'every estimate is saved as zero'

defect 'est/refuse' 'sp.sh' \
  "$(
    cat <<'EOF'
  [[ $h =~ ^[0-9]+$ && $m =~ ^[0-9]+$ ]] || die $E_USAGE "bad --est value \"$spec\""
EOF
  )" \
  '  true' \
  'a mistyped estimate such as 1hxm is saved as an hour, with nothing said about the rest'

# Reading: what list asks the API for
defect 'list/archived-done' 'sp.sh' \
  "$(
    cat <<'EOF'
  { [ "$OPT_DONE_FILTER" = 1 ] || [ "$OPT_ALL" = 1 ] || [ "$OPT_SOURCE" = archived ]; } &&
EOF
  )" \
  "$(
    cat <<'EOF'
  { [ "$OPT_DONE_FILTER" = 1 ] || [ "$OPT_ALL" = 1 ]; } &&
EOF
  )" \
  'list --source archived asks for open tasks only, and the archive, done by definition, reads as empty'

defect 'list/all' 'sp.sh' \
  "$(
    cat <<'EOF'
  [ "$OPT_ALL" = 1 ] && OPT_SOURCE=${OPT_SOURCE:-all}
EOF
  )" \
  '  true' \
  'list --all leaves archived tasks out, and an audit that relied on it misses them'

defect 'list/query-encoded' 'sp.sh' \
  "$(
    cat <<'EOF'
  [ -n "$OPT_QUERY" ] && qs+="&query=$(jq -rR @uri <<<"$OPT_QUERY")"
EOF
  )" \
  "$(
    cat <<'EOF'
  [ -n "$OPT_QUERY" ] && qs+="&query=$OPT_QUERY"
EOF
  )" \
  'a query with a space or an & in it is cut there, and the search runs for part of what was asked'

defect 'list/limit' 'sp.sh' \
  "$(
    cat <<'EOF'
  [ -n "$OPT_LIMIT" ] && data=$(jq -c ".[:$OPT_LIMIT]" <<<"$data")
EOF
  )" \
  '  true' \
  'list --limit prints every task'

defect 'list/today' 'sp.sh' \
  '    tag_id=TODAY' \
  "    tag_id=''" \
  'list --today prints every task instead of those due today'

# Stats: what the numbers add up
defect 'stats/leaves' 'sp.sh' \
  "$(
    cat <<'EOF'
    [.[] | select(((.subTaskIds // []) | length) == 0)] as $leaves |
EOF
  )" \
  "$(
    cat <<'EOF'
    [.[]] as $leaves |
EOF
  )" \
  "a parent's time, the sum of its subtasks', is counted again beside them, and stats report more than was tracked"

defect 'stats/window' 'sp.sh' \
  "$(
    cat <<'EOF'
      then (.timeSpentOnDay // {}) | to_entries | map(select(.key >= $since) | .value) | add // 0
EOF
  )" \
  '      then .timeSpent // 0' \
  '--days reports all-time spent as if it went in during the window'

defect 'stats/window-flag' 'sp.sh' \
  "$(
    cat <<'EOF'
  { [ "$OPT_BY" = day ] || [ "$OPT_DAYS_SET" = 1 ]; } && win=true
EOF
  )" \
  "$(
    cat <<'EOF'
  [ "$OPT_BY" = day ] && win=true
EOF
  )" \
  'stats --by project --days N ignores the window and reports all-time spent'

# Flags
defect 'flags/value' 'sp.sh' \
  "$(
    cat <<'EOF'
  if [ $# -lt 2 ] || [ -z "$2" ]; then die $E_USAGE "$1 needs a value"; fi
EOF
  )" \
  '  :' \
  'a flag given without its value dies on an unbound variable with exit 1, read as the app being down'

defect 'flags/dash-id' 'sp.sh' \
  "$(
    cat <<'EOF'
      [[ $1 =~ ^-[A-Za-z0-9_-]{20}$ ]] || { usage >&2; die $E_USAGE
EOF
  )" \
  "$(
    cat <<'EOF'
      false || { usage >&2; die $E_USAGE
EOF
  )" \
  'a task whose id opens with a dash, as list prints it, cannot be touched by any command'
