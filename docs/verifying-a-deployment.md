# Verifying a deployment

A short checklist for after `make deploy`, in the order that isolates problems fastest.

1. `make smoke` hits the health check and scans the last ten minutes of logs for a Secrets Manager failure. A healthy response alone doesn't prove the secret was read.
2. In the GitHub App's settings, replace the placeholder webhook URL with the `WebhookUrl` stack output.
3. Open a small pull request on a repository the App is installed on, and run `make logs` alongside it.
4. Within a couple of minutes PR-Agent should post a description, a review and code suggestions.

If nothing shows up, the App's "Recent Deliveries" tab says where it stopped:

| Delivery result | Likely cause |
|---|---|
| 403 | Webhook secret in the App doesn't match the one in Secrets Manager |
| Timed out, comments posted | Expected. The review runs longer than GitHub's 10-second wait |
| Timed out, no comments | Check `make logs` for Bedrock or model errors |
| No delivery at all | Webhook URL not saved, or the App isn't installed on the repository |
