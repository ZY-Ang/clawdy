# The GitHub provider. One of these per backend.
#
# Everything above this line in the call stack works on a normalised shape, so
# an adapter for another backend is a new file implementing the same functions
# rather than a rewrite.
#
# The plugin is `pm`, not `gh-pm`, deliberately: a backend in the name is the one
# part guaranteed to be wrong the day a second backend exists, and renaming a
# published plugin costs every user a reinstall. Nothing above this file knows
# which tracker it is talking to.
#
# The contract, in full:
#
#   provider_name              a word, for messages
#   provider_available         0 if this backend can be reached right now
#   provider_issues            normalised open issues, as a JSON array, on stdout
#   provider_supports_deps     0 if the backend exposes an issue dependency graph
#
# Normalised issue:
#   { number, title, state, labels: [string], createdAt, updatedAt,
#     comments: [{author, body}], blockedBy: [number] }
#
# Anything a backend cannot supply comes back as an empty array, never absent --
# a consumer that has to test for missing keys grows a branch per backend, which
# is the coupling this seam exists to prevent.

# --- what the backend actually said -----------------------------------------
#
# Every write below used to end `>/dev/null 2>&1`. That made three different
# failures print the same sentence, and each one cost real time to rediscover:
#
#   jq parse error hidden behind "could not parse the issue list"      (#33)
#   a rate limit hidden behind "could not list issues"                 (#45)
#   HTTP 422 hidden behind "could not link"                            (#45)
#
# The 422 in particular named the property, the value received, its actual
# type, the required type, and the endpoint documentation. All of it discarded
# and replaced with four words.
#
# PROVIDER_ERR holds the backend's own diagnostic after a failed call, for the
# caller to print under its friendly line. A wrapper that hides the underlying
# tool makes every failure look identical, which is the opposite of what a
# wrapper is for.
PROVIDER_ERR=""

# _gh_write <args...> -- run gh, discard stdout, keep stderr in PROVIDER_ERR.
_gh_write() {
  PROVIDER_ERR=$(gh "$@" 2>&1 >/dev/null)
}

# _gh_read <args...> -- run gh, stdout passes through, stderr into PROVIDER_ERR.
# Needs a temp file: stdout is the payload here, so the 2>&1 >/dev/null trick
# used above is not available.
_gh_read() {
  _pe=${TMPDIR:-/tmp}/pm-provider.$$.err
  gh "$@" 2>"$_pe"
  _prc=$?
  PROVIDER_ERR=$(cat "$_pe" 2>/dev/null || :)
  rm -f "$_pe" 2>/dev/null || :
  return $_prc
}

provider_name() { printf 'github'; }

# The markdown glyph that references a code-review item on this backend.
# GitHub has one namespace: a PR is #n, like an issue.
provider_pr_ref_mark() { printf '#'; }

provider_available() { command -v gh >/dev/null 2>&1; }

# GitHub exposes blockedBy/blocking only where the instance supports issue
# relationships -- gh adds those fields conditionally. Older GHES will not, and
# the ordering has to degrade to "no dependencies known" rather than fail.
provider_supports_deps() {
  [ -n "${PM_ASSUME_DEPS:-}" ] && return "${PM_ASSUME_DEPS}"
  gh issue list --limit 1 --json number,blockedBy >/dev/null 2>&1
}

provider_issues() {
  _repo=${1:-}
  _fields=number,title,state,labels,createdAt,updatedAt,comments

  # blockedBy only where the instance supports issue relationships. Asking for
  # it elsewhere fails the whole call, so try once and fall back rather than
  # letting one unsupported field cost the entire queue.
  if provider_supports_deps; then
    # shellcheck disable=SC2086
    gh issue list --state open --limit "${PM_LIMIT:-500}" \
       ${_repo:+--repo "$_repo"} --json "$_fields",blockedBy 2>/dev/null && return 0
  fi
  # shellcheck disable=SC2086
  gh issue list --state open --limit "${PM_LIMIT:-500}" \
     ${_repo:+--repo "$_repo"} --json "$_fields" 2>/dev/null
}

# --- the claim half ----------------------------------------------------------
#
# Four more functions, same contract style. These WRITE, so each one reports
# failure rather than returning something a caller could mistake for success.
#
#   provider_issue         one issue as JSON, by number
#   provider_comment       post a comment (already marked by the caller)
#   provider_label         add or remove one label
#   provider_open_draft_pr open a draft pull request for a branch
#   provider_find_pr       the open PR number for a branch, empty if none

