# deploy-ec2

`.github/workflows/deploy-ec2.yml` runs the image from `build.env` on one EC2 instance with [ssm-deploy](../tools/ssm-deploy/README.md). The workflow reads `build.env`, assumes the role through OIDC and passes its inputs to the tool. What happens on the runner and on the instance, the comparison with Kamal, CodeDeploy and plain `docker run`, and the AWS permissions are described in the [ssm-deploy README](../tools/ssm-deploy/README.md).

Deploys of the same container are serialized with a `concurrency` group.

## Inputs

| Input | Default | Notes |
|---|---|---|
| `aws-region`, `aws-role-arn` | | required; the role may send SSM commands to the instance |
| `instance-id`, `container-name` | | required |
| `environment` | empty | GitHub environment of the job |
| `publish` | empty | e.g. `-p 80:8080` |
| `run-args` | empty | other `docker run` options; no secrets |
| `health-passes` | `6` | |
| `health-interval` | `5` | seconds |
| `prune` | `true` | |
| `keep-release`, `keep-branch` | `5`, `3` | |
| `log-group` | `/aws-delivery/ec2/<container-name>` | retention 14 days |
| `ssm-timeout` | `900` | seconds |
| `build-env-artifact` | `build-env` | |

`publish` and `run-args` are split into words like `xargs` does and are never run as shell code. They are still `docker run` options with root on the instance, so take them only from the workflow file or other places you trust.

Secret `container-env`: `KEY=value` lines, passed to the container as `-e` options. See the note on secrets in the [ssm-deploy README](../tools/ssm-deploy/README.md#what-it-needs-in-aws).

## What to check

- `aws ssm get-command-invocation` of a deploy shows the script with plain single-quoted values and no `\"` anywhere.
- With `run-args: --memory 256m; touch /tmp/x`, docker refuses the memory value `256m;`, and `/tmp/x` doesn't appear on the instance.
- With a wrong image tag, the pull fails and `docker ps` on the instance still shows the old container, up and untouched.
- With an image that exits at start, the job fails, and `docker ps` shows the previous image running under the original name.
- `docker images` on the instance after a few deploys keeps the expected number of builds and no `-unknown` ones.
