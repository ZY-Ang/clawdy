# The GitLab provider -- the second backend behind the seam.
#
# The read half, the issue and MR writes, and the authenticated remainder --
# the needs-human notes and the issue-link graph. The last two need a token:
# both endpoints 401 anonymously, even on a public project.
#
# Everything here talks to GitLab through the public `glab` CLI and nothing
# else, for the same reason the github provider talks through `gh`: the
# wrapper's error messages and auth are not ours to reimplement, and a
# PROVIDER_ERR full of the backend's own words is what makes a failure
# debuggable.
#
# The host is glab's own choice -- its config file or GITLAB_HOST. The
# provider never pins one, because a provider that silently redirects requests
# to the wrong instance fails quietly, and a provider that stays out of it
# fails loudly on the one instance the user actually configured.

PROVIDER_ERR=""

# _glab_read <args...> -- run glab, stdout passes through, stderr into PROVIDER_ERR.
_glab_read() {
  _pe=${TMPDIR:-/tmp}/pm-provider.$$.err
  glab "$@" 2>"$_pe"
  _prc=$?
  PROVIDER_ERR=$(cat "$_pe" 2>/dev/null || :)
  rm -f "$_pe" 2>/dev/null || :
  return $_prc
}

# _glab_write <args...> -- run glab, discard stdout, keep stderr in PROVIDER_ERR.
_glab_write() {
  PROVIDER_ERR=$(glab "$@" 2>&1 >/dev/null)
}

# _glab_project [<repo>] -- the project path, url-encoded for `glab api`.
#
# The subcommands take -R owner/project; the REST path needs owner%2Fproject,
# and a subgroup path has more than one slash to encode. With no repo given,
# glab is asked what the working directory maps to rather than guessing from
# the git remote, so the answer matches whatever host it is configured for.
_glab_project() {
  _r=${1:-}
  if [ -z "$_r" ]; then
    _r=$(glab repo view -F json 2>/dev/null \
         | jq -r '.path_with_namespace // .full_name // empty' 2>/dev/null)
  fi
  [ -n "$_r" ] || {
    PROVIDER_ERR="no project given, and none could be inferred from the working directory"
    return 1; }
  printf '%s' "$_r" | sed 's|/|%2F|g'
}

provider_name() { printf 'gitlab'; }

# The markdown glyph that references a code-review item on this backend.
# GitLab has two namespaces: an MR is !n; #n would read as an issue.
provider_pr_ref_mark() { printf '!'; }

provider_available() { command -v glab >/dev/null 2>&1; }