provider_issue() {
  _n=${1:?}; _repo=${2:-}
  # shellcheck disable=SC2086
  gh issue view "$_n" ${_repo:+--repo "$_repo"} \
     --json number,title,state,labels,body 2>/dev/null
}

provider_comment() {
  _n=${1:?}; _body=${2:?}; _repo=${3:-}
  # shellcheck disable=SC2086
  printf '%s' "$_body" | _gh_write issue comment "$_n" ${_repo:+--repo "$_repo"} --body-file -
}

# $3 is add|remove. Label creation is left to the caller: a claim is not the
# right moment to invent taxonomy.
provider_label() {
  _n=${1:?}; _label=${2:?}; _op=${3:?}; _repo=${4:-}
  case "$_op" in
    add)    # shellcheck disable=SC2086
            _gh_write issue edit "$_n" ${_repo:+--repo "$_repo"} --add-label "$_label" ;;
    remove) # shellcheck disable=SC2086
            _gh_write issue edit "$_n" ${_repo:+--repo "$_repo"} --remove-label "$_label" ;;
    *) return 2 ;;
  esac
}

provider_open_draft_pr() {
  _branch=${1:?}; _title=${2:?}; _body=${3:?}; _base=${4:?}; _repo=${5:-}
  # shellcheck disable=SC2086
  printf '%s' "$_body" | _gh_read pr create --draft --head "$_branch" --base "$_base" \
     --title "$_title" --body-file - ${_repo:+--repo "$_repo"}
}

# Empty output means "no open pull request for that branch", which is different
# from "could not ask" -- that is a non-zero return.
provider_find_pr() {
  _branch=${1:?}; _repo=${2:-}
  # shellcheck disable=SC2086
  gh pr list --head "$_branch" --state open --json number \
     ${_repo:+--repo "$_repo"} 2>/dev/null | jq -r '.[0].number // empty' 2>/dev/null
}

# --- the dependency graph, written ------------------------------------------
#
#   provider_issue_id      the NUMERIC id behind an issue number
#   provider_blocked_by    current blockers of an issue, as numbers
#   provider_link          add a blocked-by edge
#   provider_unlink        remove one
#
# The id is not the number. GitHub takes the issue NUMBER in the URL and the
# numeric ID in the body, and passing the number in both places fails with a
# message that names neither -- so the lookup is a separate function rather
# than something each caller improvises.

provider_issue_id() {
  _n=${1:?}; _repo=${2:-}
  _r=${_repo:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)}
  [ -n "$_r" ] || return 1
  _gh_read api "repos/$_r/issues/$_n" --jq .id
}

provider_blocked_by() {
  _n=${1:?}; _repo=${2:-}
  _r=${_repo:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)}
  [ -n "$_r" ] || return 1
  _gh_read api "repos/$_r/issues/$_n/dependencies/blocked_by" --jq '.[].number' 
}

provider_link() {
  _n=${1:?}; _blocker_id=${2:?}; _repo=${3:-}
  _r=${_repo:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)}
  [ -n "$_r" ] || return 1
  # -F, not -f. `gh api -f` always sends a STRING, and this endpoint requires
  # an integer -- every call 422d with "is not of type integer". One character,
  # and it made the whole command inert against a real repository while every
  # test passed. See #45.
  _gh_write api --method POST "repos/$_r/issues/$_n/dependencies/blocked_by" \
     -F issue_id="$_blocker_id"
}

provider_unlink() {
  _n=${1:?}; _blocker_id=${2:?}; _repo=${3:-}
  _r=${_repo:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)}
  [ -n "$_r" ] || return 1
  _gh_write api --method DELETE "repos/$_r/issues/$_n/dependencies/blocked_by/$_blocker_id"
}

# --- creating and closing ----------------------------------------------------
#
# These four exist because file-issue, ask-async, reply-issue and check-replies
# called gh directly and so ignored the seam entirely. That made "a second
# backend is a new file" untrue for the half of the toolset most people reach
# for first -- see #44.
#
#   provider_create_issue    file it, return the URL
#   provider_ensure_label    best-effort; a missing label fails issue creation
#   provider_close_issue     close, with a reason where the backend has them
#   provider_issue_labels    label names for one issue, one per line

