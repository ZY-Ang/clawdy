# The dependency graph, and the one seam that makes it testable.
#
# Sourced by backlog-queue and backlog-triage. Both need the same edges, and a
# graph read two different ways is two graphs.
#
# BACKLOG_DEPS_JSON overrides the edges entirely:
#
#   [ {"number": 12, "blockedBy": [7, 9]}, {"number": 7, "blockedBy": []} ]
#
# It exists because the edges are the hardest part to obtain and the easiest to
# get wrong. On the repository this plugin was designed from, every blockedBy
# was EMPTY across all 160 issues -- so a fixture drawn from real data proves
# nothing about ranking or about cycles, and a cycle cannot be conjured by
# waiting for one to appear upstream.
#
# The shapes accepted are the same two backlog-queue already handles: a plain
# array, and gh's object wrapper {"nodes": [...], "totalCount": n}.

# deps_normalise <issues-json> -> [{number, blockedBy:[number]}] on stdout
#
# When BACKLOG_DEPS_JSON is set it REPLACES the edges rather than adding to
# them, so a test states the whole graph and nothing leaks in from the issue
# fixture. Merging the two would make a case depend on both files at once,
# which is how a fixture starts disagreeing with the thing it is testing.
deps_normalise() {
  _issues=$1
  if [ -n "${BACKLOG_DEPS_JSON:-}" ]; then
    [ -r "$BACKLOG_DEPS_JSON" ] || return 1
    jq -e '
      def edge: if type == "object" then .number else . end;
      if type != "array" then error("deps must be an array") else . end
      | map({ number: (.number | tonumber),
              blockedBy: [ (.blockedBy // [])[] | edge | tonumber ] })
    ' "$BACKLOG_DEPS_JSON" 2>/dev/null
    return
  fi
  printf '%s' "$_issues" | jq -e '
    # An element of blockedBy is either an object carrying a number field (what
    # the gh nodes contain) or a bare integer (what the provider contract in
    # this repo documents: blockedBy: [number]). Writing it as .number // .
    # reads well and errors on the integer, because jq cannot index a number
    # with a string, so the type is checked rather than assumed. backlog-queue
    # failed on its own documented shape for two releases because of it.
    # NOTE: no apostrophes below. This jq program is single-quoted; one
    # apostrophe ends it and hands the remainder to the shell.
    def edge: if type == "object" then .number else . end;
    map({ number: .number,
          blockedBy: [ (.blockedBy
                        | if type == "object" then (.nodes // []) else (. // []) end)[]?
                       | edge ] })
  ' 2>/dev/null
}

# deps_cycles <normalised-deps> -> one cycle per line, as "12 -> 7 -> 12"
#
# Reported, never worked around. #22 measured seven cycles on one backlog, three
# of them real and blocking, and an order that silently picked one side of a
# cycle would be an order that cannot be built in the sequence it gives.
#
# Depth-first, iterative in jq: a recursive walk over a cyclic graph is exactly
# the thing that does not terminate.
deps_cycles() {
  printf '%s' "$1" | jq -r '
    . as $g
    | (reduce $g[] as $n ({}; .[$n.number | tostring] = $n.blockedBy)) as $adj
    | [ $g[].number ]
    | map(
        . as $start
        | { stack: [[$start, [$start]]], seen: {}, found: null }
        | until(
            .found != null or (.stack | length) == 0;
            (.stack[-1]) as $top
            | .stack |= .[0:-1]
            | $top[0] as $node | $top[1] as $path
            | ($adj[$node | tostring] // []) as $next
            | if ($next | index($start)) then
                .found = (($path + [$start]) | map(tostring) | join(" -> "))
              else
                .stack += [ $next[] as $m
                            | select((.seen[$m | tostring] // false) | not)
                            | [$m, $path + [$m]] ]
                | .seen[$node | tostring] = true
              end
          )
        | .found
      )
    | map(select(. != null))
    # One cycle is reported once. Starting the walk from every node finds the
    # same loop once per member, and three lines describing one problem reads
    # as three problems. Keyed on the UNIQUE members: the start node appears at
    # both ends of the path, so sorting the raw path gives 1,1,2 and 1,2,2 for
    # the two rotations of one cycle and the dedup misses. (No apostrophes in
    # this jq program: it is single-quoted, and one apostrophe ends it.)
    | map({ key: (split(" -> ") | map(tonumber) | unique | map(tostring) | join(",")), val: . })
    | group_by(.key) | map(.[0].val)
    | .[]
  ' 2>/dev/null
}
