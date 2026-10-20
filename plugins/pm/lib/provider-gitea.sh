# The Gitea provider, through Gitea's web API ($GITEA_URL/api/v1) with curl and jq.
#
#   GITEA_URL    base URL of the instance, e.g. https://gitea.com
#   GITEA_TOKEN  an access token with issue and repository scope
#
# curl and jq rather than a Gitea CLI: pm already needs jq, and a CLI would be
# one more dependency. Gitea only; Forgejo is not claimed.
#
# Every API read goes to a temp file, never through $( ): a subshell would drop
# the PROVIDER_ERR it set.

PROVIDER_ERR=""

# _gitea_api <method> <path> [<json-body-file>] -> response body on stdout.
# Non-2xx puts "HTTP <code> ...: <Gitea's message>" in PROVIDER_ERR and returns 1.
# The token goes through a curl config file (mktemp makes it mode 600), never argv.
_gitea_api() {
  _am=$1; _ap=$2; _ab=${3:-}
  _acfg=$(mktemp) && _aout=$(mktemp) && _aerr=$(mktemp) || {
    PROVIDER_ERR="could not create a temp file"; return 1; }
  printf 'header = "Authorization: token %s"\n' "$GITEA_TOKEN" > "$_acfg"
  _abase=$(printf '%s' "$GITEA_URL" | sed 's|/*$||')
  if [ -n "$_ab" ]; then
    _acode=$(curl -sS -K "$_acfg" -X "$_am" -H 'Accept: application/json' \
               -H 'Content-Type: application/json' --data-binary "@$_ab" \
               -o "$_aout" -w '%{http_code}' "$_abase/api/v1/$_ap" 2>"$_aerr")
  else
    _acode=$(curl -sS -K "$_acfg" -X "$_am" -H 'Accept: application/json' \
               -o "$_aout" -w '%{http_code}' "$_abase/api/v1/$_ap" 2>"$_aerr")
  fi
  _arc=$?
  rm -f "$_acfg"
  if [ "$_arc" -ne 0 ]; then
    PROVIDER_ERR="curl: $(cat "$_aerr" 2>/dev/null)"
    rm -f "$_aout" "$_aerr"; return 1
  fi
  case "$_acode" in
    2??) PROVIDER_ERR=""; cat "$_aout"; rm -f "$_aout" "$_aerr"; return 0 ;;
  esac
  _amsg=$(jq -r '.message // empty' < "$_aout" 2>/dev/null)
  [ -n "$_amsg" ] || _amsg=$(head -c 500 "$_aout" 2>/dev/null)
  PROVIDER_ERR="HTTP $_acode from $_am /api/v1/$_ap: $_amsg"
  rm -f "$_aout" "$_aerr"
  return 1
}

# _gitea_list <path> <cap> <outfile> [<jq-filter>] -- every page into one array.
# Stops on an empty page, not a short one: the server caps page size at its own
# MAX_RESPONSE_ITEMS, so a short page does not mean the last page.
_gitea_list() {
  _lp=$1; _lcap=$2; _lout=$3; _lf=${4:-.}
  case "$_lp" in *\?*) _ls='&' ;; *) _ls='?' ;; esac
  _lpage=1
  printf '[]' > "$_lout"
  _lpg=$(mktemp) || { PROVIDER_ERR="could not create a temp file"; return 1; }
  while :; do
    _gitea_api GET "$_lp${_ls}limit=50&page=$_lpage" > "$_lpg" || { rm -f "$_lpg"; return 1; }
    _lgot=$(jq 'if type == "array" then length else error("not an array") end' < "$_lpg" 2>/dev/null) || {
      PROVIDER_ERR="$_lp: response is not a JSON array"; rm -f "$_lpg"; return 1; }
    [ "$_lgot" -eq 0 ] && break
    jq -s "(.[0] + [.[1][] | $_lf])" "$_lout" "$_lpg" > "$_lout.n" && mv "$_lout.n" "$_lout" || {
      PROVIDER_ERR="$_lp: could not merge page $_lpage"; rm -f "$_lpg" "$_lout.n"; return 1; }
    [ "$(jq length < "$_lout")" -ge "$_lcap" ] && break
    _lpage=$((_lpage + 1))
  done
  rm -f "$_lpg"
  jq --argjson n "$_lcap" '.[0:$n]' < "$_lout" > "$_lout.n" && mv "$_lout.n" "$_lout"
}