# provider_issues <repo> -> open issues, normalised, as a JSON array.
#
# glab's list output carries no comments and no issue links. Both come back as
# empty arrays, which the contract allows and demands: "anything you cannot
# supply is an empty array, never absent". The notes behind user_notes_count
# are a per-issue call; a queue listing cannot afford one call per row, and
# the comments consumer that matters -- check-replies -- goes through
# provider_needs_human, which does make that call.
provider_issues() {
  _repo=${1:-}
  # glab does not auto-paginate: the default call returns page one -- thirty
  # rows, silently, whatever the backlog holds. Pages of 100 (the API's
  # maximum) are fetched until PM_LIMIT or a short page says stop.
  _limit=${PM_LIMIT:-500}
  _page=1
  _all=${TMPDIR:-/tmp}/pm-gitlab.$$.all
  _tmp=${TMPDIR:-/tmp}/pm-gitlab.$$.json
  jq -n '[]' > "$_all"
  while :; do
    _glab_read issue list ${_repo:+-R "$_repo"} --output json --page "$_page" --per-page 100 > "$_tmp"
    _rc=$?
    [ "$_rc" -eq 0 ] || { rm -f "$_tmp" "$_all" 2>/dev/null; return "$_rc"; }
    jq -s '.[0] + .[1]' "$_all" "$_tmp" > "$_all.next" && mv "$_all.next" "$_all"
    _this=$(jq 'length' "$_tmp")
    _got=$(jq 'length' "$_all")
    [ "$_this" -lt 100 ] && break
    [ "$_got" -ge "$_limit" ] && break
    _page=$((_page + 1))
  done
  jq -r --argjson limit "$_limit" '
    [ limit($limit; .[]) | { number: .iid,
              title,
              state: (if .state == "opened" then "OPEN"
                      elif .state == "closed" then "CLOSED"
                      else (.state // "" | ascii_upcase) end),
              labels: (.labels // []),
              createdAt: .created_at,
              updatedAt: .updated_at,
              comments: [],
              blockedBy: [] } ]' < "$_all"
  _rc=$?
  rm -f "$_tmp" "$_all" 2>/dev/null
  return "$_rc"
}

# provider_issue <n> <repo> -> one issue, normalised, as JSON.
#
# Same shape the github provider returns for the same call, so backlog-claim
# and backlog-release read .title/.state/.labels unchanged. GitLab names the
# body "description"; the contract names it "body".
provider_issue() {
  _n=${1:?}; _repo=${2:-}
  _tmp=${TMPDIR:-/tmp}/pm-gitlab.$$.json
  _glab_read issue view "$_n" ${_repo:+-R "$_repo"} --output json > "$_tmp"
  _rc=$?
  [ "$_rc" -eq 0 ] || { rm -f "$_tmp" 2>/dev/null; return "$_rc"; }
  jq -r '
    { number: .iid,
      title,
      state: (if .state == "opened" then "OPEN"
              elif .state == "closed" then "CLOSED"
              else (.state // "" | ascii_upcase) end),
      labels: (.labels // []),
      body: (.description // "") }' < "$_tmp"
  _rc=$?
  rm -f "$_tmp" 2>/dev/null
  return "$_rc"
}

# --- the write half ----------------------------------------------------------
#
# Same contract style as the github provider's: each of these WRITES, so each
# reports failure rather than returning something a caller could mistake for
# success. The link graph and needs-human notes are the authenticated
# remainder (issue #18) -- both endpoints 401 without a token, so their wire
# fixtures cannot exist yet and neither can they.
#
# glab takes bodies as ARGUMENTS (-m, -d), not stdin. argv is megabytes; an
# issue body fits, and glab has no --body-file, so the string goes through.

# provider_comment <n> <body> <repo> -- post a comment (already marked by the caller)
provider_comment() {
  _n=${1:?}; _body=${2:?}; _repo=${3:-}
  # shellcheck disable=SC2086
  _glab_write issue note "$_n" -m "$_body" ${_repo:+-R "$_repo"}
}

# $3 is add|remove.
provider_label() {
  _n=${1:?}; _label=${2:?}; _op=${3:?}; _repo=${4:-}
  case "$_op" in
    add)    # shellcheck disable=SC2086
            _glab_write issue update "$_n" -l "$_label" ${_repo:+-R "$_repo"} ;;
    remove) # shellcheck disable=SC2086
            _glab_write issue update "$_n" -u "$_label" ${_repo:+-R "$_repo"} ;;
    *) return 2 ;;
  esac
}

# $2 is the backend reason where it has one. GitLab has none, so the argument
# is part of the contract rather than of the call.
provider_close_issue() {
  _n=${1:?}; _reason=${2:-}; _repo=${3:-}
  # shellcheck disable=SC2086
  _glab_write issue close "$_n" ${_repo:+-R "$_repo"}
}

# Best-effort by design, same as github's: a label that already exists is not
# an error, and a backend with no label concept should return 0.
provider_ensure_label() {
  _label=${1:?}; _repo=${2:-}
  # shellcheck disable=SC2086
  glab label create -n "$_label" ${_repo:+-R "$_repo"} >/dev/null 2>&1 || true
  return 0
}

# provider_create_issue <repo> <title> [label ...] -> URL on stdout
#
# The body arrives on stdin, as the contract says. Text output, not
# --output json: glab prints the URL in text mode, and passing it through
# keeps a field mapping out of this file. --yes skips the confirmation
# prompt, which would otherwise hang a non-interactive run.
#
# Known limit: on a TTY glab prints "!77 Title" above the URL; callers that
# capture this into a variable should not run under one. The unattended loop
# never has a TTY.
provider_create_issue() {
  _repo=${1:-}; _title=${2:?}; shift 2
  _body=$(cat)
  # Rebuild the argument list rather than iterating it in place, same as the
  # github provider: "$@" is both the list being read and the command being
  # built.
  set -- $(for _l in "$@"; do printf -- '--label\n%s\n' "$_l"; done)
  # shellcheck disable=SC2086
  _glab_read issue create -t "$_title" -d "$_body" -y "$@" ${_repo:+-R "$_repo"}
}

provider_issue_labels() {
  _n=${1:?}; _repo=${2:-}
  _tmp=${TMPDIR:-/tmp}/pm-gitlab.$$.json
  _glab_read issue view "$_n" ${_repo:+-R "$_repo"} --output json > "$_tmp"
  _rc=$?
  [ "$_rc" -eq 0 ] || { rm -f "$_tmp" 2>/dev/null; return "$_rc"; }
  jq -r '.labels[]?' < "$_tmp"
  _rc=$?
  rm -f "$_tmp" 2>/dev/null
  return "$_rc"
}

# provider_open_draft_pr <branch> <title> <body> <base> <repo> -> URL on stdout
#
# Text output again: glab mr create prints the MR URL, and nothing here should
# reimplement printing it. --draft, and --yes against the confirm prompt.
provider_open_draft_pr() {
  _branch=${1:?}; _title=${2:?}; _body=${3:?}; _base=${4:?}; _repo=${5:-}
  # shellcheck disable=SC2086
  _glab_read mr create -s "$_branch" -b "$_base" -t "$_title" -d "$_body" \
     --draft -y ${_repo:+-R "$_repo"}
}

# Empty output means "no open MR for that branch", which is different from
# "could not ask" -- that is a non-zero return.
provider_find_pr() {
  _branch=${1:?}; _repo=${2:-}
  _tmp=${TMPDIR:-/tmp}/pm-gitlab.$$.json
  _glab_read mr list -s "$_branch" -F json ${_repo:+-R "$_repo"} --per-page 100 > "$_tmp"
  _rc=$?
  [ "$_rc" -eq 0 ] || { rm -f "$_tmp" 2>/dev/null; return "$_rc"; }
  jq -r '.[0].iid // empty' < "$_tmp" 2>/dev/null
  _rc=$?
  rm -f "$_tmp" 2>/dev/null
  return "$_rc"
}

# provider_needs_human <repo> -> open issues awaiting a person, as JSON.
#
# The notes endpoint 401s anonymously even on a public project, where list and
# view do not. That is not the barrier it looks like: every write in this file
# already needs a token, so any working install has one. An anonymous glab gets
# an honest 2 -- "could not ask" -- and never a pretend-empty answer.
#
# TWO CALLS PER ISSUE IS THE POINT. glab's list carries user_notes_count but no
# note bodies, and the whole question here is who spoke last. The blocked subset
# is small by construction; the backlog listing, which is not, stays in
# provider_issues without comments.
#
# SYSTEM NOTES MUST GO. GitLab records "changed title from", "marked as related
# to", "assigned to" as notes in the same stream as human comments, flagged
# system:true. check-replies reads the LAST comment and asks whether it carries
# the agent mark -- so a system note landing after an agent's reply reads as a
# human answering, and the question is reported ANSWERED while it is still
# blocked on a person. Retitling one scratch issue produced exactly that.
#
# The author key is `username`; the contract's consumer reads `.author.login`.
provider_needs_human() {
  _repo=${1:-}
  _tmp=${TMPDIR:-/tmp}/pm-gitlab.$$.nh
  _proj=$(_glab_project "$_repo") || return 2
  _glab_read api "projects/$_proj/issues?labels=needs-human&state=opened&per_page=${PM_LIMIT:-100}" \
    > "$_tmp"
  _rc=$?
  [ "$_rc" -eq 0 ] || { rm -f "$_tmp" 2>/dev/null; return "$_rc"; }

  _ids=${TMPDIR:-/tmp}/pm-gitlab.$$.iids
  jq -r '.[].iid' < "$_tmp" > "$_ids" 2>/dev/null || {
    rm -f "$_tmp" "$_ids" 2>/dev/null; return 2; }

  _out=${TMPDIR:-/tmp}/pm-gitlab.$$.nhout
  jq -n '[]' > "$_out"
  # Read rather than `for _iid in $(...)`: an unquoted expansion splits on the
  # shell's IFS, which is not newline everywhere, and glob-expands besides.
  while IFS= read -r _iid; do
    [ -n "$_iid" ] || continue
    _notes=${TMPDIR:-/tmp}/pm-gitlab.$$.notes
    _glab_read api "projects/$_proj/issues/$_iid/notes?per_page=100" > "$_notes" || {
      rm -f "$_tmp" "$_out" "$_ids" "$_notes" 2>/dev/null; return 2; }
    jq --slurpfile notes "$_notes" --argjson iid "$_iid" --slurpfile issues "$_tmp" '
      . + [ ($issues[0][] | select(.iid == $iid)) as $i
          | { number: $i.iid,
              title: ($i.title // ""),
              comments: [ $notes[0][]
                          | select((.system // false) | not)
                          | { author: { login: (.author.username // "") },
                              body: (.body // ""),
                              createdAt: .created_at } ]
                        | sort_by(.createdAt) } ]' < "$_out" > "$_out.n" 2>/dev/null || {
      rm -f "$_tmp" "$_out" "$_out.n" "$_ids" "$_notes" 2>/dev/null; return 2; }
    mv "$_out.n" "$_out"
    rm -f "$_notes" 2>/dev/null
  done < "$_ids"
  cat "$_out"
  rm -f "$_tmp" "$_out" "$_ids" 2>/dev/null
}

# --- the dependency graph ----------------------------------------------------
#
# GitLab calls these issue LINKS, and the blocking ones are a paid capability.
# Measured on gitlab.com free, against a real project:
#
#   POST .../links link_type=is_blocked_by  -> 403 Blocked issues not available
#   POST .../links link_type=blocks         -> 403, the same
#   POST .../links link_type=relates_to     -> 201, a symmetric "related" edge
#
# So on a licence without them there is no blocking graph at all, while on
# Premium and on the Enterprise instances people actually run at work, there is.
# The provider must therefore neither assume nor hardcode either answer.
#
# RELATES_TO IS NOT A SUBSTITUTE. It is symmetric and carries no direction, so
# recording a blocker as "related" would let the queue read a bidirectional edge
# as an ordering constraint and produce a confidently wrong order. Better to
# have no dependency graph than a graph that lies about direction.

# The links endpoint takes and returns the ISSUE IID, not the global id, so the
# contract's "the backend's own id" is the number the caller already has. It
# stays a real lookup rather than an echo, because it must fail when the issue
# does not exist -- backlog-link treats an empty id as fatal, which is how a
# typo gets caught before a link is written.
provider_issue_id() {
  _n=${1:?}; _repo=${2:-}
  _proj=$(_glab_project "$_repo") || return 1
  _tmp=${TMPDIR:-/tmp}/pm-gitlab.$$.id
  _glab_read api "projects/$_proj/issues/$_n" > "$_tmp"
  _rc=$?
  [ "$_rc" -eq 0 ] || { rm -f "$_tmp" 2>/dev/null; return "$_rc"; }
  jq -r '.iid // empty' < "$_tmp"
  _rc=$?
  rm -f "$_tmp" 2>/dev/null
  return $_rc
}

# Only is_blocked_by is a blocker. relates_to and blocks are different claims,
# and counting either would invent an ordering constraint nobody recorded.
provider_blocked_by() {
  _n=${1:?}; _repo=${2:-}
  _proj=$(_glab_project "$_repo") || return 1
  _tmp=${TMPDIR:-/tmp}/pm-gitlab.$$.links
  _glab_read api "projects/$_proj/issues/$_n/links" > "$_tmp"
  _rc=$?
  [ "$_rc" -eq 0 ] || { rm -f "$_tmp" 2>/dev/null; return "$_rc"; }
  jq -r '.[] | select(.link_type == "is_blocked_by") | .iid' < "$_tmp"
  _rc=$?
  rm -f "$_tmp" 2>/dev/null
  return $_rc
}

# On a licence without blocking links this fails with GitLab's own words --
# "Blocked issues not available for current license" -- which PROVIDER_ERR
# carries to the caller. That is the right failure: loud, specific, and not
# quietly downgraded to a relates_to edge that would misreport direction.
provider_link() {
  _n=${1:?}; _blocker=${2:?}; _repo=${3:-}
  _proj=$(_glab_project "$_repo") || return 1
  _target=$(printf '%s' "$_proj" | sed 's|%2F|/|g')
  _glab_write api --method POST "projects/$_proj/issues/$_n/links" \
     -f target_project_id="$_target" -f target_issue_iid="$_blocker" \
     -f link_type=is_blocked_by
  [ -z "$PROVIDER_ERR" ]
}

# DELETE takes the LINK's own id, not either issue's -- so the edge has to be
# looked up first. Passing an issue number here deletes nothing and reports
# success on some paths, which is why this is not left to the caller.
provider_unlink() {
  _n=${1:?}; _blocker=${2:?}; _repo=${3:-}
  _proj=$(_glab_project "$_repo") || return 1
  _tmp=${TMPDIR:-/tmp}/pm-gitlab.$$.unlink
  _glab_read api "projects/$_proj/issues/$_n/links" > "$_tmp" || {
    rm -f "$_tmp" 2>/dev/null; return 1; }
  _lid=$(jq -r --argjson b "$_blocker" '
    .[] | select(.iid == $b and .link_type == "is_blocked_by") | .issue_link_id' \
    < "$_tmp" 2>/dev/null | head -1)
  rm -f "$_tmp" 2>/dev/null
  [ -n "$_lid" ] || { PROVIDER_ERR="no is_blocked_by link from #$_n to #$_blocker"; return 1; }
  _glab_write api --method DELETE "projects/$_proj/issues/$_n/links/$_lid"
  [ -z "$PROVIDER_ERR" ]
}

# Probe, do not assume. The links endpoint is readable on every licence, so a
# successful read means the graph can be QUERIED -- and where blocking links
# cannot be created, blocked_by correctly returns nothing, because there are
# none. An unreachable or unauthenticated backend degrades to "no dependency
# graph" rather than failing the whole ordering, per the contract.
#
# PM_ASSUME_DEPS overrides, same as the github provider, for the case where the
# probe costs a call nobody wants to spend.
provider_supports_deps() {
  [ -n "${PM_ASSUME_DEPS:-}" ] && return "${PM_ASSUME_DEPS}"
  _proj=$(_glab_project "${1:-}") || return 1
  _glab_read api "projects/$_proj/issues?per_page=1" >/dev/null 2>&1
}
