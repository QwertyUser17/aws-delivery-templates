# scan

`.github/workflows/scan.yml` has two jobs that run in parallel after build.

- **hadolint** lints the Dockerfile. The job fails at `hadolint-threshold` or above. The JSON report is the `hadolint-report` artifact.
- **Trivy** scans the image from `build.env` by digest, straight from ECR. The report has the `report-severity` levels. The job fails if the report has any vulnerability of a `fail-on-severity` level. The gate reads the same JSON report that is printed as a table, so the log and the decision always agree. Reports are in the `trivy-report` artifact (`trivy.json`, `trivy.txt`).

## Inputs

| Input | Default |
|---|---|
| `aws-region`, `aws-role-arn` | required; the role needs ECR pull rights |
| `dockerfile` | `Dockerfile` |
| `hadolint-threshold` | `error` |
| `fail-on-severity` | `CRITICAL` |
| `report-severity` | `MEDIUM,HIGH,CRITICAL` |
| `ignore-unfixed` | `true` |
| `build-env-artifact` | `build-env` |

## What to check

- A Dockerfile with `FROM ...:latest` fails hadolint with `hadolint-threshold: warning`.
- An old base image fails Trivy, and the table in the log shows the same CVEs as `trivy.json`.
