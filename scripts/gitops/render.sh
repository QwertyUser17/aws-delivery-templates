#!/usr/bin/env bash
# Deploys to Kubernetes the GitOps way: CI never talks to the cluster, it changes
# the image in the GitOps repository and Argo CD (or Flux) does the rest.
#
# Target types:
#   kustomize-patch   a patch (or any manifests) with image: fields in pod templates
#   helm-values       a values file with image: strings or {repository, tag} maps
set -Eeuo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
. "$here/../lib/common.sh"
# shellcheck source=../lib/tags.sh
. "$here/../lib/tags.sh"

require GITOPS_REPO GITOPS_FILE TARGET_TYPE IMAGE_REPOSITORY IMAGE_TAG BUILD_NUMBER RUN_ID RUN_URL GIT_SHA
: "${GITOPS_BRANCH:=main}"
: "${ALLOW_ROLLBACK:=false}"
: "${ANNOTATIONS_PATH:=.podAnnotations}"
: "${IMAGE_DIGEST:=}"
: "${SOURCE_URL:=}"
: "${SSH_PRIVATE_KEY:=}"
: "${SSH_KNOWN_HOSTS:=}"
: "${COMMIT_AUTHOR_NAME:=github-actions[bot]}"
: "${COMMIT_AUTHOR_EMAIL:=41898282+github-actions[bot]@users.noreply.github.com}"
: "${MAX_ATTEMPTS:=5}"

case $TARGET_TYPE in
  kustomize-patch | helm-values) ;;
  *) die "target-type must be kustomize-patch or helm-values, got '$TARGET_TYPE'" ;;
esac
[[ $ANNOTATIONS_PATH =~ ^(\.[A-Za-z0-9_-]+)+$ ]] || die "annotations-path must be a plain path like .podAnnotations, got '$ANNOTATIONS_PATH'"

# Provenance annotations. Fixed names, written into the yq expressions as literals.
KEY_RUN_ID='"aws-delivery-templates/run-id"'
KEY_RUN_URL='"aws-delivery-templates/run-url"'
KEY_COMMIT='"aws-delivery-templates/commit"'
IMAGE_NAME=${IMAGE_REPOSITORY##*/}
NEW_REF="$IMAGE_REPOSITORY:$IMAGE_TAG${IMAGE_DIGEST:+@$IMAGE_DIGEST}"

# The repository name goes into a regex, so its dots and other specials are escaped.
REPO_RE="^$(sed 's/[][\.^$*+?(){}|/]/\\&/g' <<<"$IMAGE_REPOSITORY")(:|@|\$)"
export REPO_RE IMAGE_REPOSITORY IMAGE_TAG IMAGE_DIGEST NEW_REF RUN_ID RUN_URL ANNOTATIONS_PATH
GIT_SHORT_SHA=${GIT_SHA:0:12}
export GIT_SHORT_SHA

# yq selectors. A pod template is any map with spec.containers; only templates that
# run this repository's image get the provenance annotations.
IMAGES='.. | select(tag == "!!str") | select(key == "image")'
OURS="$IMAGES | select(test(strenv(REPO_RE)))"
PODS='.. | select(tag == "!!map") | select(has("spec")) | select(.spec | tag == "!!map") | select(.spec | has("containers")) | select([.spec.containers[] | .image // ""] | any_c(test(strenv(REPO_RE))))'
HELM_MAPS='.. | select(tag == "!!map") | select(.repository == strenv(IMAGE_REPOSITORY)) | select(has("tag"))'

# --- reading the target file ---------------------------------------------------

# Every image reference in the file, for the race check after a rejected push.
fingerprint() {
  yq ea "$IMAGES" "$GITOPS_FILE" | sort | git hash-object --stdin
}

match_count() {
  case $TARGET_TYPE in
    kustomize-patch) yq ea "[$OURS] | length" "$GITOPS_FILE" ;;
    helm-values) yq ea "[$OURS] + [$HELM_MAPS] | length" "$GITOPS_FILE" ;;
  esac | awk '{ total += $1 } END { print total + 0 }'
}

