# A PATH with everything on it except gh.
#
# Six suites used to refuse to run when a real gh was installed, and exit 1
# while refusing -- the same code a real failure uses. So `for t in
# plugins/*/tests/*.test.sh; do sh "$t"; done` reported six failures on any
# machine that has gh, which is every machine that runs this toolkit. The
# signal that the suite is green was unavailable exactly where a contributor
# would look for it.
#
# They never needed the OPERATOR's environment to be missing a tool. They
# needed gh absent from the PATH they hand the code under test, which is
# something a test can build for itself.
#
# A symlink farm, not a PATH edit: gh is routinely installed in more than one
# directory (three, on the machine this was written on -- ~/.local/bin,
# /usr/bin and /bin), so dropping the directory that "has" gh drops coreutils
# with it and still leaves the other copies reachable.
#
#   . "$HERE/lib/gh-free.sh"
#   PATH=$(gh_free_path "$TMP/nogh"); export PATH
gh_free_path() {
  _farm=${1:?gh_free_path needs a directory}
  mkdir -p "$_farm" || return 1
  _oifs=$IFS; IFS=:
  for _d in $PATH; do
    [ -d "$_d" ] || continue
    for _f in "$_d"/*; do
      [ -f "$_f" ] || continue
      _b=${_f##*/}
      [ "$_b" = gh ] && continue
      [ -e "$_farm/$_b" ] && continue
      ln -s "$_f" "$_farm/$_b" 2>/dev/null || :
    done
  done
  IFS=$_oifs
  printf '%s' "$_farm"
}
