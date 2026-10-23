# ssm-deploy

Deploys one container to one EC2 instance through SSM Run Command. It checks that the new container is healthy and starts the old one again if it isn't. No SSH and no open ports.

- [`deploy.sh`](deploy.sh) runs in CI. It needs bash, the AWS CLI and jq.
- [`remote.sh`](remote.sh) runs on the instance. It's POSIX sh, so it also works with dash.

The [deploy-ec2 workflow](../../.github/workflows/deploy-ec2.yml) and the [GitLab template](../../gitlab/deploy-ec2.yml) only call `deploy.sh`.

## Why not Kamal, CodeDeploy or plain docker run

Kamal is the closest. Its proxy moves traffic to the new container only after the health check, so there is no downtime, and ssm-deploy can't do that. But Kamal needs SSH to the host, and you run it from the `kamal` CLI.

CodeDeploy needs its agent on the host, an `appspec.yml` with hook scripts in every app, and an application and a deployment group in AWS. That's a lot of setup for one container.

`docker run -d` over SSH is the simplest. But nothing checks the container after the start, and the job is green even if the container keeps restarting.

ssm-deploy uses what Amazon Linux 2023 already has, the SSM agent and the AWS CLI, plus Docker. It checks the container and rolls back by itself. It's for one container on one host. For several hosts behind a load balancer, use ECS or Kubernetes: [deploy-ecs](../../docs/deploy-ecs.md) or [render-gitops](../../docs/render-gitops.md).

## How it works

In CI, `deploy.sh`:

1. Checks the inputs. A `$VAR` or `$(...)` in `PUBLISH` or `RUN_ARGS` stops the deploy, because CI was supposed to put a value there.
2. Writes the values as single-quoted variables and adds `remote.sh` after them as it is. `RUN_ARGS` is split into words like `xargs` does, and every word is quoted, so nothing in it runs as shell code.
3. Turns the script into the JSON for `AWS-RunShellScript` with `jq`, sends it, waits and prints the output from CloudWatch Logs. If the deploy failed, the last line of the job is the instance's "Deploy failed:" line, with the cause.

On the instance, `remote.sh`:

1. Logs in to ECR with the instance role and pulls the image. If the pull fails, it stops there, and the running container is not touched.
2. Stops the running container and renames it to `<name>-previous`. If there is no running container but `<name>-previous` is left from a rollback that failed, that one is the rollback target.
3. Starts the new one and checks it several times in a row: healthy if the image has a HEALTHCHECK, running if it doesn't. If `StartedAt` changes between checks, the container restarted, and the check fails.
4. If the check passes, removes `<name>-previous` and old images. If not, prints the container logs, `docker inspect` and the events, removes the new container and starts `<name>-previous` under its old name.
5. A failed deploy ends with one line: what runs now and why the new version failed, for example `Deploy failed: web:42 rolled back to web:41: it exited with code 1`.

Containers are found by the exact name. An earlier version used `docker ps --filter name=api`, but this filter is a regular expression. So a deploy of `api` would also stop and remove `api-worker`.

## Usage

```bash
AWS_REGION=eu-central-1 INSTANCE_ID=i-0123456789abcdef0 CONTAINER_NAME=web \
IMAGE_REF=123456789012.dkr.ecr.eu-central-1.amazonaws.com/web:42 PUBLISH='-p 80:8080' \
tools/ssm-deploy/deploy.sh
```

Required: `AWS_REGION`, `INSTANCE_ID`, `CONTAINER_NAME` and `IMAGE_REF` (`registry/repository:tag`).

| Variable | Default | |
|---|---|---|
| `PUBLISH` | empty | ports, e.g. `-p 80:8080` |
| `RUN_ARGS` | empty | other `docker run` options, no secrets |
| `CONTAINER_ENV` | empty | `KEY=value` lines, passed as `-e` |
| `HEALTH_PASSES`, `HEALTH_INTERVAL` | `6`, `5` | good checks in a row, seconds between them |
| `KEEP_RELEASE`, `KEEP_BRANCH` | `5`, `3` | images to keep after a deploy |

The other variables (log rotation, log group, timeouts) and their defaults are at the top of [`deploy.sh`](deploy.sh).

`RUN_ARGS` never runs as shell code, but it's still `docker run` options, and docker runs as root. `--privileged` or `-v /:/host` give the container the whole host, so take these values only from the workflow file or protected CI variables.

Image cleanup follows the tag scheme of the [build template](../../docs/build.md). It keeps the newest builds of each kind, never keeps `-unknown` builds and doesn't touch other tags.

## What it needs in AWS

The CI role:

- `ssm:SendCommand` on the instance and the `AWS-RunShellScript` document;
- `ssm:GetCommandInvocation` and `ssm:CancelCommand`;
- `logs:CreateLogGroup`, `logs:PutRetentionPolicy`, `logs:DescribeLogStreams` and `logs:GetLogEvents` on the log group.

The instance role:

- `AmazonSSMManagedInstanceCore`;
- ECR pull;
- `logs:CreateLogStream` and `logs:PutLogEvents` on the log group, because the SSM agent writes the output with this role.

[`infra/`](../../infra) creates both.

`CONTAINER_ENV` goes into the SSM command parameters, so anyone who can read the SSM command history can read it. For real secrets, read them on the instance from Secrets Manager.

## Tests

```bash
bats tools/ssm-deploy/tests
```

Each test runs the whole deploy with dash and a fake `docker` from [mocks](tests/mocks), then checks which containers are left.
