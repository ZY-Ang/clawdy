#!/bin/sh
# A turn that cites work by bare number ends unclickable. Full URLs or nothing.
#
#   sh plugins/opinionated-claude/tests/refs.test.sh

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOOK=$HERE/../hooks/no-bare-refs
TMP=${TMPDIR:-/tmp}/refs-test.$$
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM
command -v jq >/dev/null 2>&1 || { echo "refs.test: jq required" >&2; exit 1; }

fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"
        return 0; }

say() {
  # %b so \n in a case string becomes a real newline -- the fence case needs
  # real lines for the fence stripper to see them.
  printf '%b' "$1" | jq -Rs '{type:"assistant",message:{content:[{type:"text",text:.}]}}' \
    > "$TMP/t.jsonl"
  printf '{"transcript_path":"%s","stop_hook_active":false}' "$TMP/t.jsonl" \
    | sh "$HOOK" >/dev/null 2>&1
  echo $?
}
blocks() { if [ "$(say "$2")" -eq 2 ]; then ok "$1"; else bad "$1" "not blocked"; fi; }
allows() { if [ "$(say "$2")" -eq 0 ]; then ok "$1"; else bad "$1" "blocked, should not be"; fi; }

# --- the shape that produced this hook ---------------------------------------
blocks "#64 cited bare"      "Both are worth tracking.

Filed #64 and #65, both labelled task."
blocks "!42 cited bare"      "The MR is up.

See !42 for the pipeline change."
blocks "several in one list" "Waiting on your merge of:

- #67 -- the title rule
- #68 -- the label fix"
blocks "refs after a sentence" "That is the fix.

Fixed the retry, then pushed. See #55 for the remaining guard work."

# --- path-prefixed refs: the form other hosts actually print --------------------
# On a host where a project is a PATH rather than a flat owner/repo,
# group/subgroup/project!123 is the ordinary way to cite a merge request. The
# word-glue carve-out below hid it: the character before the marker is a
# letter, so the original class never fired. A slash in the prefix is what
# separates the two -- PR#63 has none, a project path always has one.
blocks "a path-prefixed MR ref"    "The pipeline change is up.

See group/project!123 for the fix."
blocks "a subgroup path, nested"   "The pipeline change is up.

See group/subgroup/project!123 for the fix."
blocks "a path-prefixed issue ref" "That is tracked already.

See group/project#123 for the detail."

# --- what must still pass -----------------------------------------------------
allows "full URLs"           "Waiting on your merge of:

- https://github.com/o/r/pull/67 -- the title rule
- https://github.com/o/r/pull/68 -- the label fix"
# The / exclusion is what these two exercise: a # after a slash is part of a
# URL, and a ! after ! is an exclamation, not a ref.
allows "a # in a URL path"   "The page is at https://example.com/#42."
allows "!!42 is not a ref"   "Wait!!42 was the version before."
# Single quotes: in double quotes POSIX sh runs backticks as command
# substitution, which is how the first version of these two cases executed the
# very binary the message quotes.
allows "quoted in backticks" 'The message says `backlog-claim #42` fails the first time.'
allows "a fenced block"      'It fails like this:

```
backlog-claim #42
```

Nothing else to add.'
# The # exclusion is exercised here: ##42 must not match, or a markdown
# heading with a digit would block. The earlier case said "## Two rules" and
# had no digit to exclude -- it passed with the class wrong.
# Path-shaped matching would otherwise read a URL path as a project path, so
# bare URLs are stripped before matching. A ref already written as a URL is
# self-evidently not a bare one.
allows "a bare URL with a numeric fragment" "The anchor is at https://example.com/docs/page#123."
allows "a bare URL ending in a ref path"    "See https://gitlab.com/group/project/-/merge_requests/123 for it."
allows "##42 heading, no match" "##42 the rule, at last."
# A markdown link already carries its URL; its link text is not a bare
# citation. The first version blocked this and demanded the URL it had.
allows "a markdown link carries its URL" "See [#64](https://github.com/o/r/issues/64) for details."
allows "glued to a word"     "The PR#63 title was the issue's title."
allows "a hash with no digits" "The bug is in # comment handling."
# Documented limit, pinned: "the # 42 evasion" is unmatched.
allows "a space after the marker" "It is issue # 42 on the list."
allows "no refs at all"      "Both suites pass; CI is green."

