#!/usr/bin/env bash
#
# Proves the image, the Function URL and the cold start all work, before GitHub
# is anywhere near it.
#
# Note what this does NOT prove: PR-Agent returns {"status":"ok"} even when the
# Secrets Manager lookup failed, because that failure is swallowed. The log
# check below is the part that catches a wrong-region secret.

source "$(dirname "$0")/common.sh"

need aws
need curl

URL="$(stack_output FunctionUrl)" || true
if [ -z "$URL" ] || [ "$URL" = "None" ]; then
  die "no FunctionUrl output on stack ${STACK_NAME}. Deployed yet?"
fi

info "GET ${URL}"
BODY="$(curl -sS --max-time 60 "$URL")" || die "request failed"
printf '%s\n' "$BODY"

case "$BODY" in
  *'"status"'*'"ok"'*) info "health check passed" ;;
  *) die "unexpected response, check the logs: make logs" ;;
esac

LOG_GROUP="$(stack_output LogGroup)" || true
if [ -n "$LOG_GROUP" ] && [ "$LOG_GROUP" != "None" ]; then
  info "checking the last 10 minutes of logs for a secrets failure"
  if aws logs filter-log-events \
      --log-group-name "$LOG_GROUP" \
      --start-time "$(( ($(date +%s) - 600) * 1000 ))" \
      --filter-pattern '"Failed to get secrets from AWS Secrets Manager"' \
      --region "$REGION" \
      --query 'events[0].message' --output text 2>/dev/null | grep -q "Failed to get secrets"; then
    warn "the function could not read its secret. Almost always a region mismatch:"
    warn "the secret must live in ${REGION}, same as the function."
    exit 1
  fi
  info "no secrets errors in the recent logs"
fi

info "webhook url: $(stack_output WebhookUrl)"
