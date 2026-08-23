# The GitLab provider -- the second backend behind the seam.
#
# Read half, per #14: provider_name, provider_available, provider_issues,
# provider_issue. Writes arrive with #13.
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

provider_name() { printf 'gitlab'; }

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

# provider_needs_human <repo> -> not in the read half.
#
# Reading notes takes `glab api` against the notes endpoint, which requires an
# authenticated read token even on public projects -- the list and view calls
# above work without one, this one 401s. It lands with the write half and a
# wire fixture for the notes shape; until then check-replies gets an honest
# "cannot tell" rather than a pretend-empty answer.
provider_needs_human() {
  echo "pm: gitlab provider: needs-human listing is not implemented yet (write half)" >&2
  return 2
}
