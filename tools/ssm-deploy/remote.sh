#!/bin/sh
# ssm-deploy, instance side. POSIX sh: the instance may run it with dash.
#
# deploy.sh sends this file through SSM with the values prepended as single-quoted
# assignments. With SSM_DEPLOY_LIB=1 it only defines the functions, for the tests.
# Every docker call goes through dk, so the tests can replace docker.
# shellcheck disable=SC2154 # the values are assigned by the prepended block

dk() {
  docker "$@"
}

section() {
  printf '\n==> %s\n' "$1"
}

# container_exists NAME: exact name match. docker's name filter is a substring regex.
container_exists() {
  dk ps -a --format '{{.Names}}' | grep -Fqx -- "$1"
}

# registry_login REGISTRY REGION: logs in with the instance role into a private
# config dir, so the job leaves no credentials in root's ~/.docker. The caller
# owns the cleanup (see registry_logout).
registry_login() {
  DOCKER_CONFIG=$(mktemp -d)
  export DOCKER_CONFIG
  _password=$(aws ecr get-login-password --region "$2") || return 1
  _log=$(mktemp)
  if printf '%s\n' "$_password" | dk login --username AWS --password-stdin "$1" >"$_log" 2>&1; then
    _rc=0
  else
    _rc=$?
  fi
  unset _password
  grep -v -e 'credentials are stored unencrypted' -e 'credential helper' -e 'credential-store' "$_log" || true
  rm -f "$_log"
  return "$_rc"
}

registry_logout() {
  if [ -n "${DOCKER_CONFIG:-}" ] && [ -d "$DOCKER_CONFIG" ]; then
    dk logout "$1" >/dev/null 2>&1 || true
    rm -rf "$DOCKER_CONFIG"
  fi
}

# pull_image REF: pull without the per-layer progress lines.
pull_image() {
  _log=$(mktemp)
  if dk pull "$1" >"$_log" 2>&1; then
    _rc=0
  else
    _rc=$?
  fi
  grep -Ev '^[0-9a-f]{12}: (Pulling fs layer|Waiting|Downloading|Verifying Checksum|Download complete|Extracting|Pull complete|Already exists)' "$_log" || true
  rm -f "$_log"
  return "$_rc"
}

dump_diagnostics() {
  echo '--- docker ps'
  dk ps -a --filter "name=$1" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' || true
  echo '--- docker inspect'
  dk inspect --format 'Status={{.State.Status}} ExitCode={{.State.ExitCode}} OOMKilled={{.State.OOMKilled}} Error={{.State.Error}} StartedAt={{.State.StartedAt}} FinishedAt={{.State.FinishedAt}} RestartCount={{.RestartCount}}' "$1" || true
  echo '--- docker logs, last 50 lines'
  dk logs --tail 50 "$1" 2>&1 || true
  echo '--- docker events, last 2 minutes'
  _now=$(date +%s)
  dk events --since "$((_now - 120))" --until "$_now" --filter "container=$1" || true
}

# health_gate NAME PASSES INTERVAL MAX_CHECKS
#
# Healthy means PASSES checks in a row where the container is running and its
# healthcheck reports healthy, or it is just running when the image has no
# healthcheck. A changed StartedAt means docker restarted it between checks,
# which fails the gate even if it looks fine at the moment of the check.
health_gate() {
  _name=$1 _need=$2 _interval=$3 _max=$4
  _passes=0 _checks=0 _started='' _reason=''
  while [ "$_checks" -lt "$_max" ]; do
    _checks=$((_checks + 1))
    _state=$(dk inspect --format '{{.State.Status}}:{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}:{{.State.StartedAt}}' "$_name" 2>/dev/null) || _state='missing:none:'
    _status=${_state%%:*}
    _rest=${_state#*:}
    _health=${_rest%%:*}
    _now_started=${_rest#*:}

    if [ -n "$_started" ] && [ "$_now_started" != "$_started" ]; then
      _reason="restarted between checks (StartedAt $_started -> $_now_started)"
      break
    fi
    _started=$_now_started

    case "$_status:$_health" in
      running:healthy | running:none)
        _passes=$((_passes + 1))
        echo "check $_checks: $_status, health $_health ($_passes/$_need in a row)"
        if [ "$_passes" -ge "$_need" ]; then
          return 0
        fi
        ;;
      running:starting)
        _passes=0
        echo "check $_checks: running, healthcheck still starting"
        ;;
      *)
        _reason="status $_status, health $_health"
        break
        ;;
    esac
    sleep "$_interval"
  done

  echo "Health gate failed for $_name: ${_reason:-not stable after $_max checks}"
  dump_diagnostics "$_name"
  return 1
}

