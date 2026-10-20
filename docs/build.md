# build

`.github/workflows/build.yml` builds the image with buildx, pushes it to ECR and publishes `build.env` as an artifact for the next stages.

## What it does

1. Picks the tag from the branch:

   | Branch | Tag |
   |---|---|
   | `main`, `master` | `N` |
   | `release/*` | `N-rc` |
   | `hotfix/*` | `N-hotfix` |
   | `bugfix/*` | `N-bugfix` |
   | `feature/*` | `N-feature` |
   | `dev*` | `N-dev` |
   | anything else | `N-unknown` |

   `N` is `github.run_number`. It only grows, which is what lets render-gitops and the instance-side cleanup order builds.
2. Creates the ECR repository if it doesn't exist (scan on push, AES256).
3. Applies the lifecycle policy from a JSON file. The current and the desired policy are both canonicalized (sorted keys, rules by priority), and the policy is written only when they differ. The default is [`policies/ecr-lifecycle.json`](../policies/ecr-lifecycle.json), which matches the tag scheme above.
4. Builds and pushes with OCI labels: `org.opencontainers.image.version`, `revision`, `ref.name`, `created`, `source`, plus `ci.build-number`, `ci.run-id` and `ci.run-url`.
5. Writes `build.env`. Every value is single-quoted with `'` escaped as `'\''`, so `. build.env` restores it exactly in sh, dash and bash, whatever it contains.

## Inputs

| Input | Default | Notes |
|---|---|---|
| `aws-region` | | required |
| `aws-role-arn` | | required, role with ECR push rights |
| `ecr-repository` | caller's `owner/repo`, lower case | |
| `context` | `.` | |
| `dockerfile` | `Dockerfile` | |
| `platforms` | `linux/amd64` | comma-separated; QEMU is set up when there is more than one |
| `lifecycle-policy` | `policies/ecr-lifecycle.json` of this repository | path in the caller repository |
| `build-env-artifact` | `build-env` | |

Outputs: `image-ref`, `image-tag`, `image-digest`.

## build.env

```sh
IMAGE_REF='123456789012.dkr.ecr.eu-central-1.amazonaws.com/web:42'
IMAGE_REPOSITORY='123456789012.dkr.ecr.eu-central-1.amazonaws.com/web'
IMAGE_TAG='42'
IMAGE_DIGEST='sha256:...'
BUILD_NUMBER='42'
GIT_SHA='...'
GIT_REF='main'
RUN_ID='...'
RUN_URL='https://github.com/org/web/actions/runs/...'
SOURCE_URL='https://github.com/org/web'
```

## What to check

- The caller grants `id-token: write`, otherwise the role can't be assumed.
- A second run of the same pipeline doesn't rewrite the lifecycle policy: the log says it is up to date.
- `docker inspect` of the pushed image shows the labels with the right run URL.