# _gitea_repo [<repo>] -- sets PM_GITEA_REPO to owner/name, from the argument or
# the origin remote (https, scp-style ssh, ssh:// with a port, or a sub-path install).
_gitea_repo() {
  _r=${1:-}
  if [ -z "$_r" ]; then
    _r=$(git remote get-url origin 2>/dev/null \
         | sed -e 's|\.git$||' -e 's|/*$||' -e 's|.*[/:]\([^/:]*/[^/:]*\)$|\1|')
  fi
  case "$_r" in
    */*/*|*:*|/*|*/) ;;
    ?*/?*) PM_GITEA_REPO=$_r; return 0 ;;
  esac
  PROVIDER_ERR="no owner/name repository given, and none could be inferred from the origin remote (got: '$_r')"
  return 1
}

# _gitea_limit <default> -- sets PM_GITEA_LIMIT from PM_LIMIT, a positive integer.
_gitea_limit() {
  PM_GITEA_LIMIT=${PM_LIMIT:-$1}
  case "$PM_GITEA_LIMIT" in
    ''|*[!0-9]*|0) PROVIDER_ERR="PM_LIMIT must be a positive whole number, got: $PM_GITEA_LIMIT"; return 1 ;;
  esac
}

# Gitea stamps times in the server's zone (+02:00); consumers parse only Z.
_GITEA_JQ_DEFS='
def utc:
  if type != "string" then .
  else ((capture("^(?<b>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|(?<s>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2}))$")
         | ((.b + "Z") | fromdateiso8601)
           - (if .z == "Z" then 0
              else (if .s == "-" then -1 else 1 end) * ((.h | tonumber) * 3600 + (.m | tonumber) * 60) end)
         | todateiso8601) // .)
  end;
def st: if . == "open" then "OPEN" elif . == "closed" then "CLOSED" else (. // "" | ascii_upcase) end;
def names: [ (.labels // [])[] | .name ];
def comments: [ .[] | { author: { login: (.user.login // "") }, body: (.body // ""),
                        createdAt: (.created_at | utc), id: .id } ] | sort_by(.createdAt, .id);
'

# _gitea_label_ids <name>... -- sets PM_GITEA_IDS to a JSON array of the label
# ids in PM_GITEA_REPO, then its org's. Ids go as JSON numbers: Gitea reads a
# quoted id as a label NAME and silently drops it.
_gitea_label_ids() {
  PM_GITEA_IDS='[]'
  [ $# -gt 0 ] || return 0
  _gl=$(mktemp) || { PROVIDER_ERR="could not create a temp file"; return 1; }
  _gitea_list "repos/$PM_GITEA_REPO/labels" 100000 "$_gl" || { rm -f "$_gl"; return 1; }
  _gw=$(printf '%s\n' "$@" | jq -R . | jq -cs .)
  _gids=$(jq -c --argjson w "$_gw" '[ $w[] as $n | ([ .[] | select(.name == $n) | .id ][0] // $n) ]' < "$_gl")
  if printf '%s' "$_gids" | jq -e 'any(.[]; type == "string")' >/dev/null; then
    # A user-owned repo answers 404 here.
    if _gitea_list "orgs/${PM_GITEA_REPO%%/*}/labels" 100000 "$_gl"; then
      _gids=$(jq -c --argjson g "$_gids" '. as $o | [ $g[] | if type == "string" then (. as $n | [ $o[] | select(.name == $n) | .id ][0] // $n) else . end ]' < "$_gl")
    else
      case "$PROVIDER_ERR" in "HTTP 404 "*) ;; *) rm -f "$_gl"; return 1 ;; esac
    fi
  fi
  rm -f "$_gl"
  _gmiss=$(printf '%s' "$_gids" | jq -r '[ .[] | strings ] | join(", ")')
  [ -z "$_gmiss" ] || { PROVIDER_ERR="no such label in $PM_GITEA_REPO: $_gmiss"; return 1; }
  PM_GITEA_IDS=$_gids
}

# _gitea_blockers <n> <outfile> -- blocker numbers of n, one per line. Same repo
# only: a cross-repo index would read as a local issue.
_gitea_blockers() {
  _bf=$(mktemp) || { PROVIDER_ERR="could not create a temp file"; return 1; }
  _gitea_list "repos/$PM_GITEA_REPO/issues/$1/dependencies" 100000 "$_bf" || { rm -f "$_bf"; return 1; }
  jq -r --arg r "$PM_GITEA_REPO" '
    .[] | select((.repository.full_name // "" | ascii_downcase) == ($r | ascii_downcase)) | .number' \
    < "$_bf" > "$2"
  _brc=$?
  rm -f "$_bf"
  return $_brc
}

provider_name() { printf 'gitea'; }

# Issues and pull requests share one number namespace.
provider_pr_ref_mark() { printf '#'; }

# Names what is missing on stderr too: callers print only their own line.
provider_available() {
  for _v in GITEA_URL GITEA_TOKEN; do
    eval "_vv=\${$_v:-}"
    [ -n "$_vv" ] || { PROVIDER_ERR="gitea: $_v is not set"; echo "$PROVIDER_ERR" >&2; return 1; }
  done
  for _v in curl jq; do
    command -v "$_v" >/dev/null 2>&1 || {
      PROVIDER_ERR="gitea: $_v is not installed"; echo "$PROVIDER_ERR" >&2; return 1; }
  done
}

# Dependencies are a per-repo switch, on by default: read the repo's own setting.
provider_supports_deps() {
  [ -n "${PM_ASSUME_DEPS:-}" ] && return "${PM_ASSUME_DEPS}"
  _gitea_repo "${1:-}" || return 1
  _sd=$(mktemp) || return 1
  _gitea_api GET "repos/$PM_GITEA_REPO" > "$_sd" || { rm -f "$_sd"; return 1; }
  jq -e '.internal_tracker.enable_issue_dependencies == true' < "$_sd" >/dev/null 2>&1
  _src=$?
  rm -f "$_sd"
  return $_src
}

# provider_issues <repo> -> open issues, normalised.
# blockedBy is read per issue when the repo has dependencies on. Comments are
# read only for needs-human issues, the one place the queue looks at them.
provider_issues() {
  _gitea_repo "${1:-}" || return 1
  _gitea_limit 500 || return 1
  _il=$(mktemp) && _ix=$(mktemp) && _it=$(mktemp) || { PROVIDER_ERR="could not create a temp file"; return 1; }
  _gitea_list "repos/$PM_GITEA_REPO/issues?state=open&type=issues" "$PM_GITEA_LIMIT" "$_il" \
    'select(.pull_request == null)' || { rm -f "$_il" "$_ix" "$_it"; return 1; }
  _deps=0
  provider_supports_deps "$PM_GITEA_REPO" && _deps=1
  for _in in $(jq -r '.[].number' < "$_il"); do
    _ib='[]'
    if [ "$_deps" -eq 1 ]; then
      _gitea_blockers "$_in" "$_it" || { rm -f "$_il" "$_ix" "$_it"; return 1; }
      _ib=$(jq -cs . < "$_it")
    fi
    printf '[]' > "$_it"
    if jq -e --argjson n "$_in" 'any(.[]; .number == $n and any(.labels[]?; .name == "needs-human"))' < "$_il" >/dev/null; then
      _gitea_api GET "repos/$PM_GITEA_REPO/issues/$_in/comments" > "$_it" || { rm -f "$_il" "$_ix" "$_it"; return 1; }
    fi
    jq -c --argjson n "$_in" --argjson b "$_ib" "$_GITEA_JQ_DEFS"'{ n: $n, blockedBy: $b, comments: comments }' \
      < "$_it" >> "$_ix" || {
      PROVIDER_ERR="could not read the comments on #$_in"; rm -f "$_il" "$_ix" "$_it"; return 1; }
  done
  jq --slurpfile x "$_ix" "$_GITEA_JQ_DEFS"'
    ($x | map({ key: (.n | tostring), value: . }) | from_entries) as $m
    | [ .[] | { number, title,
                state: (.state | st),
                labels: names,
                createdAt: (.created_at | utc),
                updatedAt: (.updated_at | utc),
                comments: ($m[.number | tostring].comments // []),
                blockedBy: ($m[.number | tostring].blockedBy // []) } ]' < "$_il"
  _irc=$?
  rm -f "$_il" "$_ix" "$_it"
  return $_irc
}

provider_issue() {
  _n=${1:?}
  _gitea_repo "${2:-}" || return 1
  _io=$(mktemp) || { PROVIDER_ERR="could not create a temp file"; return 1; }
  _gitea_api GET "repos/$PM_GITEA_REPO/issues/$_n" > "$_io" || { rm -f "$_io"; return 1; }
  jq "$_GITEA_JQ_DEFS"'{ number, title, state: (.state | st), labels: names, body: (.body // "") }' < "$_io"
  _iorc=$?
  rm -f "$_io"
  return $_iorc
}

provider_comment() {
  _n=${1:?}; _body=${2:?}
  _gitea_repo "${3:-}" || return 1
  _cb=$(mktemp) || { PROVIDER_ERR="could not create a temp file"; return 1; }
  printf '%s' "$_body" | jq -Rs '{ body: . }' > "$_cb"
  _gitea_api POST "repos/$PM_GITEA_REPO/issues/$_n/comments" "$_cb" > /dev/null
  _crc=$?
  rm -f "$_cb"
  return $_crc
}

# $3 is add|remove. The add checks the label list Gitea returns, because Gitea
# silently skips an id it does not know.
provider_label() {
  _n=${1:?}; _label=${2:?}; _op=${3:?}
  case "$_op" in add|remove) ;; *) return 2 ;; esac
  _gitea_repo "${4:-}" || return 1
  _gitea_label_ids "$_label" || return 1
  if [ "$_op" = remove ]; then
    _gitea_api DELETE "repos/$PM_GITEA_REPO/issues/$_n/labels/$(printf '%s' "$PM_GITEA_IDS" | jq '.[0]')" > /dev/null
    return
  fi
  _lb=$(mktemp) && _lr=$(mktemp) || { PROVIDER_ERR="could not create a temp file"; return 1; }
  jq -n --argjson l "$PM_GITEA_IDS" '{ labels: $l }' > "$_lb"
  _gitea_api POST "repos/$PM_GITEA_REPO/issues/$_n/labels" "$_lb" > "$_lr" || { rm -f "$_lb" "$_lr"; return 1; }
  jq -e --arg l "$_label" 'any(.[]; .name == $l)' < "$_lr" >/dev/null 2>&1
  _lrc=$?
  rm -f "$_lb" "$_lr"
  [ "$_lrc" -eq 0 ] || { PROVIDER_ERR="label '$_label' was not on #$_n after adding it"; return 1; }
}

provider_issue_labels() {
  _n=${1:?}
  _gitea_repo "${2:-}" || return 1
  _ll=$(mktemp) || { PROVIDER_ERR="could not create a temp file"; return 1; }
  _gitea_api GET "repos/$PM_GITEA_REPO/issues/$_n/labels" > "$_ll" || { rm -f "$_ll"; return 1; }
  jq -r '.[].name' < "$_ll"
  _llrc=$?
  rm -f "$_ll"
  return $_llrc
}

# Gitea has no close reasons.
provider_close_issue() {
  _n=${1:?}
  PROVIDER_CLOSE_REASON_APPLIED=0
  _gitea_repo "${3:-}" || return 1
  _xb=$(mktemp) && _xr=$(mktemp) || { PROVIDER_ERR="could not create a temp file"; return 1; }
  printf '{"state":"closed"}' > "$_xb"
  _gitea_api PATCH "repos/$PM_GITEA_REPO/issues/$_n" "$_xb" > "$_xr" || { rm -f "$_xb" "$_xr"; return 1; }
  jq -e '.state == "closed"' < "$_xr" >/dev/null 2>&1
  _xrc=$?
  rm -f "$_xb" "$_xr"
  [ "$_xrc" -eq 0 ] || { PROVIDER_ERR="#$_n is not closed after closing it"; return 1; }
}

# Best-effort, always 0. Gitea allows duplicate label names, so look before creating.
provider_ensure_label() {
  _label=${1:?}
  _gitea_repo "${2:-}" || return 0
  _gitea_label_ids "$_label" 2>/dev/null && return 0
  _eb=$(mktemp) || return 0
  jq -n --arg n "$_label" '{ name: $n, color: "#ededed" }' > "$_eb"
  _gitea_api POST "repos/$PM_GITEA_REPO/labels" "$_eb" >/dev/null 2>&1 || :
  rm -f "$_eb"
  return 0
}

# provider_create_issue <repo> <title> [label ...] -> URL; body on stdin.
provider_create_issue() {
  _repo=${1:-}; _title=${2:?}; shift 2
  _gitea_repo "$_repo" || return 1
  _gitea_label_ids "$@" || return 1
  _nb=$(mktemp) && _nr=$(mktemp) || { PROVIDER_ERR="could not create a temp file"; return 1; }
  jq -Rs --arg t "$_title" --argjson l "$PM_GITEA_IDS" '{ title: $t, body: ., labels: $l }' > "$_nb"
  _gitea_api POST "repos/$PM_GITEA_REPO/issues" "$_nb" > "$_nr" || { rm -f "$_nb" "$_nr"; return 1; }
  jq -r '.html_url' < "$_nr"
  _nrc=$?
  rm -f "$_nb" "$_nr"
  return $_nrc
}

# No draft flag in Gitea: a WIP: title prefix is what makes the API report draft.
provider_open_draft_pr() {
  _branch=${1:?}; _title=${2:?}; _body=${3:?}; _base=${4:?}
  _gitea_repo "${5:-}" || return 1
  case "$(printf '%s' "$_title" | tr '[:lower:]' '[:upper:]')" in
    'WIP:'*|'[WIP]'*) ;;
    *) _title="WIP: $_title" ;;
  esac
  _pb=$(mktemp) && _pr=$(mktemp) || { PROVIDER_ERR="could not create a temp file"; return 1; }
  printf '%s' "$_body" | jq -Rs --arg h "$_branch" --arg b "$_base" --arg t "$_title" \
    '{ head: $h, base: $b, title: $t, body: . }' > "$_pb"
  _gitea_api POST "repos/$PM_GITEA_REPO/pulls" "$_pb" > "$_pr" || { rm -f "$_pb" "$_pr"; return 1; }
  jq -r '.html_url' < "$_pr"
  _prc=$?
  rm -f "$_pb" "$_pr"
  return $_prc
}

# Empty output: no open PR from that branch of this repo. Non-zero: could not ask.
provider_find_pr() {
  _branch=${1:?}
  _gitea_repo "${2:-}" || return 1
  _fp=$(mktemp) || { PROVIDER_ERR="could not create a temp file"; return 1; }
  _gitea_list "repos/$PM_GITEA_REPO/pulls?state=open" 100000 "$_fp" || { rm -f "$_fp"; return 1; }
  jq -r --arg b "$_branch" --arg r "$PM_GITEA_REPO" '
    [ .[] | select(.head.ref == $b
                   and ((.head.repo.full_name // "") | ascii_downcase) == ($r | ascii_downcase)) ]
    | .[0].number // empty' < "$_fp"
  _frc=$?
  rm -f "$_fp"
  return $_frc
}

# provider_pr_activity <branch> [repo] -> "<draft>\t<updatedAt>" for the open PR
# from that branch of this repo, or nothing. Non-zero: could not ask.
provider_pr_activity() {
  _branch=${1:?}
  _gitea_repo "${2:-}" || return 1
  _pa=$(mktemp) || { PROVIDER_ERR="could not create a temp file"; return 1; }
  _gitea_list "repos/$PM_GITEA_REPO/pulls?state=open" 100000 "$_pa" || { rm -f "$_pa"; return 1; }
  jq -r --arg b "$_branch" --arg r "$PM_GITEA_REPO" "$_GITEA_JQ_DEFS"'
    [ .[] | select(.head.ref == $b
                   and ((.head.repo.full_name // "") | ascii_downcase) == ($r | ascii_downcase)) ]
    | .[0] // empty | "\(.draft // false)\t\(.updated_at | utc)"' < "$_pa"
  _parc=$?
  rm -f "$_pa"
  return $_parc
}

# provider_needs_human <repo> -> [{number, title, comments oldest first}].
# Filtered here as well as in the query: Gitea drops an unknown label name from
# the filter and then returns every open issue.
provider_needs_human() {
  _gitea_repo "${1:-}" || return 2
  _gitea_limit 100 || return 2
  _hl=$(mktemp) && _hx=$(mktemp) && _hc=$(mktemp) || { PROVIDER_ERR="could not create a temp file"; return 2; }
  _gitea_list "repos/$PM_GITEA_REPO/issues?state=open&type=issues&labels=needs-human" "$PM_GITEA_LIMIT" "$_hl" \
    'select(.pull_request == null and any(.labels[]?; .name == "needs-human"))' || {
    rm -f "$_hl" "$_hx" "$_hc"; return 2; }
  for _hn in $(jq -r '[.[].number] | unique | .[]' < "$_hl"); do
    _gitea_api GET "repos/$PM_GITEA_REPO/issues/$_hn/comments" > "$_hc" || { rm -f "$_hl" "$_hx" "$_hc"; return 2; }
    jq -c --argjson n "$_hn" --slurpfile c "$_hc" "$_GITEA_JQ_DEFS"'
      first(.[] | select(.number == $n))
      | { number, title: (.title // ""), comments: ($c[0] | comments) }' < "$_hl" >> "$_hx" || {
      PROVIDER_ERR="could not read the comments on #$_hn"; rm -f "$_hl" "$_hx" "$_hc"; return 2; }
  done
  jq -s . < "$_hx"
  _hrc=$?
  rm -f "$_hl" "$_hx" "$_hc"
  [ "$_hrc" -eq 0 ] || return 2
}

# The dependency body takes the issue index, so the "id" is the number, looked
# up so that a missing issue fails here rather than in the link.
provider_issue_id() {
  _n=${1:?}
  _gitea_repo "${2:-}" || return 1
  _ii=$(mktemp) || { PROVIDER_ERR="could not create a temp file"; return 1; }
  _gitea_api GET "repos/$PM_GITEA_REPO/issues/$_n" > "$_ii" || { rm -f "$_ii"; return 1; }
  jq -r '.number // empty' < "$_ii"
  _iirc=$?
  rm -f "$_ii"
  return $_iirc
}

# GET /issues/{n}/dependencies lists the issues that block n.
provider_blocked_by() {
  _n=${1:?}
  _gitea_repo "${2:-}" || return 1
  _bb=$(mktemp) || { PROVIDER_ERR="could not create a temp file"; return 1; }
  _gitea_blockers "$_n" "$_bb" || { rm -f "$_bb"; return 1; }
  cat "$_bb"
  rm -f "$_bb"
}

# _gitea_edge <POST|DELETE> <n> <blocker> -- write the edge, then read it back
# rather than trusting the response. The body names the blocker's repo: Gitea
# reads an IssueMeta without owner/repo as a cross-repo reference.
_gitea_edge() {
  case "$3" in ''|*[!0-9]*) PROVIDER_ERR="blocker must be an issue number, got: $3"; return 1 ;; esac
  _db=$(mktemp) && _dk=$(mktemp) || { PROVIDER_ERR="could not create a temp file"; return 1; }
  jq -n --argjson i "$3" --arg o "${PM_GITEA_REPO%%/*}" --arg r "${PM_GITEA_REPO#*/}" \
    '{ index: $i, owner: $o, repo: $r }' > "$_db"
  _gitea_api "$1" "repos/$PM_GITEA_REPO/issues/$2/dependencies" "$_db" > /dev/null \
    && _gitea_blockers "$2" "$_dk" || { rm -f "$_db" "$_dk"; return 1; }
  grep -qx "$3" "$_dk"
  _dfound=$?
  rm -f "$_db" "$_dk"
  case "$1:$_dfound" in
    POST:0|DELETE:1) return 0 ;;
    POST:*) PROVIDER_ERR="#$2 is not blocked by #$3 after linking" ;;
    *) PROVIDER_ERR="#$2 is still blocked by #$3 after unlinking" ;;
  esac
  return 1
}

provider_link() {
  _gitea_repo "${3:-}" || return 1
  _gitea_edge POST "${1:?}" "${2:?}"
}

provider_unlink() {
  _gitea_repo "${3:-}" || return 1
  _gitea_edge DELETE "${1:?}" "${2:?}"
}

# Ordering axes are labels here, as on GitHub. 0 triaged, 1 not, 2 cannot tell.
provider_is_triaged() {
  _issue=${1:?}
  printf '%s' "$_issue" | jq -e '
    [ .labels[]? | (if type == "object" then .name else . end) | strings ] as $l
    | ($l | any(startswith("priority-")))
      and ($l | any(startswith("urgency-")))
      and ($l | any(startswith("size-")))
  ' >/dev/null 2>&1 && return 0
  case $? in 1) return 1 ;; *) return 2 ;; esac
}
