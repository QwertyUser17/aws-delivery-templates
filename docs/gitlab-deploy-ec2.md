# deploy-ec2 on GitLab CI

[`gitlab/deploy-ec2.yml`](../gitlab/deploy-ec2.yml) has one hidden job, `.aws-deploy-ec2`. It downloads this repository at `DELIVERY_TEMPLATES_REF` and runs [ssm-deploy](../tools/ssm-deploy/README.md), the same tool the GitHub workflow runs, so the deploy logic doesn't depend on the CI system. The template only passes variables; what the tool does is described in its README.

## AWS access

The job uses GitLab OIDC: `id_tokens` gives it a token, and `aws sts assume-role-with-web-identity` exchanges it for credentials of `AWS_ROLE_ARN`. No AWS keys are stored in GitLab. The role's trust policy allows the GitLab OIDC provider of your instance, limited to the project:

```json
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::123456789012:oidc-provider/gitlab.example.com" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": { "gitlab.example.com:aud": "sts.amazonaws.com" },
    "StringLike": { "gitlab.example.com:sub": "project_path:group/web:ref_type:branch:ref:main" }
  }
}
```

## Variables

| Variable | Notes |
|---|---|
| `AWS_ROLE_ARN`, `AWS_REGION` | required |
| `INSTANCE_ID`, `CONTAINER_NAME` | required |
| `PUBLISH`, `RUN_ARGS`, `CONTAINER_ENV` and the rest | the variables of [ssm-deploy](../tools/ssm-deploy/README.md#usage), same defaults |
| `DELIVERY_TEMPLATES_REF` | `main` |

The job in `needs` must publish `build.env` with at least `IMAGE_REF`, in the format described in [build](build.md#buildenv). Deploys of the same container are serialized with a `resource_group`.

See [`examples/gitlab-ec2`](../examples/gitlab-ec2/.gitlab-ci.yml) for a full pipeline.

## What to check

- The job log shows `assume-role-with-web-identity` succeeding without any AWS key in the project variables.
- The `include` URL and `DELIVERY_TEMPLATES_REF` point to the same ref, so the template and the tool come from the same version.
