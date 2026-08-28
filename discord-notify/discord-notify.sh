#!/usr/bin/env bash
#
# Post one message to a Discord webhook, honouring the rate limit.
#
# A plain `curl` exits 0 whatever Discord answers, so a 429 — which is what
# several workflows firing at once earns you — threw the notification away
# without a trace. Discord's 429 names the wait it wants:
#
#   {"message": "Service resource is being rate limited.", "retry_after": 3, ...}
#
# Wait that long and try again, bounded so no job can hang on a notification,
# and exit non-zero when the message never lands — unless the caller set
# fail-on-undeliverable: false, which is for a notifier reporting someone
# else's failure, whose own red would be mistaken for that failure.
#
# Everything arrives via env, set by action.yml from the action's inputs.
# Nothing is interpolated into this file, so caller-controlled text (a PR
# title, a commit message) can never become shell.

set -euo pipefail

: "${DISCORD_WEBHOOK_URL:?webhook-url is required and was empty}"

content=${DISCORD_CONTENT:-}
payload=${DISCORD_PAYLOAD:-}
fail_on_undeliverable=${DISCORD_FAIL_ON_UNDELIVERABLE:-true}

if [ -n "$content" ] && [ -n "$payload" ]; then
  echo "::error::discord-notify: give content or payload, not both"
  exit 1
fi

# Encode here rather than making every caller reach for jq: getting a title
# with a quote in it into valid JSON by hand is the bug this avoids.
if [ -z "$payload" ]; then
  if [ -z "$content" ]; then
    echo "::error::discord-notify: one of content or payload is required"
    exit 1
  fi
  payload=$(jq -n --arg content "$content" '{content: $content}')
elif ! jq -e . >/dev/null 2>&1 <<<"$payload"; then
  echo "::error::discord-notify: payload is not valid JSON"
  exit 1
fi

MAX_ATTEMPTS=5
MAX_TOTAL_WAIT=60 # across all retries — the ceiling on delaying a job
MAX_SINGLE_WAIT=30
DEFAULT_WAIT=2 # a 429 that names no wait at all

body=$(mktemp)
hdrs=$(mktemp)
trap 'rm -f "$body" "$hdrs"' EXIT

# Report the verdict once, in one place, so the output and the exit code
# cannot disagree. `delivered` lets a caller that suppressed the failure still
# branch on what happened.
finish() {
  local delivered=$1
  [ -z "${GITHUB_OUTPUT:-}" ] || echo "delivered=$delivered" >>"$GITHUB_OUTPUT"
  [ "$delivered" = false ] || exit 0
  [ "$fail_on_undeliverable" != false ] || exit 0
  exit 1
}

# Whole seconds, rounded UP. retry_after is fractional and the shell has no
# float arithmetic; oversleeping costs nothing, undersleeping earns another 429.
ceil_seconds() {
  local value=${1:-} whole=${1%%.*}
  case $whole in '' | *[!0-9]*) echo 0 ;; *)
    if [ "$whole" = "$value" ]; then echo "$whole"; else echo $((whole + 1)); fi
    ;;
  esac
}

# A response header by name (give it lowercase), empty when absent. Bash
# builtins only: the self-hosted runners' nix shells promise curl and jq on
# PATH, not awk.
header() {
  local want=$1 line key value=""
  while IFS= read -r line; do
    line=${line%$'\r'}
    key=${line%%:*}
    if [ "${key,,}" = "$want" ]; then value=${line#*: }; fi
  done <"$hdrs"
  printf '%s' "$value"
}

# What the response actually asked for, in descending authority. The body is
# Discord's own answer; the headers cover a 429 raised in front of the API,
# which arrives with no JSON body at all.
rate_limit_wait() {
  local secs
  secs=$(ceil_seconds "$(jq -r '.retry_after // empty' "$body" 2>/dev/null || true)")
  [ "$secs" -gt 0 ] || secs=$(ceil_seconds "$(header x-ratelimit-reset-after)")
  [ "$secs" -gt 0 ] || secs=$(ceil_seconds "$(header retry-after)")
  [ "$secs" -gt 0 ] || secs=$DEFAULT_WAIT
  echo "$secs"
}

waited=0
attempt=1
while :; do
  # --max-time bounds a hung connection: without it "bounded retry" still
  # leaves one attempt able to stall the job indefinitely.
  status=$(curl -sS --connect-timeout 5 --max-time 15 \
    -o "$body" -D "$hdrs" -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    -X POST --data-binary "$payload" \
    "$DISCORD_WEBHOOK_URL") || status=000

  case $status in
    2*)
      finish true
      ;;
    429)
      delay=$(rate_limit_wait)
      scope=$(jq -r 'if .global == true then "global" else "route" end' "$body" 2>/dev/null || echo route)
      reason="rate limited, $scope"
      ;;
    5* | 000)
      # Discord is down, or the request never landed. Neither says how long to
      # wait, so back off on the attempt count.
      delay=$((attempt * 2))
      reason="transient"
      ;;
    *)
      # 400/401/404: a malformed payload or a dead webhook does not improve by
      # being repeated. Fail now and name it, rather than burning the budget.
      echo "::error::discord notification refused with HTTP $status — payload or webhook, not a rate limit"
      detail=$(<"$body")
      printf 'discord: HTTP %s: %s\n' "$status" "${detail:0:500}" >&2
      finish false
      ;;
  esac

  [ "$delay" -le "$MAX_SINGLE_WAIT" ] || delay=$MAX_SINGLE_WAIT

  if [ "$attempt" -ge "$MAX_ATTEMPTS" ] || [ $((waited + delay)) -gt "$MAX_TOTAL_WAIT" ]; then
    break
  fi

  printf 'discord: HTTP %s (%s), retrying in %ss (attempt %s/%s)\n' \
    "$status" "$reason" "$delay" "$attempt" "$MAX_ATTEMPTS" >&2
  sleep "$delay"
  waited=$((waited + delay))
  attempt=$((attempt + 1))
done

echo "::error::discord notification never landed: $attempt attempts over ${waited}s, last status $status"
finish false
