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
namesrefs() {
  printf '%s' "$1" | jq -Rs '{type:"assistant",message:{content:[{type:"text",text:.}]}}' > "$TMP/t.jsonl"
  printf '{"transcript_path":"%s"}' "$TMP/t.jsonl" | sh "$HOOK" 2>&1 >/dev/null | head -1
}
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
allows "http, not only https"               "The anchor is at http://example.com/docs/page#123."
# Any scheme carries the same path shape. Matching only http would read these
# as project refs and block them.
allows "an uppercase scheme"                "The anchor is at HTTPS://example.com/docs/page#123."
allows "a non-web scheme"                   "See ftp://host.com/pub/dir/file#12 there."
allows "a compound scheme"                  "Clone git+ssh://git@host/group/project#123 now."
allows "a quote-wrapped URL"                'See "https://a.com/b/c#42" there.'
# The stop class earns its keep here: a quoted URL followed by a real ref.
blocks "a ref after a quoted URL"           'See "https://a.com/b"#64 now.'

# THE BOUNDARY. A URL is routinely followed by punctuation and then a real ref.
# Stripping to the next space swallowed the ref with it and the guard fell
# silent -- the exact case it exists for. Each of these blocked before path
# matching was added and must still block.
blocks "a ref after a URL and a comma"  "Details: https://github.com/o/r/pull/12,#64,#65."
blocks "a ref after a URL in brackets"  "Fixed in https://github.com/o/r/pull/12(#64 has the detail)."
blocks "a ref after emphasis marks"     "The change is up.

**https://github.com/o/r/pull/12**#64 is next."
blocks "a ref after a URL and a semicolon" "See https://a.com/b;#64."
blocks "a ref after an angle-bracketed URL" "See <https://a.com/b>#64 for it."

# A trailing slash sat between the two patterns: too path-shaped for the bare
# grep, and with nothing after the slash for the pathed one.
blocks "a path with a trailing slash"   "See group/project/#123 here."

# The documented exemption, pinned like the other known limits. project#123 is
# lexically identical to PR#63; no rule fires on one without the other.
allows "a single segment stays exempt"  "The project#123 build is green."
# ...but only for "#". The collision that forced the slash rule belongs to "#"
# alone: PR#63, step#2, a hex colour. "!" glued to digits after a word is not
# something English does, so sqlgate!406 -- the short form people actually type
# for a merge request -- has no ambiguity to protect and should fire.
blocks "a slash-less project before !" "The pipeline is fixed.

See sqlgate!406 for it."
blocks "a dotted project before !"     "See my.proj!12 for it."
allows "a word before # stays exempt"  "The PR#63 title was fine."
allows "!!42 is still not a ref"       "Wait!!42 was the version before."
allows "a bare ! is not a ref"         "It works! 42 times over."
# Named WHOLE, like the pathed form: "sqlgate!406" tells the reader which
# project, which is the entire complaint. "!406" repeats the problem. The
# exit-code assertions above cannot see this.
r=$(namesrefs 'See sqlgate!406 for it.')
case "$r" in
  *'sqlgate!406'*) ok "a slash-less project ref is named whole" ;;
  *) bad "a slash-less project ref is named whole" "$r" ;;
esac

# The pathed grep must run on the STRIPPED text, like the bare one. Without
# these, gutting the fence, link and code-span strips for PATHED alone left the
# suite fully green.
allows "a pathed ref in backticks"      'The message says `group/project!123` fails.'
allows "a pathed ref in a link"         "See [group/project!123](https://host/group/project/-/merge_requests/123)."
allows "a pathed ref in a fence"        'It fails like this:

```
group/project!123
```

Nothing else.'
allows "##42 heading, no match" "##42 the rule, at last."
# A markdown link already carries its URL; its link text is not a bare
# citation. The first version blocked this and demanded the URL it had.
allows "a markdown link carries its URL" "See [#64](https://github.com/o/r/issues/64) for details."
allows "glued to a word"     "The PR#63 title was the issue's title."
allows "a hash with no digits" "The bug is in # comment handling."
# Documented limit, pinned: "the # 42 evasion" is unmatched.
allows "a space after the marker" "It is issue # 42 on the list."
allows "no refs at all"      "Both suites pass; CI is green."

# --- inline backticks: pair, or strip nothing on that line -------------------
# The second inline strip, s/`[^`]*//g, consumes a leftover backtick together
# with everything after it -- to END OF LINE, not to the quote. So one stray
# backtick hid every ref after it and the guard passed silently. That is the
# same failure the fence rule above was written to prevent, one level down,
# and it argues the same remedy: if the backticks on a line do not pair up,
# strip nothing on that line rather than everything past the odd one.
blocks "a stray backtick does not swallow a ref" 'Stray ` before it: see #64 too.'
blocks "a stray backtick before a URL and a ref" 'Stray ` here: see https://a.com/b/c#42 and #64 too.'
blocks "an odd backtick with a pathed ref after" 'Stray ` here: group/project!123 is next.'
# The pairing case must keep working: a quoted ref is not a citation.
allows "balanced backticks still quote"      'The message says `backlog-claim #42` fails.'
allows "two pairs on one line"               'Both `#42` and `#43` are quoted here.'
# An odd count on ONE line must not disarm quoting on the others.
blocks "an odd line does not disarm the rest" 'Stray ` on this line with #64.

