# Choose and load the backend.
#
#   PM_PROVIDER=github   (default)   which backend
#   PM_REPO=owner/name               where its issues go
#
# PM_PROVIDER pinned WHICH backend and nothing pinned WHERE, so a filed question
# went wherever the shell was standing: with no --repo the provider omits -R and
# the backend CLI resolves the project from the current directory's git remote.
# An operator who configured the backend had not configured the destination.
#
# Every binary reads PM_REPO as the default for its --repo flag, so the
# precedence is the same as every other knob here: flag, then variable, then the
# backend's own cwd inference. Leaving both unset changes nothing.
#
# Sourced by every binary instead of naming a provider file directly. Eleven
# copies of a two-line loader is eleven places to fix a bug in it, and the bug
# worth avoiding is the quiet one: sourcing a file that does not exist leaves
# every provider_* function undefined, and the failure then surfaces three calls
# later as "provider_issues: not found" with nothing pointing at the cause.
#
# The setting is an environment variable because every other knob here is one --
# BACKLOG_NOW, STALE_HOURS, PM_LIMIT -- and no plugin in this repository has a
# config file. The cost is real and worth stating: a provider is closer to an
# install-time choice than a tunable, and an env var that must be set in every
# shell is one that will be missing from exactly one of them. When that happens
# the tools fall back to github rather than refusing, which is the safe failure
# only because github is the reference implementation.
#
# Requires PM_LIB to be set to the lib directory by the caller.

pm_load_provider() {
  _name=${PM_PROVIDER:-github}

  # A name is a filename here, so it must not be able to reach out of the lib
  # directory. PM_PROVIDER=../../../etc/passwd is not a threat model anyone is
  # defending against, but a name with a slash in it produces a confusing error
  # rather than a clear one.
  case "$_name" in
    ''|*/*|*' '*|.*)
      echo "pm: PM_PROVIDER='$_name' is not a provider name" >&2
      return 2 ;;
  esac

  _file=$PM_LIB/provider-$_name.sh
  if [ ! -r "$_file" ]; then
    echo "pm: no provider '$_name' -- expected $(basename "$_file") in $PM_LIB" >&2
    echo "pm: available:$(for f in "$PM_LIB"/provider-*.sh; do
                            [ -r "$f" ] || continue
                            b=${f##*/provider-}; printf ' %s' "${b%.sh}"
                          done)" >&2
    return 2
  fi

  # shellcheck disable=SC1090
  . "$_file"

  # A file that loads but does not implement the contract is worse than a
  # missing one: it fails later, somewhere else, in a way that reads like a bug
  # in the tool rather than in the provider. Two functions are enough to tell --
  # everything checks availability before doing anything.
  for _fn in provider_name provider_available; do
    command -v "$_fn" >/dev/null 2>&1 || {
      echo "pm: provider '$_name' does not define $_fn -- see lib/PROVIDERS.md" >&2
      return 2
    }
  done
  return 0
}
