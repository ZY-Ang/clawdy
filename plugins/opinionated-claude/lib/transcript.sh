# tail_turn <transcript>  -- print the end of the transcript (JSONL), from far
# enough back to hold the last human message and the last assistant entry.
#
# The hooks only judge the current turn, so a long session must not cost more
# than that turn: parsing the whole file hit the Stop-hook timeout.
# The window grows x4 from 256 KiB and falls back to the whole file.
tail_turn() {
  _size=$(wc -c < "$1" | tr -d ' ') _n=262144
  while [ "$_n" -lt "$_size" ]; do
    # The window starts mid-line; drop that partial line.
    _win=$(tail -c "$_n" "$1" | sed 1d)
    # "Human" is a user entry with no tool_result, as in no-announced-work.
    if printf '%s\n' "$_win" | jq -se '
         any(.[]; .type == "assistant")
         and any(.[]; .type == "user"
                 and ( (.message.content | type) == "string"
                       or ( [ .message.content[]?.type ] | index("tool_result") | not ) ))
       ' >/dev/null 2>&1; then
      printf '%s\n' "$_win"
      return
    fi
    _n=$((_n * 4))
  done
  cat "$1"
}
