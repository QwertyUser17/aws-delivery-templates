#!/usr/bin/env bash
# Builds the image, pushes it to ECR and writes build.env for the scan, deploy and
# render-gitops stages.
#
# Expects a logged-in docker with buildx, and AWS credentials for ECR.
set -Eeuo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
. "$here/../lib/common.sh"
# shellcheck source=../lib/tags.sh
. "$here/../lib/tags.sh"

require AWS_REGION ECR_REGISTRY ECR_REPOSITORY REF_NAME BUILD_NUMBER GIT_SHA RUN_ID RUN_URL
: "${BUILD_CONTEXT:=.}"
: "${DOCKERFILE:=Dockerfile}"
: "${PLATFORMS:=linux/amd64}"
: "${LIFECYCLE_POLICY_FILE:=$here/../../policies/ecr-lifecycle.json}"
: "${SOURCE_URL:=}"
: "${JOB_URL:=}"
: "${BUILD_ENV_FILE:=build.env}"
# Repository names in registries are lower case; GitHub owners often are not.
ECR_REPOSITORY=${ECR_REPOSITORY,,}

ecr() {
  aws ecr "$@" --region "$AWS_REGION"
}

ensure_repository() {
  local err
  err=$(mktemp)
  if ecr describe-repositories --repository-names "$ECR_REPOSITORY" >/dev/null 2>"$err"; then
    rm -f "$err"
    return
  fi
  if ! grep -q RepositoryNotFoundException "$err"; then
    cat "$err" >&2
    rm -f "$err"
    die "could not look up ECR repository $ECR_REPOSITORY"
  fi
  rm -f "$err"
  note "ECR repository $ECR_REPOSITORY does not exist, creating it"
  ecr create-repository \
    --repository-name "$ECR_REPOSITORY" \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256 >/dev/null
}

# The policy file is the source of truth. Both sides are canonicalized (sorted keys,
# rules by priority, no whitespace), so only a real difference leads to a write.
apply_lifecycle_policy() {
  local canonical='.rules |= sort_by(.rulePriority)' desired current err
  [[ -f $LIFECYCLE_POLICY_FILE ]] || die "lifecycle policy file not found: $LIFECYCLE_POLICY_FILE"
  desired=$(jq -cS "$canonical" "$LIFECYCLE_POLICY_FILE") || die "lifecycle policy is not valid JSON: $LIFECYCLE_POLICY_FILE"

  err=$(mktemp)
  if current=$(ecr get-lifecycle-policy --repository-name "$ECR_REPOSITORY" \
    --query lifecyclePolicyText --output text 2>"$err"); then
    current=$(printf '%s' "$current" | jq -cS "$canonical")
  elif grep -q LifecyclePolicyNotFoundException "$err"; then
    current=''
  else
    cat "$err" >&2
    rm -f "$err"
    die "could not read the lifecycle policy of $ECR_REPOSITORY"
  fi
  rm -f "$err"

  if [[ $current == "$desired" ]]; then
    note "Lifecycle policy is up to date"
    return
  fi
  if [[ -z $current ]]; then
    note "Lifecycle policy is missing, applying $LIFECYCLE_POLICY_FILE"
  else
    note "Lifecycle policy differs from $LIFECYCLE_POLICY_FILE, updating"
  fi
  ecr put-lifecycle-policy --repository-name "$ECR_REPOSITORY" \
    --lifecycle-policy-text "$desired" >/dev/null
}

main() {
  local tag image metadata digest created
  tag=$(image_tag "$REF_NAME" "$BUILD_NUMBER")
  image="$ECR_REGISTRY/$ECR_REPOSITORY:$tag"
  created=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  ensure_repository
  apply_lifecycle_policy

  local labels=(
    --label "org.opencontainers.image.version=$tag"
    --label "org.opencontainers.image.revision=$GIT_SHA"
    --label "org.opencontainers.image.ref.name=$REF_NAME"
    --label "org.opencontainers.image.created=$created"
    --label "ci.build-number=$BUILD_NUMBER"
    --label "ci.run-id=$RUN_ID"
    --label "ci.run-url=$RUN_URL"
  )
  [[ -z $SOURCE_URL ]] || labels+=(--label "org.opencontainers.image.source=$SOURCE_URL")
  [[ -z $JOB_URL ]] || labels+=(--label "ci.job-url=$JOB_URL")

  note "Building $image for $PLATFORMS"
  metadata=$(mktemp)
  docker buildx build \
    --file "$DOCKERFILE" \
    --platform "$PLATFORMS" \
    --pull \
    --push \
    --tag "$image" \
    "${labels[@]}" \
    --metadata-file "$metadata" \
    "$BUILD_CONTEXT"
  digest=$(jq -r '."containerimage.digest" // empty' "$metadata")
  rm -f "$metadata"
  [[ $digest == sha256:* ]] || die "buildx did not report the digest of $image"
  note "Pushed $image@$digest"

  {
    env_line IMAGE_REF "$image"
    env_line IMAGE_REPOSITORY "$ECR_REGISTRY/$ECR_REPOSITORY"
    env_line IMAGE_TAG "$tag"
    env_line IMAGE_DIGEST "$digest"
    env_line BUILD_NUMBER "$BUILD_NUMBER"
    env_line GIT_SHA "$GIT_SHA"
    env_line GIT_REF "$REF_NAME"
    env_line RUN_ID "$RUN_ID"
    env_line RUN_URL "$RUN_URL"
    env_line SOURCE_URL "$SOURCE_URL"
  } >"$BUILD_ENV_FILE"

  set_output image-ref "$image"
  set_output image-tag "$tag"
  set_output image-digest "$digest"
}

main "$@"
