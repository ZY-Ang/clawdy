# The GitLab provider -- the second backend behind the seam.
#
# The read half (#14) plus the issue and MR writes (#17). The authenticated
# remainder -- the issue-link graph and the needs-human notes -- waits on a
# token (#18); both endpoints 401 anonymously.
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

# provider_needs_human <repo> -> the authenticated remainder (issue #18).
#
# Reading notes takes the notes endpoint, which requires an authenticated
# read token even on public projects -- the list and view calls above work
# without one, this one 401s. Until a token and a wire fixture exist,
# check-replies gets an honest "cannot tell" rather than a pretend-empty
# answer.
provider_needs_human() {
  echo "pm: gitlab provider: needs-human listing is not implemented yet (issue #18)" >&2
  return 2
}
