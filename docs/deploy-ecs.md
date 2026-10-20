# deploy-ecs

`.github/workflows/deploy-ecs.yml` rolls an ECS service to the image from `build.env`. Logic: [`scripts/ecs/deploy.sh`](../scripts/ecs/deploy.sh).

## What it does

1. Reads the task definition the service runs now. It is not the latest revision of the family: after a failed deploy, the latest revision is the one that failed.
2. Registers a new revision with the image of `container-name` replaced. It keeps the tags and drops the read-only fields. If no container has that name, it stops before registering anything and lists the containers there are.
3. `update-service` to the new revision.
4. Waits with `aws ecs wait services-stable` in a loop until `wait-timeout`. The CLI waiter gives up after 10 minutes on its own, and a slow service may need more. It stops early if the service is gone or draining.
5. If the service is not stable in time, it prints the last service events, goes back to the previous revision and waits up to `rollback-timeout`. The job fails, and the output `rolled-back` is `true`.

Deploys of the same service are serialized with a `concurrency` group.

## Rollback in the pipeline or the deployment circuit breaker

ECS can roll back by itself: the [deployment circuit breaker](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/deployment-circuit-breaker.html) with `rollback: true` stops a deployment whose tasks keep failing to start or failing their health checks, and returns to the last completed one.

The circuit breaker is enough when:

- a broken release shows up as tasks that fail to start or fail ELB or container health checks;
- you don't need the pipeline itself to fail at a known time;
- one rollback rule for all services is fine.

The rollback here is useful when:

- the time limit matters more than the failure count: a service that is "in progress" for 40 minutes is a failed deploy for you;
- the pipeline must report clearly that this deploy failed and was rolled back, for the notification and for the next stage;
- you want both. They work together: turn on the circuit breaker, and keep this as the outer time limit.

## Inputs

| Input | Default |
|---|---|
| `aws-region`, `aws-role-arn` | required |
| `cluster`, `service`, `container-name` | required |
| `environment` | empty |
| `wait-timeout` | `1200` seconds |
| `rollback-timeout` | `600` seconds |

## What to check

- With an image that crashes on start, the job fails after `wait-timeout`, and the service runs the previous revision again.
- After a failed deploy, the next deploy builds its revision from the running one, not from the failed one.
