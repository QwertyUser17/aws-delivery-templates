# notify

`.github/workflows/notify.yml` posts to a Slack incoming webhook at the start and at the end of a pipeline. Logic: [`scripts/notify/slack.sh`](../scripts/notify/slack.sh); the [`actions/slack`](../actions/slack) composite action wraps it for direct use in a job.

- **started**: repository, branch, commit, author and a link to the run.
- **finished**: the same, with the result. The links include the jobs that failed or were cancelled. They are read from the GitHub API, so the workflow needs `actions: read`.

The webhook URL comes from a CI secret and is never printed, not even when Slack rejects the message.

The caller computes the result from the jobs it waited for:

```yaml
finished:
  needs: [build, scan, deploy]
  if: always()
  uses: QwertyUser17/aws-delivery-templates/.github/workflows/notify.yml@main
  with:
    event: finished
    status: ${{ contains(needs.*.result, 'failure') && 'failure' || contains(needs.*.result, 'cancelled') && 'cancelled' || 'success' }}
  secrets:
    slack-webhook-url: ${{ secrets.SLACK_WEBHOOK_URL }}
```

## Inputs

| Input | Default |
|---|---|
| `event` | required: `started` or `finished` |
| `status` | empty; for `finished`: `success`, `failure` or `cancelled` |
| `title` | the repository name |

Secret: `slack-webhook-url`.

## What to check

- A failed deploy job shows up in the finish message with a working link.
- A wrong webhook fails the job with a message that doesn't contain the URL.
