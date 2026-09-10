#!/usr/bin/env bash
# CLI over Super Productivity's Local REST API (Settings -> Misc -> Enable local REST API)
set -euo pipefail

SP_API=${SP_API:-http://127.0.0.1:3876}
SP_TIMEOUT=${SP_TIMEOUT:-10}

# Where this script really lives. $0 may be a symlink, and is followed by hand because
# `readlink -f` is missing from older macOS; pwd -P resolves a symlinked directory
src=$0
while [ -L "$src" ]; do
  link=$(readlink "$src")
  case $link in
    /*) src=$link ;;
    *) src=$(dirname "$src")/$link ;;
  esac
done
HERE=$(cd -- "$(dirname -- "$src")" && pwd -P)

# The token and the private notes belong to the user, not to the install. They stay in
# the skill directory when it already holds them — a clone synced between machines
# carries them along — and otherwise go to the XDG config directory, because a plugin or
# `npx skills` update replaces the skill directory whole. The layout is the same in both:
# secrets/token and user/. The env var wins so one call can hit another instance
# without touching the file
if [ -z "${SP_HOME:-}" ]; then
  if [ -e "$HERE/secrets" ] || [ -e "$HERE/user" ]; then
    SP_HOME=$HERE
  else
    SP_HOME=${XDG_CONFIG_HOME:-$HOME/.config}/super-productivity-skill
  fi
fi
SP_TOKEN=${SP_TOKEN:-}
SP_TOKEN_FILE=${SP_TOKEN_FILE:-$SP_HOME/secrets/token}
if [ -z "$SP_TOKEN" ] && [ -r "$SP_TOKEN_FILE" ]; then
  SP_TOKEN=$(tr -d '[:space:]' <"$SP_TOKEN_FILE")
fi

E_USAGE=1
E_CONN=2
E_NAME=3
E_API=4
E_AUTH=5
E_DATA=6

usage() {
  cat <<'EOF'
sp.sh — Super Productivity over its Local REST API

  help                         this text
  home                         the private directory: token and user/ notes
  health                       server + renderer status, as JSON
  current                      currently tracked task, as JSON
  projects | tags              id and title of every project / tag
  list   [filters]             tasks, one line each
  get    <id>                  a single task
  add    "title" [options]     create a task
  set    <id> [options]        update a task: any add option but --parent
  done   <id>...               mark done
  rm     <id>...               delete (irreversible)
  start  <id>                  start the timer on a task
  stop                         stop the timer
  archive <id>... | restore <id>...
  stats  [--days N] [--by project|tag|day]

Filters for list:
  --project P   --tag T   --query TEXT   --today   --done   --all
  --source active|archived|all            --limit N

Options for add / set:
  --project P            project by title or id (a task lives in exactly one)
  --tag T[,T2]           tags by title or id; on set, T,T2 replaces the set
                         while +T adds and -T removes — one form or the other
  --due today|tomorrow|+3d|YYYY-MM-DD|none
  --at "YYYY-MM-DD HH:MM"|none            due date with a time
  --est 90m|1h30m|2h|0                    time estimate
  --notes TEXT           --title TEXT (set only)
  --parent <id>          (add only) create as a subtask; excludes --project and --tag
  --done | --undone      (set only)

--json prints the raw API payload instead of the one-line format, for list, get,
add, set, done, projects and tags; health and current print JSON anyway

A task id may open with "-": pass it as it is, or after --, which ends the options
(sp.sh set --est 2h -- <id>)

stats counts leaf tasks. --by day lists the last N days (default 7, today
included); --by project and --by tag show all-time spent unless --days is given,
and then only what was spent in that window

Environment: SP_API (default http://127.0.0.1:3876), SP_TOKEN, SP_HOME (default this
script's directory when it holds secrets/ or user/, else
$XDG_CONFIG_HOME/super-productivity-skill), SP_TOKEN_FILE (default
SP_HOME/secrets/token), SP_TIMEOUT

The token comes from Settings -> Misc -> Access Token

Exit codes and what the API cannot do: SKILL.md beside this script
EOF
}

die() {
  local code=$1
  shift
  printf '%s\n' "$*" >&2
  exit "$code"
}

# jq's own failures — 2 system, 3 compile, 5 runtime — would otherwise leak out as this
# script's status, where 3 and 5 already mean "name unresolved" and "token rejected".
# 1 and 4 are -e verdicts, not failures, and pass through
jq() {
  local rc=0
  command jq "$@" || rc=$?
  case $rc in
    2 | 3 | 5) die $E_DATA "jq failed with code $rc: the API sent data of an unexpected shape, or sp.sh has a bug" ;;
  esac
  return "$rc"
}

# jq helpers shared by every filter below
# shellcheck disable=SC2016
JQ_LIB='
def fold: explode | map(
    if . >= 1040 and . <= 1071 then . + 32
    elif . == 1025 or . == 1105 then 1077
    else . end) | implode | ascii_downcase;
def dur: (. // 0) as $ms |
  if $ms <= 0 then "0m" else
    (($ms / 60000) | floor) as $m | (($m / 60) | floor) as $h | ($m % 60) as $r |
    (if $h > 0 then "\($h)h" else "" end) + (if $r > 0 or $h == 0 then "\($r)m" else "" end)
  end;
def line($p; $t):
  (if .isDone then "x " else "- " end)
  + (if (.parentId // null) != null then "sub " else "" end)
  + .id + "  " + .title
  + (if (.projectId // "INBOX_PROJECT") == "INBOX_PROJECT" then ""
     else "  @" + ($p[.projectId] // .projectId) end)
  + ((.tagIds // []) | map("  #" + ($t[.] // .)) | join(""))
  + (if (.dueWithTime // null) != null then "  ~" + (.dueWithTime / 1000 | strflocaltime("%Y-%m-%d %H:%M"))
     elif (.dueDay // null) != null then "  ~" + .dueDay else "" end)
  + (if (.timeSpent // 0) > 0 or (.timeEstimate // 0) > 0
     then "  [" + (.timeSpent | dur) + "/" + (.timeEstimate | dur) + "]" else "" end)
  + (if ((.subTaskIds // []) | length) > 0 then "  (+\((.subTaskIds | length)))" else "" end);
'

api() {
  local method=$1 path=$2 body=${3:-} out rc=0 code json
  local -a args=(-sS --max-time "$SP_TIMEOUT" -X "$method" -H 'Content-Type: application/json' -w $'\n%{http_code}')
  [ -n "$SP_TOKEN" ] && args+=(-H "Authorization: Bearer $SP_TOKEN")
  [ -n "$body" ] && args+=(--data-binary "$body")

  out=$(curl "${args[@]}" "$SP_API$path" 2>/dev/null) || rc=$?
  case $rc in
    0) ;;
    1 | 3) die $E_USAGE "SP_API=$SP_API is not a URL curl can use (curl code $rc)" ;;
    6 | 7 | 28) die $E_CONN "cannot reach Super Productivity at $SP_API
start the desktop app and enable Settings -> Misc -> Enable local REST API" ;;
    *) die $E_CONN "curl failed with code $rc on $method $path" ;;
  esac

  code=${out##*$'\n'}
  json=${out%$'\n'*}
  # the real jq: a parse failure here is the diagnosis, not an internal error
  if [ -z "$json" ] || ! command jq -e . >/dev/null 2>&1 <<<"$json"; then
    die $E_API "HTTP $code: unexpected non-JSON response"
  fi
  if [ "$(jq -r '.ok' <<<"$json")" != "true" ]; then
    if [ "$code" = 401 ]; then
      die $E_AUTH "HTTP 401: the API rejected the token
copy it from Settings -> Misc -> Access Token into $SP_TOKEN_FILE (chmod 600)"
    fi
    die $E_API "$(jq -r '"\(.error.code // "ERROR"): \(.error.message // "request failed")"' <<<"$json")"
  fi
  jq -c '.data' <<<"$json"
}

# one fetch per process, both catalogs are needed to print any task line
_projects='' _tags=''
catalog() {
  case $1 in
    projects) [ -n "$_projects" ] || _projects=$(api GET /projects); printf '%s' "$_projects" ;;
    tags) [ -n "$_tags" ] || _tags=$(api GET /tags); printf '%s' "$_tags" ;;
  esac
}

name_map() { catalog "$1" | jq -c 'map({key: .id, value: .title}) | from_entries'; }

# title -> id: exact id, then exact title, then unique substring; never guesses
resolve() {
  local kind=$1 needle=$2 res
  res=$(catalog "$kind" | jq -r --arg n "$needle" "$JQ_LIB"'
    ($n | fold) as $f |
    (map(select(.id == $n)) | .[0].id) as $byId |
    (map(select((.title | fold) == $f))) as $exact |
    (map(select((.title | fold) | index($f)))) as $sub |
    if $byId then "ok\t" + $byId
    elif ($exact | length) == 1 then "ok\t" + $exact[0].id
    elif ($exact | length) > 1 then "ambiguous\t" + ($exact | map(.title) | join(", "))
    elif ($sub | length) == 1 then "ok\t" + $sub[0].id
    elif ($sub | length) > 1 then "ambiguous\t" + ($sub | map(.title) | join(", "))
    else "none\t" + (map(.title) | join(", ")) end') || exit $?

  local status=${res%%$'\t'*} rest=${res#*$'\t'}
  case $status in
    ok) printf '%s' "$rest" ;;
    ambiguous) die $E_NAME "${kind%s} \"$needle\" is ambiguous: $rest" ;;
    none)
      local other hint=''
      other=$([ "$kind" = projects ] && echo tags || echo projects)
      # a name that misses in one namespace usually hits in the other
      if catalog "$other" | jq -e -r --arg n "$needle" "$JQ_LIB"'
           ($n | fold) as $f | map(select((.title | fold) | index($f))) | length > 0' >/dev/null; then
        hint="
but a ${other%s} matches it — use --$([ "$other" = tags ] && echo tag || echo project) instead"
      fi
      die $E_NAME "no ${kind%s} matches \"$needle\"
known: $rest$hint
the REST API cannot create projects or tags — add it in the app first" ;;
  esac
}

resolve_list() {
  local kind=$1 csv=$2 out=() item items=() id
  IFS=, read -ra items <<<"$csv"
  # ${a[@]+"${a[@]}"}: bash before 4.4 calls an empty array unbound under set -u, and
  # macOS ships 3.2
  for item in ${items[@]+"${items[@]}"}; do
    [ -n "$item" ] || continue
    # a bare out+=("$(resolve …)") would swallow the failure exit inside the subshell
    id=$(resolve "$kind" "$item") || exit $?
    out+=("$id")
  done
  [ ${#out[@]} -gt 0 ] || { printf '[]'; return; }
  printf '%s\n' "${out[@]}" | jq -R . | jq -sc .
}

# GNU date parses with -d; BSD date, the one macOS ships, adjusts with -v and parses with
# -j -f. Which one is here is asked once, and every date goes through the helpers below
if date --version >/dev/null 2>&1; then DATE_GNU=1; else DATE_GNU=0; fi

day_offset() { # day_offset N -> the day N days from today, N may be negative, YYYY-MM-DD
  if [ "$DATE_GNU" = 1 ]; then date -d "$1 days" +%F; else date -v"$(printf '%+d' "$1")"d +%F; fi
}

# BSD date rolls 2026-02-30 over into March rather than failing, so a value only counts
# as a date when formatting it back gives the same text
is_day() { # is_day YYYY-MM-DD -> 0 when that day exists
  local got
  if [ "$DATE_GNU" = 1 ]; then got=$(date -d "$1" +%F 2>/dev/null) || return 1
  else got=$(date -j -f %Y-%m-%d "$1" +%F 2>/dev/null) || return 1; fi
  [ "$got" = "$1" ]
}

epoch_at() { # epoch_at "YYYY-MM-DD HH:MM" -> seconds since the epoch in local time
  local got
  # BSD fills the fields a format leaves out from the current time, so seconds are given
  if [ "$DATE_GNU" = 1 ]; then got=$(date -d "$1" '+%Y-%m-%d %H:%M' 2>/dev/null) || return 1
  else got=$(date -j -f '%Y-%m-%d %H:%M:%S' "$1:00" '+%Y-%m-%d %H:%M' 2>/dev/null) || return 1; fi
  [ "$got" = "$1" ] || return 1
  if [ "$DATE_GNU" = 1 ]; then date -d "$1" +%s; else date -j -f '%Y-%m-%d %H:%M:%S' "$1:00" +%s; fi
}

parse_due() {
  case $1 in
    today) date +%F ;;
    tomorrow) day_offset 1 ;;
    +[0-9]*d) [[ ${1%d} =~ ^\+[0-9]+$ ]] || die $E_USAGE "bad --due value \"$1\""; day_offset "${1%d}" ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) is_day "$1" || die $E_USAGE "bad date: $1"; printf '%s' "$1" ;;
    *) die $E_USAGE "bad --due value \"$1\" — use today, tomorrow, +3d or YYYY-MM-DD" ;;
  esac
}

parse_at() {
  local secs
  secs=$(epoch_at "$1") || die $E_USAGE "bad --at value \"$1\" — use \"YYYY-MM-DD HH:MM\""
  printf '%s' "$((secs * 1000))"
}

parse_est() {
  local spec=$1 h=0 m=0
  case $spec in
    0) printf '0'; return ;;
    *h*m) h=${spec%%h*}; m=${spec#*h}; m=${m%m} ;;
    *h) h=${spec%h} ;;
    *m) m=${spec%m} ;;
    *[!0-9]*) die $E_USAGE "bad --est value \"$spec\" — use 90m, 1h30m, 2h or a plain number of minutes" ;;
    *) m=$spec ;;
  esac
  [[ $h =~ ^[0-9]+$ && $m =~ ^[0-9]+$ ]] || die $E_USAGE "bad --est value \"$spec\""
  printf '%s' "$(((h * 60 + m) * 60000))"
}

# task JSON on stdin -> one line each
fmt() {
  if [ "${OPT_JSON:-}" = 1 ]; then
    jq .
    return
  fi
  local pmap tmap
  pmap=$(name_map projects) || exit $?
  tmap=$(name_map tags) || exit $?
  jq -r --argjson p "$pmap" --argjson t "$tmap" "$JQ_LIB"'
    (if type == "array" then . else [.] end) | .[] | line($p; $t)'
}

OPT_JSON=0 OPT_PROJECT='' OPT_TAG='' OPT_DUE='' OPT_AT='' OPT_EST='' OPT_NOTES='' \
  OPT_PARENT='' OPT_TITLE='' OPT_QUERY='' OPT_SOURCE='' OPT_LIMIT='' OPT_DAYS=7 OPT_DAYS_SET=0 OPT_BY=project
OPT_TODAY=0 OPT_DONE_FILTER=0 OPT_ALL=0 OPT_MARK=''
POS=()
HAS_NOTES=0

parse_flags() {
  while [ $# -gt 0 ]; do
    case $1 in
      --json) OPT_JSON=1 ;;
      --project) OPT_PROJECT=${2:?--project needs a value}; shift ;;
      --tag) OPT_TAG=${2:?--tag needs a value}; shift ;;
      --due) OPT_DUE=${2:?--due needs a value}; shift ;;
      --at) OPT_AT=${2:?--at needs a value}; shift ;;
      --est) OPT_EST=${2:?--est needs a value}; shift ;;
      --notes) OPT_NOTES=${2?--notes needs a value}; HAS_NOTES=1; shift ;;
      --title) OPT_TITLE=${2:?--title needs a value}; shift ;;
      --parent) OPT_PARENT=${2:?--parent needs a value}; shift ;;
      --query) OPT_QUERY=${2:?--query needs a value}; shift ;;
      --source) OPT_SOURCE=${2:?--source needs a value}; shift ;;
      --limit)
        OPT_LIMIT=${2:?--limit needs a value}; shift
        [[ $OPT_LIMIT =~ ^[0-9]+$ ]] || die $E_USAGE "--limit takes a whole number, not \"$OPT_LIMIT\"" ;;
      --days)
        OPT_DAYS=${2:?--days needs a value}; OPT_DAYS_SET=1; shift
        [[ $OPT_DAYS =~ ^[1-9][0-9]*$ ]] || die $E_USAGE "--days takes a whole number of days from 1, not \"$OPT_DAYS\"" ;;
      --by) OPT_BY=${2:?--by needs a value}; shift ;;
      --today) OPT_TODAY=1 ;;
      --done) OPT_DONE_FILTER=1; OPT_MARK=true ;;
      --undone) OPT_MARK=false ;;
      --all) OPT_ALL=1 ;;
      --) shift; POS+=("$@"); return ;;
      # A task id is a nanoid and "-" is in its alphabet, so an id can open with one: a word
      # of an id's shape is an id rather than an unknown flag, and `--` works before any
      -*)
        [[ $1 =~ ^-[A-Za-z0-9_-]{20}$ ]] || { usage >&2; die $E_USAGE "unknown flag: $1 — a task id that opens with - can also go after --"; }
        POS+=("$1") ;;
      *) POS+=("$1") ;;
    esac
    shift
  done
}

# TODAY is a virtual tag: SP derives it from dueDay, no task ever stores it
reject_today_tag() {
  local item items=()
  IFS=, read -ra items <<<"$OPT_TAG"
  for item in ${items[@]+"${items[@]}"}; do
    case ${item#[+-]} in
      TODAY | today | Today) die $E_USAGE "TODAY is a due-date filter, not a real tag — use --due today" ;;
    esac
  done
}

body_set() { BODY=$(jq -c --arg k "$1" --argjson v "$2" '.[$k] = $v' <<<"$BODY"); }
json_str() { jq -nc --arg s "$1" '$s'; }  # -R would split a multiline value into several JSON strings

# every helper below is assigned on its own line: a die() inside $( ) exits only the
# subshell, so its status has to reach set -e through a plain assignment
build_body() {
  BODY='{}'
  local val
  [ -n "$OPT_TAG" ] && reject_today_tag
  if [ -n "$OPT_PARENT" ]; then
    [ -z "$OPT_PROJECT" ] && [ -z "$OPT_TAG" ] ||
      die $E_USAGE "a subtask inherits its parent's project and tags — drop --project/--tag"
    body_set parentId "$(json_str "$OPT_PARENT")"
  fi
  [ -n "$OPT_TITLE" ] && body_set title "$(json_str "$OPT_TITLE")"
  [ "$HAS_NOTES" = 1 ] && body_set notes "$(json_str "$OPT_NOTES")"
  [ -n "$OPT_MARK" ] && body_set isDone "$OPT_MARK"
  if [ -n "$OPT_PROJECT" ]; then
    val=$(resolve projects "$OPT_PROJECT") || exit $?
    body_set projectId "$(json_str "$val")"
  fi
  if [ -n "$OPT_EST" ]; then
    val=$(parse_est "$OPT_EST") || exit $?
    body_set timeEstimate "$val"
  fi
  if [ -n "$OPT_DUE" ]; then
    if [ "$OPT_DUE" = none ]; then
      body_set dueDay null
    else
      val=$(parse_due "$OPT_DUE") || exit $?
      body_set dueDay "$(json_str "$val")"
    fi
  fi
  if [ -n "$OPT_AT" ]; then
    if [ "$OPT_AT" = none ]; then
      body_set dueWithTime null
    else
      val=$(parse_at "$OPT_AT") || exit $?
      body_set dueWithTime "$val"
    fi
  fi
}

cmd_list() {
  local qs='' tag_id='' project_id=''
  [ -n "$OPT_QUERY" ] && qs+="&query=$(jq -rR @uri <<<"$OPT_QUERY")"
  if [ -n "$OPT_PROJECT" ]; then
    project_id=$(resolve projects "$OPT_PROJECT") || exit $?
    qs+="&projectId=$project_id"
  fi
  if [ "$OPT_TODAY" = 1 ]; then
    tag_id=TODAY
  elif [ -n "$OPT_TAG" ]; then
    tag_id=$(resolve tags "$OPT_TAG") || exit $?
  fi
  [ -n "$tag_id" ] && qs+="&tagId=$tag_id"
  [ "$OPT_ALL" = 1 ] && OPT_SOURCE=${OPT_SOURCE:-all}
  # every archived task is done, so without includeDone the archive reads as empty
  { [ "$OPT_DONE_FILTER" = 1 ] || [ "$OPT_ALL" = 1 ] || [ "$OPT_SOURCE" = archived ]; } &&
    qs+='&includeDone=true'
  [ -n "$OPT_SOURCE" ] && qs+="&source=$OPT_SOURCE"

  local data
  data=$(api GET "/tasks?${qs#&}")
  [ -n "$OPT_LIMIT" ] && data=$(jq -c ".[:$OPT_LIMIT]" <<<"$data")
  printf '%s' "$data" | fmt
}

cmd_stats() {
  local data since pmap tmap win=false
  case $OPT_BY in
    project | tag | day) ;;
    *) die $E_USAGE "--by takes project, tag or day" ;;
  esac
  data=$(api GET '/tasks?includeDone=true&source=all')
  pmap=$(name_map projects) || exit $?
  tmap=$(name_map tags) || exit $?
  # the last N days include today, so the window opens N-1 days back
  since=$(day_offset "-$((OPT_DAYS - 1))")
  { [ "$OPT_BY" = day ] || [ "$OPT_DAYS_SET" = 1 ]; } && win=true
  jq -r --arg by "$OPT_BY" --arg since "$since" --argjson days "$OPT_DAYS" --argjson win "$win" \
    --argjson p "$pmap" --argjson t "$tmap" "$JQ_LIB"'
    # inside a window only timeSpentOnDay can say when the time went in
    def spent: if $win
      then (.timeSpentOnDay // {}) | to_entries | map(select(.key >= $since) | .value) | add // 0
      else .timeSpent // 0 end;
    # only leaves count: a parent stores the sum of its subtasks timeSpent
    [.[] | select(((.subTaskIds // []) | length) == 0)] as $leaves |
    ($leaves | map(select(.isDone | not)) | length) as $open |
    ($leaves | map(select(.isDone)) | length) as $done |
    ($leaves | map(spent) | add // 0) as $spent |
    "leaf tasks \($leaves | length)  open \($open)  done \($done)  tracked \($spent | dur)",
    (if $by == "day" then
      ($leaves | map((.timeSpentOnDay // {}) | to_entries) | add // []
        | map(select(.key >= $since)) | group_by(.key) | sort_by(.[0].key) | reverse
        | .[] | "\(.[0].key)  \(map(.value) | add | dur)")
     elif $by == "project" then
      ($leaves | group_by(.projectId // "INBOX_PROJECT") | sort_by(-(map(spent) | add)) | .[]
        | "\($p[.[0].projectId // "INBOX_PROJECT"] // .[0].projectId)  \(map(spent) | add | dur) spent  \(map(.timeEstimate // 0) | add | dur) est  \(map(select(.isDone | not)) | length) open  \(length) total")
     else
      ($leaves | map(. as $task | ((.tagIds // []) | if length == 0 then ["(untagged)"] else . end)
        | map({tag: ., task: $task})) | add // [] | group_by(.tag) | sort_by(-(map(.task | spent) | add)) | .[]
        | "\($t[.[0].tag] // .[0].tag)  \(map(.task | spent) | add | dur) spent  \(map(select(.task.isDone | not)) | length) open  \(length) total")
     end),
    (if $by == "tag" then "tags overlap, so rows do not sum to the total" else empty end),
    (if $win then "window: the last \($days) days, today included"
       + (if $by == "day" then "" else "; estimates and open counts are not windowed" end)
     else empty end)' <<<"$data"
}

main() {
  [ $# -gt 0 ] || { usage; exit 0; }
  local cmd=$1 tag_ids='' cur='' add_ids='' del_ids='' id='' title='' item
  local -a items=() plus=() minus=() bare=()
  shift
  parse_flags "$@"

  case $cmd in
    help | -h | --help) usage ;;
    home) printf '%s\n' "$SP_HOME" ;;
    health) api GET /health | jq . ;;
    current) api GET /status | jq . ;;
    projects | tags)
      if [ "$OPT_JSON" = 1 ]; then catalog "$cmd" | jq .
      else catalog "$cmd" | jq -r '.[] | "\(.id)\t\(.title)"'; fi ;;
    list) cmd_list ;;
    get)
      [ ${#POS[@]} -ge 1 ] || die $E_USAGE "get needs a task id"
      api GET "/tasks/${POS[0]}" | fmt ;;
    add)
      [ ${#POS[@]} -ge 1 ] || die $E_USAGE "add needs a title"
      OPT_TITLE=${POS[0]}
      build_body
      if [ -n "$OPT_TAG" ]; then
        tag_ids=$(resolve_list tags "$OPT_TAG") || exit $?
        body_set tagIds "$tag_ids"
      fi
      api POST /tasks "$BODY" | fmt ;;
    set)
      [ ${#POS[@]} -ge 1 ] || die $E_USAGE "set needs a task id"
      [ -n "$OPT_PARENT" ] && die $E_USAGE "the API cannot re-parent a task — delete and recreate it"
      build_body
      if [ -n "$OPT_TAG" ]; then
        # only an item's first character decides its role — a hyphen inside a name
        # such as foo-bar is part of the name
        IFS=, read -ra items <<<"$OPT_TAG"
        for item in ${items[@]+"${items[@]}"}; do
          case $item in
            +*) plus+=("${item#+}") ;;
            -*) minus+=("${item#-}") ;;
            ?*) bare+=("$item") ;;
          esac
        done
        if [ ${#plus[@]} -gt 0 ] || [ ${#minus[@]} -gt 0 ]; then
          [ ${#bare[@]} -eq 0 ] ||
            die $E_USAGE "--tag either replaces the set (a,b) or edits it (+a,-b) — \"$OPT_TAG\" mixes both"
          # a bare --tag replaces the whole array, so +x/-y merge against the current one
          cur=$(api GET "/tasks/${POS[0]}" | jq -c '.tagIds // []') || exit $?
          add_ids=$(resolve_list tags "$(IFS=,; printf '%s' "${plus[*]+${plus[*]}}")") || exit $?
          del_ids=$(resolve_list tags "$(IFS=,; printf '%s' "${minus[*]+${minus[*]}}")") || exit $?
          tag_ids=$(jq -c --argjson a "$add_ids" --argjson d "$del_ids" '. + $a - $d | unique' <<<"$cur")
        else
          tag_ids=$(resolve_list tags "$OPT_TAG") || exit $?
        fi
        body_set tagIds "$tag_ids"
      fi
      [ "$BODY" = '{}' ] && die $E_USAGE "set needs at least one option to change"
      api PATCH "/tasks/${POS[0]}" "$BODY" | fmt ;;
    done)
      [ ${#POS[@]} -ge 1 ] || die $E_USAGE "done needs a task id"
      for id in "${POS[@]}"; do api PATCH "/tasks/$id" '{"isDone":true}' | fmt; done ;;
    rm)
      [ ${#POS[@]} -ge 1 ] || die $E_USAGE "rm needs a task id"
      for id in "${POS[@]}"; do

        title=$(api GET "/tasks/$id" | jq -r '.title') || exit $?
        api DELETE "/tasks/$id" >/dev/null
        printf 'deleted: %s  %s\n' "$id" "$title"
      done ;;
    start)
      [ ${#POS[@]} -ge 1 ] || die $E_USAGE "start needs a task id"
      api POST "/tasks/${POS[0]}/start" >/dev/null
      api GET /status | jq . ;;
    stop) api POST /task-control/stop | jq . ;;
    archive | restore)
      [ ${#POS[@]} -ge 1 ] || die $E_USAGE "$cmd needs a task id"
      for id in "${POS[@]}"; do api POST "/tasks/$id/$cmd" >/dev/null && printf '%sd: %s\n' "$cmd" "$id"; done ;;
    stats) cmd_stats ;;
    *) usage >&2; die $E_USAGE "unknown command: $cmd" ;;
  esac
}

main "$@"