current_run_id() {
  case $TARGET_TYPE in
    kustomize-patch) yq ea "$PODS | .metadata.annotations.$KEY_RUN_ID // \"\"" "$GITOPS_FILE" ;;
    helm-values) yq "$ANNOTATIONS_PATH.$KEY_RUN_ID // \"\"" "$GITOPS_FILE" ;;
  esac | grep -E '^[0-9]+$' | sort -n | tail -1 || true
}

current_tag() {
  local ref
  ref=$(yq ea "$OURS" "$GITOPS_FILE" | head -1)
  if [[ -z $ref && $TARGET_TYPE == helm-values ]]; then
    yq ea "$HELM_MAPS | .tag" "$GITOPS_FILE" | head -1
    return
  fi
  ref=${ref%@*}
  ref=${ref##*/}
  [[ $ref != *:* ]] || printf '%s' "${ref##*:}"
}

# --- the change ----------------------------------------------------------------

# Deterministic: run twice on the same file, it gives the same result. That is what
# makes the retry after a rejected push safe.
apply_change() {
  local annotations
  case $TARGET_TYPE in
    kustomize-patch)
      annotations="($PODS | .metadata.annotations)"
      yq -i "
        $annotations.$KEY_RUN_ID = strenv(RUN_ID)
        | $annotations.$KEY_RUN_URL = strenv(RUN_URL)
        | $annotations.$KEY_COMMIT = strenv(GIT_SHORT_SHA)
        | ${annotations}[] style=\"double\"
        | ($OURS) = strenv(NEW_REF)
      " "$GITOPS_FILE"
      ;;
    helm-values)
      yq -i "
        ($OURS) = strenv(NEW_REF)
        | ($HELM_MAPS | .tag) = strenv(IMAGE_TAG)
        | $ANNOTATIONS_PATH.$KEY_RUN_ID = strenv(RUN_ID)
        | $ANNOTATIONS_PATH.$KEY_RUN_URL = strenv(RUN_URL)
        | $ANNOTATIONS_PATH.$KEY_COMMIT = strenv(GIT_SHORT_SHA)
        | ${ANNOTATIONS_PATH}[] style=\"double\"
      " "$GITOPS_FILE"
      ;;
  esac
}

# --- out-of-order protection ---------------------------------------------------

# Pipelines don't finish in the order they started. A slow older pipeline must not
# overwrite what a newer one already deployed. Both the run ID in the annotations
# and the build number in the tag only grow, so either one decides.
newer_deploy() {
  local run tag number
  run=$(current_run_id)
  tag=$(current_tag)
  number=$(build_number_of "$tag")
  if [[ -n $run ]] && ((run > RUN_ID)); then
    printf 'run %s' "$run"
  elif [[ -n $number ]] && ((number > BUILD_NUMBER)); then
    printf 'build %s (tag %s)' "$number" "$tag"
  fi
}

guard() {
  local newer
  newer=$(newer_deploy)
  [[ -n $newer ]] || return 0
  if [[ $ALLOW_ROLLBACK == true ]]; then
    warn_loud "DEPLOYING AN OLDER BUILD" \
      "$GITOPS_FILE already has $newer, newer than build $BUILD_NUMBER (run $RUN_ID)." \
      "allow-rollback is true, so this older build replaces it."
    return 0
  fi
  note "Skipped: $GITOPS_FILE already has $newer, newer than this build $BUILD_NUMBER (run $RUN_ID)."
  note "This pipeline finished after a newer one, and an older image must not replace a newer one."
  note "To deploy this build on purpose, run the job again with allow-rollback set to true."
  exit 0
}

can_compare() {
  [[ -n $(current_run_id) || -n $(build_number_of "$(current_tag)") ]]
}

# --- git -----------------------------------------------------------------------

