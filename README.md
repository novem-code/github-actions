# github-actions
A collection of reusable GitHub Actions for Novem

## `discord-notify`

Post one message to a Discord webhook, honouring the rate limit. A plain
`curl` exits 0 whatever Discord answers, so a 429 — what several workflows
firing at once earns you — printed the rate-limit body into the log and left
the step green with the message thrown away.

```yaml
- uses: novem-code/github-actions/discord-notify@<full-sha>
  with:
    webhook-url: ${{ secrets.DISCORD_WEBHOOK_URL }}
    content: "🚀 deploy finished"
```

Pin the **full commit SHA**, never a tag or branch: refs here are mutable.

| Input | Required | Default | |
|---|---|---|---|
| `webhook-url` | yes | | The webhook. A composite action cannot declare `secrets:`, so pass the secret as this input; masking is by value, so it stays redacted. |
| `content` | one of | `''` | Message text. JSON-encoded for you — quotes and newlines are safe without reaching for `jq`. |
| `payload` | one of | `''` | A complete Discord JSON object, for embeds. Give exactly one of `content` / `payload`. |
| `fail-on-undeliverable` | no | `'true'` | Whether an undeliverable message fails the step. |

Output `delivered` is `"true"`/`"false"`.

### Which way to set `fail-on-undeliverable`

A notifier that **is** the deliverable may fail the run; a notifier reporting
**someone else's** failure may not. Leave it `true` when sending the message is
the whole job — nothing else records that it vanished. Set it `false` in an
`if: failure()` step, where a red notifier is read as the failure it was
reporting. Either way an `::error::` annotation lands on the run summary, so
the loss is never silent.

Retries honour `retry_after` and `X-RateLimit-Reset-After`, bounded at 5
attempts / 30s per wait / 60s total, with `--max-time` so one hung connection
cannot stall a job. A 4xx that is not a 429 is not retried — a malformed
payload or a dead webhook does not improve by repetition.

Needs `bash`, `curl` and `jq` on the runner.