# provider_create_issue <repo> <title> [label ...] -> URL on stdout
#
# The body arrives on STDIN, not as an argument. An issue body routinely exceeds
# what an argument list should carry and always contains characters a shell
# would otherwise interpret.
provider_create_issue() {
  _repo=${1:-}; _title=${2:?}; shift 2
  # Rebuild the argument list rather than iterating it in place: "$@" is both
  # the label list being read and the command being built, and touching one
  # while reading the other is how the first version dropped every label.
  set -- $(for _l in "$@"; do printf -- '--label\n%s\n' "$_l"; done)
  # shellcheck disable=SC2086
  _gh_read issue create --title "$_title" --body-file - "$@" ${_repo:+--repo "$_repo"}
}

# Best-effort by design. A label that already exists is not an error, and a
# backend with no label concept should return 0 rather than fail the filing.
provider_ensure_label() {
  _label=${1:?}; _repo=${2:-}
  # shellcheck disable=SC2086
  gh label create "$_label" ${_repo:+--repo "$_repo"} >/dev/null 2>&1 || true
  return 0
}

# $2 is the backend reason where it has one. GitHub takes completed|not_planned|
# duplicate; a backend with no reasons should ignore it rather than refuse.
provider_close_issue() {
  _n=${1:?}; _reason=${2:-}; _repo=${3:-}
  # shellcheck disable=SC2086
  _gh_write issue close "$_n" ${_repo:+--repo "$_repo"} ${_reason:+--reason "$_reason"} ||
  # A backend that rejects the reason must still be able to close. Falling back
  # rather than failing keeps `reply-issue --closes` working against an older
  # instance that has no reasons at all.
  # shellcheck disable=SC2086
  _gh_write issue close "$_n" ${_repo:+--repo "$_repo"}
}

provider_issue_labels() {
  _n=${1:?}; _repo=${2:-}
  # shellcheck disable=SC2086
  _gh_read issue view "$_n" ${_repo:+--repo "$_repo"} --json labels -q '.labels[].name'
}

# provider_needs_human <repo> -> open issues awaiting a person, as JSON
#
# Separate from provider_issues because it asks a different question: the whole
# backlog versus the blocked subset, and only the latter needs comments. A
# backend where that subset is a status rather than a label implements it
# differently, which is exactly what the seam is for.
provider_needs_human() {
  _repo=${1:-}
  # shellcheck disable=SC2086
  _gh_read issue list --label needs-human --state open \
     --json number,title,comments,updatedAt --limit "${PM_LIMIT:-100}" \
     ${_repo:+--repo "$_repo"}
}

# --- triage state ------------------------------------------------------------
#
# provider_is_triaged <issue-json> -> 0 triaged · 1 not · 2 cannot tell
#
# "Has anyone classified this?" is NOT the same question as "does it carry three
# labels", and the difference only shows up on a backend other than this one.
#
# Here, ordering axes are labels: optional, absent by default, so their absence
# means nobody chose. On a tracker with a MANDATORY priority field there is no
# such state -- every issue has a priority from the moment it exists, usually
# defaulted by the backend rather than picked by a person, and an issue nobody
# looked at is indistinguishable from one deliberately set to the middle value.
#
# So the question belongs to the provider. GitHub answers it from labels. A
# backend with mandatory fields answers it from whatever it actually uses to
# mean nobody has looked at this -- a status, an unset sprint, a null assignee --
# or returns 2 to say it cannot tell, and the caller leaves the ordering key out
# rather than inventing an answer.
#
# RETURNING 2 IS NOT A LICENCE TO CARRY ON. It says the priority values this
# backend supplies are of unknown provenance -- some chosen by a person, some
# filled in by the tracker, and indistinguishable from here.
#
# That matters more than it first appears, because priority is the key the order
# actually turns on. Severity sits above it and fires only for two labels that a
# repository may not even define, in which case priority decides everything.
#
# The wrong response to 2 is to drop the untriaged key and rank as usual: that
# asserts every priority was chosen, and produces a confidently differentiated
# order built from values nobody set. A flat order is visibly useless; that one
# looks authoritative. So a caller that gets 2 must SAY SO in its output rather
# than quietly rank.
provider_is_triaged() {
  _issue=${1:?}
  command -v jq >/dev/null 2>&1 || return 2
  printf '%s' "$_issue" | jq -e '
    [ .labels[]? | (.name // .) ] as $l
    | ($l | any(startswith("priority-")))
      and ($l | any(startswith("urgency-")))
      and ($l | any(startswith("size-")))
  ' >/dev/null 2>&1 && return 0
  # jq exits 1 for a false result and 5 for a broken program or bad input. Only
  # the first means "not triaged"; the second means the question was not asked.
  case $? in
    1) return 1 ;;
    *) return 2 ;;
  esac
}