And `#65` is properly quoted, but #66 is not.'
# A quoted ref on the SAME line as a stray tick stays quoted. An earlier fix
# left the whole line alone when the ticks did not pair, which reported the
# properly-quoted #42 as bare -- a false positive on correct writing.
printf '%s' 'See `#42` and a stray ` then #64.' | jq -Rs '{type:"assistant",message:{content:[{type:"text",text:.}]}}' > "$TMP/t.jsonl"
out=$(printf '{"transcript_path":"%s"}' "$TMP/t.jsonl" | sh "$HOOK" 2>&1 >/dev/null | head -1)
case "$out" in
  *'#42'*) bad "a quoted ref beside a stray tick stays quoted" "$out" ;;
  *'#64'*) ok "a quoted ref beside a stray tick stays quoted" ;;
  *) bad "a quoted ref beside a stray tick stays quoted" "no ref reported: $out" ;;
esac

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
else bad "reference-links escape"; fi

# --- safety rails, same as the siblings -----------------------------------------
printf '%s' "Filed #64." | jq -Rs '{type:"assistant",message:{content:[{type:"text",text:.}]}}' > "$TMP/t.jsonl"
if printf '{"transcript_path":"%s","stop_hook_active":true}' "$TMP/t.jsonl" | sh "$HOOK" >/dev/null 2>&1
then ok "stop_hook_active stops it re-blocking"
else bad "stop_hook_active"; fi

if printf '{"transcript_path":"%s"}' "$TMP/t.jsonl" | CLAUDE_ALLOW_ASKING=1 sh "$HOOK" >/dev/null 2>&1
then ok "CLAUDE_ALLOW_ASKING=1 overrides, same switch as the siblings"
else bad "escape hatch"; fi

if printf '{"transcript_path":"/nope/missing.jsonl"}' | sh "$HOOK" >/dev/null 2>&1
then ok "a missing transcript stands down"
else bad "missing transcript"; fi

if printf '' | sh "$HOOK" >/dev/null 2>&1
then ok "empty input stands down"; else bad "empty input"; fi

# --- the message has to say what to do instead --------------------------------
printf '%s' "Filed #64 and #65." | jq -Rs '{type:"assistant",message:{content:[{type:"text",text:.}]}}' > "$TMP/t.jsonl"
out=$(printf '{"transcript_path":"%s"}' "$TMP/t.jsonl" | sh "$HOOK" 2>&1 >/dev/null)
case "$out" in *'#64'*) ok "names the offending refs" ;; *) bad "names the refs" "$out" ;; esac
case "$out" in *'https://github.com/OWNER/REPO'*) ok "shows the replacement shape" ;; *) bad "replacement shape" "$out" ;; esac
case "$out" in *CLAUDE_REFERENCE_LINKS*) ok "and names the clickable-terminal escape" ;; *) bad "names the escape" "$out" ;; esac

# A pathed ref is reported whole: "group/project!123" tells a reader which
# project, which is the entire complaint. "!123" repeats the problem.
printf '%s' "See group/project!123 for it." | jq -Rs '{type:"assistant",message:{content:[{type:"text",text:.}]}}' > "$TMP/t.jsonl"
# Match the FIRST line only: the help text below it contains the literal
# "group/project!123" as an example, so matching the whole message passes
# whatever PATHED reports.
out=$(printf '{"transcript_path":"%s"}' "$TMP/t.jsonl" | sh "$HOOK" 2>&1 >/dev/null | head -1)
case "$out" in *'group/project!123'*) ok "names a pathed ref whole" ;; *) bad "names a pathed ref whole" "$out" ;; esac

# --- the message must name each ref exactly once, and drop none ---------------
# Two independent grep -o passes reported a pathed ref AND the bare ref inside
# it ("!1 -/-!1"), and dropped a second marker inside a path entirely, because
# grep -o does not overlap. The verdict was right in both; the list was not,
# and a list that names one of two wrong refs sends the reader to fix the wrong
# thing.
r=$(namesrefs 'See -/-!1 and _/_!2 here.')
case "$r" in
  *'!1 -/-!1'*|*'!2 _/_!2'*) bad "a punctuation prefix is not named twice" "$r" ;;
  *'-/-!1'*'_/_!2'*) ok "a punctuation prefix is named once, whole" ;;
  *) bad "a punctuation prefix is named once" "$r" ;;
esac

r=$(namesrefs 'See group/a#1/b#2 here.')
case "$r" in
  *'#2'*) ok "a second marker inside a path is not dropped" ;;
  *) bad "a second marker inside a path is not dropped" "$r" ;;
esac

# The plain shapes must still be named exactly as before.
r=$(namesrefs 'Filed #64 and #65.')
case "$r" in *'#64 #65'*) ok "two bare refs, both named" ;; *) bad "two bare refs" "$r" ;; esac
r=$(namesrefs 'See group/project!123 and #64.')
case "$r" in
  *'!123 group'*) bad "a pathed ref is not also named bare" "$r" ;;
  *'group/project!123'*) ok "a pathed ref beside a bare one, each once" ;;
  *) bad "pathed beside bare" "$r" ;;
esac

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
