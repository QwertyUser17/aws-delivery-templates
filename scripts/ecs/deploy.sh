#!/usr/bin/env bash
# Registers a task definition revision with the new image, rolls the service to it
# and waits until the service is stable. If it doesn't get there in time, the
# service goes back to the revision it ran before and the job fails.
set -Eeuo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
. "$here/../lib/common.sh"

require AWS_REGION ECS_CLUSTER ECS_SERVICE CONTAINER_NAME IMAGE_REF
: "${WAIT_TIMEOUT:=1200}"
: "${ROLLBACK_TIMEOUT:=600}"

ecs() {
  aws ecs "$@" --cluster "$ECS_CLUSTER" --region "$AWS_REGION"
}

# new_task_definition CURRENT_ARN OUT_FILE: the current revision with the image of
# one container replaced and the fields that register-task-definition rejects removed.
new_task_definition() {
  local described
  described=$(aws ecs describe-task-definition --task-definition "$1" --include TAGS --region "$AWS_REGION")
  if ! jq -e --arg name "$CONTAINER_NAME" '.taskDefinition.containerDefinitions | any(.name == $name)' <<<"$described" >/dev/null; then
    note "Containers in $1:"
    jq -r '.taskDefinition.containerDefinitions[] | "  \(.name)  \(.image)"' <<<"$described" >&2
    die "no container named $CONTAINER_NAME in $1, nothing was registered"
  fi
  jq --arg name "$CONTAINER_NAME" --arg image "$IMAGE_REF" '
    (.tags // []) as $tags
    | .taskDefinition
    | del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities,
          .registeredAt, .registeredBy, .deregisteredAt, .deleteRequestedAt)
    | .containerDefinitions |= map(if .name == $name then .image = $image else . end)
    | if ($tags | length) > 0 then .tags = $tags else . end
  ' <<<"$described" >"$2"
}

# wait_stable TIMEOUT: the CLI waiter gives up after 10 minutes on its own, so it
# runs in a loop until the overall deadline. A service that is gone or draining
# can never become stable, and the waiter fails on it straight away.
wait_stable() {
  local deadline=$((SECONDS + $1)) left status
  while :; do
    left=$((deadline - SECONDS))
    ((left > 0)) || return 1
    if timeout "$left" aws ecs wait services-stable --cluster "$ECS_CLUSTER" \
      --services "$ECS_SERVICE" --region "$AWS_REGION" 2>/dev/null; then
      return 0
    fi
    status=$(ecs describe-services --services "$ECS_SERVICE" --query 'services[0].status' --output text 2>/dev/null || true)
    [[ $status == ACTIVE ]] || {
      note "Service $ECS_SERVICE is ${status:-missing}, it will not become stable"
      return 1
    }
  done
}

recent_events() {
  ecs describe-services --services "$ECS_SERVICE" \
    --query 'services[0].events[:8].[createdAt,message]' --output text >&2 || true
}

main() {
  local current new_file new_arn
  current=$(ecs describe-services --services "$ECS_SERVICE" --query 'services[0].taskDefinition' --output text)
  [[ $current == arn:* ]] || die "service $ECS_SERVICE not found in cluster $ECS_CLUSTER"
  note "Service $ECS_SERVICE runs $current"

  # Based on what the service runs, not on the latest revision of the family:
  # after a failed deploy, the latest revision is the one that failed.
  new_file=$(mktemp)
  new_task_definition "$current" "$new_file"
  new_arn=$(aws ecs register-task-definition --cli-input-json "file://$new_file" \
    --region "$AWS_REGION" --query taskDefinition.taskDefinitionArn --output text)
  rm -f "$new_file"
  note "Registered $new_arn with $IMAGE_REF"

  ecs update-service --service "$ECS_SERVICE" --task-definition "$new_arn" >/dev/null
  note "Waiting up to ${WAIT_TIMEOUT}s for $ECS_SERVICE to become stable"
  if wait_stable "$WAIT_TIMEOUT"; then
    note "Deployed $IMAGE_REF to $ECS_SERVICE"
    set_output rolled-back false
    return 0
  fi

  note "$ECS_SERVICE did not become stable on $new_arn. Recent service events:"
  recent_events
  note "Rolling back to $current"
  ecs update-service --service "$ECS_SERVICE" --task-definition "$current" >/dev/null
  set_output rolled-back true
  if wait_stable "$ROLLBACK_TIMEOUT"; then
    die "deploy of $IMAGE_REF failed, $ECS_SERVICE is back on $current"
  fi
  die "deploy of $IMAGE_REF failed and the rollback to $current is not stable either"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
