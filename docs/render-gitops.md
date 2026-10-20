# render-gitops

`.github/workflows/render-gitops.yml` is the deploy to Kubernetes. CI never talks to the cluster: it changes the image in one file of a GitOps repository with a commit, and Argo CD applies it. Logic: [`scripts/gitops/render.sh`](../scripts/gitops/render.sh). Needs `yq` v4 on the runner (it is on GitHub-hosted runners).

## Target types

| `target-type` | File | What changes |
|---|---|---|
| `kustomize-patch` | patch or manifests | every `image:` of the repository, in all documents; provenance in the annotations of the pod templates that run it |
| `helm-values` | values file | `image:` strings of the repository and `{repository, tag}` maps; provenance under `annotations-path` |

Only references to this repository change, so sidecars stay as they are. The repository name is regex-escaped, so `.../app` doesn't match `.../app-worker`. If nothing matches, the job fails and lists the images the file has. A Deployment and its migration CronJob in one file get the same build.

Provenance annotations: `aws-delivery-templates/run-id`, `aws-delivery-templates/run-url`, `aws-delivery-templates/commit`.

## Out-of-order protection

Pipelines don't finish in the order they started, so a slow older one could replace what a newer one already deployed. Before changing anything, the job compares:

- the run ID in the annotations with its own (run IDs only grow);
- the build number in the current tag with its own.

If the file already has something newer, the job ends with exit code 0 and explains why. To deploy an older build on purpose, run it with `allow-rollback: true`.

## Racing pushes

Two pipelines can change the GitOps repository at the same time. Before the change, the job takes a fingerprint of all image references in the file. If the push is rejected:

1. `git fetch` and `git reset --hard` to the new head. Not a rebase: it works on a shallow clone and never leaves a half-done rebase.
2. If the images changed and the new state has neither a run ID nor a numbered tag for this repository, the order can't be checked, and the job stops with the image list.
3. Otherwise it runs the guard again and applies the change again. Applying is deterministic, so the same input gives the same file.
4. Up to 5 attempts, with a longer pause each time.

If the file already has this build, that's a normal outcome: the job says so. To restart pods, restart the workload in the cluster; running the job again changes nothing.

## Commit

The commit goes straight to `gitops-branch`. Its subject is `Deploy <name> <tag>`. The body has the image with digest, the source commit, the run and the file.

## Inputs

| Input | Default | Notes |
|---|---|---|
| `gitops-repository` | | SSH URL, `git@host:org/repo.git` or `ssh://git@host:2222/org/repo.git` |
| `gitops-branch` | `main` | |
| `gitops-file` | | path inside the GitOps repository |
| `target-type` | `kustomize-patch` | or `helm-values` |
| `annotations-path` | `.podAnnotations` | `helm-values` only |
| `allow-rollback` | `false` | |

Secrets: `gitops-deploy-key` (required, a deploy key with write access), `gitops-known-hosts` (optional; without it the host key is scanned on first use).

## What to check

- Two pipelines finishing in the wrong order: the older one logs "Skipped", and the file keeps the newer image.
- A file with a sidecar from another repository: only the application image changes.
- In a `kustomize-patch` overlay, `kubectl kustomize` still builds, and the pods carry the three annotations.
