# shellcheck shell=bash
# Helpers for the runner-side scripts. Sourced, never executed.

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '%s\n' "$*" >&2
}

# require NAME...: fails once, listing every variable that is unset or empty.
require() {
  local name missing=()
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || missing+=("$name")
  done
  ((${#missing[@]} == 0)) || die "required variables are not set: ${missing[*]}"
}

# shell_quote VALUE: VALUE as one single-quoted shell word. The result is read the
# same way by sh, dash and bash, whatever quotes, spaces or $ the value contains.
# sed rather than ${1//...}: bash 3.2 and 5.x treat backslashes in that replacement
# differently. The trailing dot keeps trailing newlines through $(...).
shell_quote() {
  local escaped
  escaped=$(printf '%s.' "$1" | sed "s/'/'\\\\''/g")
  printf "'%s'" "${escaped%.}"
}

# env_line NAME VALUE: a NAME='value' line that `. file` restores exactly.
env_line() {
  printf '%s=%s\n' "$1" "$(shell_quote "$2")"
}

# warn_loud TITLE LINE...: a yellow banner that stands out in a long job log,
# plus a warning annotation on the run page when running in GitHub Actions.
warn_loud() {
  local title=$1 rule='========================================================'
  shift
  printf '\n\033[1;33m%s\n  %s\n%s\033[0m\n' "$rule" "$title" "$rule" >&2
  printf '  %s\n' "$@" >&2
  printf '\033[1;33m%s\033[0m\n\n' "$rule" >&2
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    printf '::warning title=%s::%s\n' "$title" "$*"
  fi
}

# set_output NAME VALUE: a step output in GitHub Actions, nothing elsewhere.
set_output() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
  fi
}
