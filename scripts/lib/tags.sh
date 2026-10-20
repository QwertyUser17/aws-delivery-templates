# shellcheck shell=bash
# Image tag scheme shared by build and render-gitops. Sourced, never executed.
#
#   main, master   N            release builds
#   release/*      N-rc
#   hotfix/*       N-hotfix
#   bugfix/*       N-bugfix
#   feature/*      N-feature
#   dev*           N-dev
#   anything else  N-unknown    expires after a day in ECR, never kept on instances
#
# N is the build number of the pipeline. It only grows, so it orders builds.

# image_tag REF BUILD_NUMBER
image_tag() {
  local ref=$1 number=$2
  [[ $number =~ ^[0-9]+$ ]] || die "build number must be a positive integer, got '$number'"
  case $ref in
    main | master) printf '%s' "$number" ;;
    release/*) printf '%s-rc' "$number" ;;
    hotfix/*) printf '%s-hotfix' "$number" ;;
    bugfix/*) printf '%s-bugfix' "$number" ;;
    feature/*) printf '%s-feature' "$number" ;;
    dev*) printf '%s-dev' "$number" ;;
    *) printf '%s-unknown' "$number" ;;
  esac
}

# build_number_of TAG: the leading build number, or nothing for a tag outside the scheme.
build_number_of() {
  if [[ $1 =~ ^([0-9]+)(-(rc|hotfix|bugfix|feature|dev|unknown))?$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}
