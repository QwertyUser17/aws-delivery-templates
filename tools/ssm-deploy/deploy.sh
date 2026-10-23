#!/usr/bin/env bash
# ssm-deploy, runner side: checks the inputs, sends remote.sh through SSM Run Command,
# waits for it and prints its output from CloudWatch Logs.
# No SSH and no open ports: the instance only needs Docker, the SSM agent and a role.
# Self-contained on purpose: it needs bash, the AWS CLI and jq, nothing else from
# this repository. See README.md next to it.
set -Eeuo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '%s\n' "$*" >&2
}

require() {
  local name missing=()
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || missing+=("$name")
  done
  ((${#missing[@]} == 0)) || die "required variables are not set: ${missing[*]}"
}

# shell_quote VALUE: VALUE as one single-quoted word for sh, dash and bash.
# sed rather than ${1//...}: bash 3.2 and 5.x treat backslashes in that replacement
# differently. The trailing dot keeps trailing newlines through $(...).
shell_quote() {
  local escaped
  escaped=$(printf '%s.' "$1" | sed "s/'/'\\\\''/g")
  printf "'%s'" "${escaped%.}"
}

require AWS_REGION INSTANCE_ID IMAGE_REF CONTAINER_NAME
: "${PUBLISH:=}"
: "${RUN_ARGS:=}"
: "${CONTAINER_ENV:=}"
: "${HEALTH_PASSES:=6}"
: "${HEALTH_INTERVAL:=5}"
: "${HEALTH_MAX_CHECKS:=$((HEALTH_PASSES + 20))}"
: "${PRUNE:=true}"
: "${KEEP_RELEASE:=5}"
: "${KEEP_BRANCH:=3}"
: "${LOG_MAX_SIZE:=10m}"
: "${LOG_MAX_FILES:=5}"
: "${LOG_GROUP:=/aws-delivery/ec2/$CONTAINER_NAME}"
: "${LOG_RETENTION_DAYS:=14}"
: "${SSM_WAIT_TIMEOUT:=900}"
: "${SSM_POLL_INTERVAL:=5}"

# A variable or a command substitution in PUBLISH or RUN_ARGS is something the CI
# was meant to substitute and didn't. It would reach docker as plain text, so stop
# here instead. Values are never printed: run args often carry tokens, and job logs
# are kept for a long time.
check_run_args() {
  local text="$PUBLISH $RUN_ARGS" found
  # shellcheck disable=SC2016 # the $ in these patterns is literal on purpose
  found=$(grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*\}?' <<<"$text" | tr -d '${}' | sort -u | paste -sd' ' - || true)
  [[ -z $found ]] || die "unresolved variables in publish or run-args: $found. Pass the values themselves, or secrets through container-env."
  # shellcheck disable=SC2016
  [[ $text != *'$('* && $text != *'`'* ]] || die "command substitution in publish or run-args is not allowed"
}

# quote_words NAME TEXT: TEXT split into words the way xargs splits its input
# (quotes and backslashes work, nothing is expanded), each word single-quoted.
# The instance runs eval on these words, so ; | & > * and newlines in them stay
# plain characters and are never run as shell code.
quote_words() {
  local word words out=''
  words=$(xargs -r printf '%s\n' <<<"$2" 2>/dev/null) || die "$1 has an unmatched quote"
  [[ -n $words ]] || return 0
  while IFS= read -r word; do
    out+="${out:+ }$(shell_quote "$word")"
  done <<<"$words"
  printf '%s' "$out"
}

# container-env holds KEY=value lines, usually from a CI secret. Each line becomes
# one -e argument, quoted so that nothing in the value is expanded on the instance.
env_args() {
  local line out=''
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z ${line// /} || $line == \#* ]] && continue
    [[ $line == [A-Za-z_]*=* ]] || die "container-env line is not KEY=value: ${line%%=*}"
    out+=" -e $(shell_quote "$line")"
  done <<<"$CONTAINER_ENV"
  printf '%s' "$out"
}

# PUBLISH and RUN_ARGS as the instance gets them: quoted words only, container-env
# included.
prepare_docker_args() {
  check_run_args
  PUBLISH=$(quote_words publish "$PUBLISH")
  RUN_ARGS=$(quote_words run-args "$RUN_ARGS")
  RUN_ARGS+=$(env_args)
}

# The instance script: values first, as single-quoted assignments, then remote.sh
# as it is in the repository. No escaping anywhere.
compose_remote_script() {
  local name
  printf '%s\n' '#!/bin/sh' 'set -eu'
  for name in AWS_REGION REGISTRY IMAGE_REF CONTAINER_NAME PUBLISH RUN_ARGS \
    HEALTH_PASSES HEALTH_INTERVAL HEALTH_MAX_CHECKS PRUNE KEEP_RELEASE KEEP_BRANCH \
    LOG_MAX_SIZE LOG_MAX_FILES; do
    printf '%s=%s\n' "$name" "$(shell_quote "${!name}")"
  done
  cat "$here/remote.sh"
}

# AWS-RunShellScript takes the script as a list of lines. jq does the JSON encoding,
# so quotes, backslashes and tabs in the script reach the instance unchanged.
ssm_parameters() {
  jq -n --rawfile script "$1" --arg timeout "$SSM_WAIT_TIMEOUT" \
    '{commands: ($script | rtrimstr("\n") | split("\n")), executionTimeout: [$timeout]}'
}

ensure_log_group() {
  aws logs create-log-group --log-group-name "$LOG_GROUP" --region "$AWS_REGION" 2>/dev/null || true
  aws logs put-retention-policy --log-group-name "$LOG_GROUP" \
    --retention-in-days "$LOG_RETENTION_DAYS" --region "$AWS_REGION"
}

# wait_for_command ID: prints the final status. Right after send-command the
# invocation may not exist yet, so InvocationDoesNotExist counts as pending.
wait_for_command() {
  local id=$1 status err api_errors=0 deadline=$((SECONDS + SSM_WAIT_TIMEOUT + 60))
  err=$(mktemp)
  while :; do
    if status=$(aws ssm get-command-invocation --command-id "$id" --instance-id "$INSTANCE_ID" \
      --region "$AWS_REGION" --query Status --output text 2>"$err"); then
      api_errors=0
    elif grep -q InvocationDoesNotExist "$err"; then
      status=Pending
    else
      api_errors=$((api_errors + 1))
      ((api_errors < 3)) || {
        cat "$err" >&2
        status=Unknown
        break
      }
      status=Pending
    fi
    case $status in
      Success | Failed | Cancelled | TimedOut) break ;;
    esac
    if ((SECONDS >= deadline)); then
      note "No result after ${SSM_WAIT_TIMEOUT}s, cancelling command $id"
      aws ssm cancel-command --command-id "$id" --region "$AWS_REGION" >/dev/null 2>&1 || true
      status=TimedOut
      break
    fi
    sleep "$SSM_POLL_INTERVAL"
  done
  rm -f "$err"
  printf '%s' "$status"
}

# print_stream NAME: all events of one output stream, following the paging tokens.
print_stream() {
  local token='' next page
  while :; do
    page=$(aws logs get-log-events --log-group-name "$LOG_GROUP" --log-stream-name "$1" \
      --start-from-head --region "$AWS_REGION" ${token:+--next-token "$token"} --output json) || return 1
    jq -r '.events[].message' <<<"$page"
    next=$(jq -r '.nextForwardToken' <<<"$page")
    [[ $next != "$token" ]] || return 0
    token=$next
  done
}

# CloudWatch receives the output a few seconds after the command ends.
print_output() {
  local id=$1 stream
  stream="$id/$INSTANCE_ID/aws-runShellScript"
  for _ in 1 2 3 4 5 6; do
    if aws logs describe-log-streams --log-group-name "$LOG_GROUP" --log-stream-name-prefix "$stream/" \
      --region "$AWS_REGION" --query 'logStreams[0].logStreamName' --output text 2>/dev/null | grep -q "$id"; then
      break
    fi
    sleep 5
  done
  printf '\n----- output from %s -----\n' "$INSTANCE_ID"
  if ! print_stream "$stream/stdout"; then
    note "No output in CloudWatch, showing the truncated copy SSM keeps"
    aws ssm get-command-invocation --command-id "$id" --instance-id "$INSTANCE_ID" \
      --region "$AWS_REGION" --query StandardOutputContent --output text || true
  fi
  print_stream "$stream/stderr" 2>/dev/null || true
  printf -- '----- end of output -----\n\n'
}

main() {
  local script params command_id status
  prepare_docker_args
  # shellcheck disable=SC2034 # read through ${!name} in compose_remote_script
  REGISTRY=${IMAGE_REF%%/*}

  ensure_log_group
  script=$(mktemp)
  params=$(mktemp)
  compose_remote_script >"$script"
  ssm_parameters "$script" >"$params"
  rm -f "$script"

  note "Deploying $IMAGE_REF as $CONTAINER_NAME on $INSTANCE_ID"
  command_id=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name AWS-RunShellScript \
    --comment "deploy $CONTAINER_NAME" \
    --parameters "file://$params" \
    --cloud-watch-output-config "CloudWatchOutputEnabled=true,CloudWatchLogGroupName=$LOG_GROUP" \
    --region "$AWS_REGION" \
    --query Command.CommandId --output text)
  rm -f "$params"
  note "SSM command $command_id, output goes to $LOG_GROUP"

  status=$(wait_for_command "$command_id")
  output=$(mktemp)
  print_output "$command_id" | tee "$output"
  if [[ $status != Success ]]; then
    # remote.sh ends a failed deploy with one "Deploy failed:" line that names the
    # cause. Repeat it where the job log ends, so it is the first thing you read.
    verdict=$(grep '^Deploy failed: ' "$output" | tail -n 1 || true)
    rm -f "$output"
    die "${verdict:-deploy failed on $INSTANCE_ID (SSM status: $status)}"
  fi
  rm -f "$output"
  note "Deployed $IMAGE_REF as $CONTAINER_NAME on $INSTANCE_ID"
}

# Sourced by the tests for its functions, executed by the workflows.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
