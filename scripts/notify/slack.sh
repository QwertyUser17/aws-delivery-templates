#!/usr/bin/env bash
# Posts a pipeline start or finish message to a Slack incoming webhook. The webhook
# comes from a CI secret and is never printed.
set -Eeuo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/common.sh
. "$here/../lib/common.sh"

require SLACK_WEBHOOK_URL EVENT REPOSITORY REF RUN_URL
: "${STATUS:=}"
: "${SHA:=}"
: "${ACTOR:=}"
: "${TITLE:=}"
# JSON array of {"name", "url", "conclusion"} for the jobs worth a link.
: "${JOBS_JSON:=[]}"

case "$EVENT:$STATUS" in
  started:*) icon=':arrow_forward:' color='#439FE0' word='started' ;;
  finished:success) icon=':white_check_mark:' color='good' word='succeeded' ;;
  finished:failure) icon=':x:' color='danger' word='failed' ;;
  finished:cancelled) icon=':no_entry_sign:' color='#9E9E9E' word='was cancelled' ;;
  finished:*) icon=':grey_question:' color='warning' word="finished: ${STATUS:-unknown}" ;;
  *) die "event must be started or finished, got '$EVENT'" ;;
esac

payload=$(jq -n \
  --arg icon "$icon" --arg color "$color" --arg word "$word" \
  --arg title "${TITLE:-$REPOSITORY}" --arg repo "$REPOSITORY" --arg ref "$REF" \
  --arg sha "${SHA:0:12}" --arg actor "$ACTOR" --arg run "$RUN_URL" \
  --argjson jobs "$JOBS_JSON" '
  {
    text: "\($icon) \($title) \($word)",
    attachments: [{
      color: $color,
      blocks: [
        {type: "section", text: {type: "mrkdwn",
          text: "*\($title)* \($word)\n`\($repo)` on `\($ref)`\(if $sha != "" then " at `\($sha)`" else "" end)\(if $actor != "" then " by \($actor)" else "" end)"}},
        {type: "context", elements: ([{type: "mrkdwn", text: "<\($run)|Pipeline>"}]
          + [$jobs[] | {type: "mrkdwn", text: "<\(.url)|\(.name)>: \(.conclusion)"}])}
      ]
    }]
  }')

curl -fsS --retry 3 --max-time 15 -H 'Content-Type: application/json' \
  --data "$payload" "$SLACK_WEBHOOK_URL" >/dev/null ||
  die "Slack did not accept the message (the webhook URL is not printed)"
note "Slack: $REPOSITORY $word"
