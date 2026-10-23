#!/usr/bin/env bats
# Runs the whole deploy with a fake docker (tests/mocks) and checks what happened.

setup() {
  TOOL=$(cd "$BATS_TEST_DIRNAME/.." && pwd)
  MOCK_DIR=$(mktemp -d)
  export MOCK_DIR
  PATH="$BATS_TEST_DIRNAME/mocks:$PATH"
  echo 'app reg.example/app:41' >"$MOCK_DIR/containers"
}

# deploy: builds the instance script like deploy.sh does and runs it with dash.
deploy() {
  AWS_REGION=eu-central-1 INSTANCE_ID=i-0123456789abcdef0 IMAGE_REF=reg.example/app:42 \
    CONTAINER_NAME=app REGISTRY=reg.example PUBLISH='-p 80:8080' RUN_ARGS="${RUN_ARGS:-}" \
    HEALTH_PASSES=2 HEALTH_INTERVAL=0 HEALTH_MAX_CHECKS=5 KEEP_RELEASE="${KEEP_RELEASE:-5}" \
    bash -c '. "$1"; prepare_docker_args; compose_remote_script' _ "$TOOL/deploy.sh" >"$MOCK_DIR/remote.sh" || return 1
  run dash -c 'cd "$1" && dash remote.sh' _ "$MOCK_DIR"
}

# health LINE...: what docker inspect says about "app", one line per check.
health() {
  printf '%s\n' "$@" >"$MOCK_DIR/states.app"
}

@test "a healthy container replaces the old one" {
  health 'running:healthy:T2'
  deploy
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_DIR/containers")" = 'app reg.example/app:42' ]
}

@test "a failed pull doesn't touch the running container" {
  echo 1 >"$MOCK_DIR/pull_rc"
  deploy
  [ "$status" -eq 1 ]
  [[ $output == *"Deploy failed: pull of reg.example/app:42 failed. The running container was not touched."* ]]
  [ "$(cat "$MOCK_DIR/containers")" = 'app reg.example/app:41' ]
}

@test "an unhealthy container is replaced by the old one again, and the job says why" {
  health 'running:unhealthy:T2' 'running:healthy:T1'
  deploy
  [ "$status" -eq 1 ]
  [[ $output == *"Deploy failed: reg.example/app:42 rolled back to reg.example/app:41: its healthcheck reports unhealthy"* ]]
  [ "$(cat "$MOCK_DIR/containers")" = 'app reg.example/app:41' ]
}

@test "a -previous container left by a failed rollback is the rollback target" {
  echo 'app-previous reg.example/app:41' >"$MOCK_DIR/containers"
  health 'exited:none:T2' 'running:healthy:T1'
  deploy
  [ "$status" -eq 1 ]
  [[ $output == *"rolled back to reg.example/app:41: it exited with code 1"* ]]
  [ "$(cat "$MOCK_DIR/containers")" = 'app reg.example/app:41' ]
}

@test "a restart between checks counts as a failure" {
  health 'running:none:T2' 'running:none:T3' 'running:none:T1'
  deploy
  [ "$status" -eq 1 ]
  [[ $output == *"rolled back to reg.example/app:41: it keeps crashing, docker restarted it between checks"* ]]
}

@test "shell code in run-args doesn't run on the instance" {
  health 'running:healthy:T2'
  RUN_ARGS="--memory 256m; touch $MOCK_DIR/hacked" deploy
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_DIR/hacked" ]
  grep -qx '256m;' "$MOCK_DIR/run_args"
}

@test "a \$VAR in run-args stops the deploy" {
  RUN_ARGS='-e TOKEN=$TOKEN' run deploy
  [ "$status" -eq 1 ]
  [[ $output == *"unresolved variables in publish or run-args: TOKEN"* ]]
}

@test "old images are removed, the newest ones stay" {
  health 'running:healthy:T2'
  printf '%s\n' reg.example/app:39 reg.example/app:40 reg.example/app:41 reg.example/app:38-unknown >"$MOCK_DIR/images"
  KEEP_RELEASE=2 deploy
  [ "$status" -eq 0 ]
  [ "$(grep '^rmi ' "$MOCK_DIR/calls" | sort)" = "$(printf 'rmi %s\n' reg.example/app:38-unknown reg.example/app:39)" ]
}

@test "the SSM payload decodes back to the exact script, no escaping" {
  printf '%s\n' '#!/bin/sh' "echo 'single' \"double\" \\back \$HOME" >"$MOCK_DIR/script"
  run env AWS_REGION=x INSTANCE_ID=i IMAGE_REF=r/a:1 CONTAINER_NAME=app \
    bash -c '. "$1"; ssm_parameters "$2"' _ "$TOOL/deploy.sh" "$MOCK_DIR/script"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.commands | join("\n")' <<<"$output")" = "$(cat "$MOCK_DIR/script")" ]
}