# prune_images REPOSITORY KEEP_RELEASE KEEP_BRANCH
#
# Release builds (N) and branch builds (N-rc, N-hotfix, N-bugfix, N-feature, N-dev)
# are kept by build number, newest first. N-unknown builds are never kept. Tags
# outside the scheme are left alone. docker refuses to remove an image that a
# container still uses, the rollback container included, and that is fine.
prune_images() {
  dk images --format '{{.Repository}}:{{.Tag}}' "$1" |
    awk '
      { tag = $0; sub(/.*:/, "", tag); n = tag; sub(/-.*/, "", n) }
      tag ~ /^[0-9]+$/ { print "release", n, $0; next }
      tag ~ /^[0-9]+-(rc|hotfix|bugfix|feature|dev)$/ { print "branch", n, $0; next }
      tag ~ /^[0-9]+-unknown$/ { print "unknown", n, $0 }
    ' |
    sort -k1,1 -k2,2nr |
    awk -v keep_release="$2" -v keep_branch="$3" '
      { seen[$1]++ }
      $1 == "unknown" { print $3; next }
      $1 == "release" && seen[$1] > keep_release { print $3; next }
      $1 == "branch" && seen[$1] > keep_branch { print $3 }
    ' |
    while IFS= read -r _ref; do
      if dk rmi "$_ref" >/dev/null 2>&1; then
        echo "removed $_ref"
      else
        echo "kept $_ref: still used by a container"
      fi
    done
}

main() {
  exec 2>&1
  trap 'registry_logout "$REGISTRY"' EXIT
  trap 'exit 130' INT TERM

  previous="$CONTAINER_NAME-previous"

  section "Log in to $REGISTRY"
  if ! registry_login "$REGISTRY" "$AWS_REGION"; then
    echo "Login failed. The running container was not touched."
    exit 1
  fi

  section "Pull $IMAGE_REF"
  if ! pull_image "$IMAGE_REF"; then
    echo "Pull failed. The running container was not touched."
    exit 1
  fi

  # The old container is stopped and renamed, not removed: if the new one fails the
  # health gate, it comes back exactly as it was, with its own image, env and ports.
  had_previous=false
  if container_exists "$CONTAINER_NAME"; then
    section "Stop $CONTAINER_NAME and keep it as $previous"
    if container_exists "$previous"; then
      dk rm -f "$previous" >/dev/null
    fi
    dk stop "$CONTAINER_NAME" >/dev/null
    if ! dk rename "$CONTAINER_NAME" "$previous"; then
      dk start "$CONTAINER_NAME" >/dev/null
      echo "Could not rename $CONTAINER_NAME, started it again. Nothing was deployed."
      exit 1
    fi
    had_previous=true
  fi

  section "Start $CONTAINER_NAME from $IMAGE_REF"
  # deploy.sh sends both as single-quoted words, so eval only takes the quotes off.
  eval "set -- $PUBLISH $RUN_ARGS"
  if dk run --detach \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --log-driver json-file \
    --log-opt "max-size=$LOG_MAX_SIZE" \
    --log-opt "max-file=$LOG_MAX_FILES" \
    "$@" \
    "$IMAGE_REF" >/dev/null &&
    health_gate "$CONTAINER_NAME" "$HEALTH_PASSES" "$HEALTH_INTERVAL" "$HEALTH_MAX_CHECKS"; then
    section "$CONTAINER_NAME is healthy on $IMAGE_REF"
    if [ "$had_previous" = true ]; then
      dk rm "$previous" >/dev/null || echo "Could not remove $previous, remove it by hand."
    fi
    if [ "$PRUNE" = true ]; then
      section "Prune old images of ${IMAGE_REF%:*}"
      prune_images "${IMAGE_REF%:*}" "$KEEP_RELEASE" "$KEEP_BRANCH"
    fi
    exit 0
  fi

  section "Roll back"
  dk rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  if [ "$had_previous" != true ]; then
    echo "There was no previous container, nothing to roll back to."
    exit 1
  fi
  if ! dk rename "$previous" "$CONTAINER_NAME" || ! dk start "$CONTAINER_NAME" >/dev/null; then
    echo "Could not bring back the previous container. Check the instance: docker ps -a"
    exit 1
  fi
  rollback_image=$(dk inspect --format '{{.Config.Image}}' "$CONTAINER_NAME")
  if health_gate "$CONTAINER_NAME" "$HEALTH_PASSES" "$HEALTH_INTERVAL" "$HEALTH_MAX_CHECKS"; then
    echo "Rolled back: $CONTAINER_NAME runs $rollback_image again. The deploy of $IMAGE_REF failed."
  else
    echo "Rolled back to $rollback_image, but it is not healthy either. Check the instance."
  fi
  exit 1
}

if [ "${SSM_DEPLOY_LIB:-}" != 1 ]; then
  main "$@"
fi