setup_ssh() {
  local rest host port dir
  case $GITOPS_REPO in
    ssh://*)
      rest=${GITOPS_REPO#ssh://}
      rest=${rest%%/*}
      ;;
    *@*:*) rest=${GITOPS_REPO%%:*} ;;
    *) die "gitops-repository must be an SSH URL like git@host:org/repo.git or ssh://git@host:2222/org/repo.git" ;;
  esac
  rest=${rest#*@}
  host=${rest%%:*}
  port=22
  [[ $rest != *:* ]] || port=${rest##*:}

  require SSH_PRIVATE_KEY
  dir=$(mktemp -d)
  printf '%s\n' "$SSH_PRIVATE_KEY" >"$dir/key"
  chmod 600 "$dir/key"
  if [[ -n $SSH_KNOWN_HOSTS ]]; then
    printf '%s\n' "$SSH_KNOWN_HOSTS" >"$dir/known_hosts"
  else
    ssh-keyscan -p "$port" "$host" >"$dir/known_hosts" 2>/dev/null || true
    [[ -s $dir/known_hosts ]] || die "could not read the SSH host key of $host:$port; is the host reachable from the runner?"
  fi
  export GIT_SSH_COMMAND="ssh -i $dir/key -o IdentitiesOnly=yes -o UserKnownHostsFile=$dir/known_hosts -o StrictHostKeyChecking=yes"
}

commit_change() {
  local source_line="${SOURCE_URL:+$SOURCE_URL/commit/}$GIT_SHA"
  git add -- "$GITOPS_FILE"
  git -c user.name="$COMMIT_AUTHOR_NAME" -c user.email="$COMMIT_AUTHOR_EMAIL" \
    commit --quiet --file - <<EOF
Deploy $IMAGE_NAME $IMAGE_TAG

Image:  $NEW_REF
Source: $source_line
Run:    $RUN_URL
File:   $GITOPS_FILE
EOF
}

up_to_date() {
  note "Nothing to change: $GITOPS_FILE already points at $IMAGE_NAME $IMAGE_TAG from run $RUN_ID."
  note "Running this job again changes nothing. To restart the pods, restart the workload in"
  note "the cluster (kubectl rollout restart, or the Restart action in Argo CD)."
  exit 0
}

check_target() {
  [[ -f $GITOPS_FILE ]] || die "$GITOPS_FILE not found in $GITOPS_REPO@$GITOPS_BRANCH"
  if [[ $(match_count) -eq 0 ]]; then
    note "No image of $IMAGE_REPOSITORY in $GITOPS_FILE. Images found there:"
    yq ea "$IMAGES | \"  \" + ." "$GITOPS_FILE" >&2
    die "nothing to update. Check image-repository and gitops-file."
  fi
}

commit_and_push() {
  local attempt base_fp
  for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
    check_target
    base_fp=$(fingerprint)
    guard
    apply_change
    git diff --quiet -- "$GITOPS_FILE" && up_to_date
    commit_change
    if git push --quiet origin "HEAD:$GITOPS_BRANCH"; then
      note "Pushed $(git rev-parse --short HEAD) to $GITOPS_BRANCH: $IMAGE_NAME $IMAGE_TAG"
      return 0
    fi

    # Someone pushed first. Reset to the new head (no rebase: it works on a shallow
    # clone and never leaves a half-done rebase behind) and redo the change.
    note "Push rejected, $GITOPS_BRANCH moved. Attempt $attempt of $MAX_ATTEMPTS."
    git fetch --quiet --depth 1 origin "$GITOPS_BRANCH"
    git reset --quiet --hard FETCH_HEAD
    if [[ $(fingerprint) != "$base_fp" ]] && ! can_compare; then
      note "Another pipeline changed the images in $GITOPS_FILE, and the new state has neither"
      note "a run ID annotation nor a numbered tag for $IMAGE_REPOSITORY, so the order cannot be checked."
      note "Images in the file now:"
      yq ea "$IMAGES" "$GITOPS_FILE" >&2 || true
      die "stopped to avoid replacing a deploy that may be newer"
    fi
    sleep $((attempt * 3))
  done
  die "could not push after $MAX_ATTEMPTS attempts"
}

main() {
  setup_ssh
  local workdir
  workdir=$(mktemp -d)
  git clone --quiet --depth 1 --branch "$GITOPS_BRANCH" "$GITOPS_REPO" "$workdir"
  cd "$workdir"
  commit_and_push
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