# --- fences: pairing, not swallowing ------------------------------------------
# An odd fence is a typo, and the first version treated everything after it as
# code -- one stray backtick-triple hid a real ref and the guard passed
# silently. Now an odd count strips nothing, so the ref is still seen.
blocks "a stray fence does not swallow a ref" 'Here it is:

```
see #64 for details'
# And with a balanced fence, a ref outside it is seen as usual.
blocks "a ref after a balanced fence" 'The block:

```
see #64
```

And #65 here, outside.'

# --- the documented false positive: prose numbers -----------------------------
# Any bare #N could be a citation, and reading one as prose is the failure the
# guard exists for -- so "we're #1" is blocked on purpose and named in the
# conventions.
blocks "a prose number is still blocked" "We're #1 in the standings."

# --- the exception: the terminal renders links ---------------------------------
printf '%s' "Filed #64 and #65." | jq -Rs '{type:"assistant",message:{content:[{type:"text",text:.}]}}' > "$TMP/t.jsonl"
if printf '{"transcript_path":"%s"}' "$TMP/t.jsonl" | CLAUDE_REFERENCE_LINKS=1 sh "$HOOK" >/dev/null 2>&1
then ok "CLAUDE_REFERENCE_LINKS=1 stands down -- the terminal renders them clickable"
else fails=$((fails+1)); printf 'FAIL reference-links escape\n'; fi
ran=$((ran+1))

# --- safety rails, same as the siblings -----------------------------------------
printf '%s' "Filed #64." | jq -Rs '{type:"assistant",message:{content:[{type:"text",text:.}]}}' > "$TMP/t.jsonl"
if printf '{"transcript_path":"%s","stop_hook_active":true}' "$TMP/t.jsonl" | sh "$HOOK" >/dev/null 2>&1
then ok "stop_hook_active stops it re-blocking"
else fails=$((fails+1)); printf 'FAIL stop_hook_active\n'; fi
ran=$((ran+1))

if printf '{"transcript_path":"%s"}' "$TMP/t.jsonl" | CLAUDE_ALLOW_ASKING=1 sh "$HOOK" >/dev/null 2>&1
then ok "CLAUDE_ALLOW_ASKING=1 overrides, same switch as the siblings"
else fails=$((fails+1)); printf 'FAIL escape hatch\n'; fi
ran=$((ran+1))

if printf '{"transcript_path":"/nope/missing.jsonl"}' | sh "$HOOK" >/dev/null 2>&1
then ok "a missing transcript stands down"
else fails=$((fails+1)); printf 'FAIL missing transcript\n'; fi
ran=$((ran+1))

if printf '' | sh "$HOOK" >/dev/null 2>&1
then ok "empty input stands down"; else fails=$((fails+1)); printf 'FAIL empty input\n'; fi
ran=$((ran+1))

# --- the message has to say what to do instead --------------------------------
printf '%s' "Filed #64 and #65." | jq -Rs '{type:"assistant",message:{content:[{type:"text",text:.}]}}' > "$TMP/t.jsonl"
out=$(printf '{"transcript_path":"%s"}' "$TMP/t.jsonl" | sh "$HOOK" 2>&1 >/dev/null)
case "$out" in *'#64'*) ok "names the offending refs" ;; *) bad "names the refs" "$out" ;; esac
case "$out" in *'https://github.com/OWNER/REPO'*) ok "shows the replacement shape" ;; *) bad "replacement shape" "$out" ;; esac
case "$out" in *CLAUDE_REFERENCE_LINKS*) ok "and names the clickable-terminal escape" ;; *) bad "names the escape" "$out" ;; esac

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
