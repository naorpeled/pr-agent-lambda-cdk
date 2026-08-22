#!/usr/bin/env bash
#
# Builds the PR-Agent config secret from your GitHub App credentials and stores
# it in Secrets Manager, in the same region as everything else.
#
# The secret has to live in the function's region. PR-Agent's secrets provider
# builds its boto3 client without an explicit region, so a secret somewhere else
# fails the lookup, and the Lambda handler swallows that and falls back to
# environment variables. You end up with no credentials and, worse, no webhook
# signature verification, announced only by an error line in the logs.
#
#   APP_ID=123456 PEM=./my-app.private-key.pem ./scripts/create-secret.sh
#
# WEBHOOK_SECRET is read from the environment. Generate one with:
#   export WEBHOOK_SECRET=$(openssl rand -hex 32)

source "$(dirname "$0")/common.sh"

need aws
need jq

: "${APP_ID:?set APP_ID to the App ID of your GitHub App}"
: "${PEM:?set PEM to the path of your GitHub App private key .pem}"
: "${WEBHOOK_SECRET:?set WEBHOOK_SECRET first, see the comment at the top of this script}"

[ -f "$PEM" ] || die "no such file: $PEM"

# An empty webhook secret is worse than no secret at all: PR-Agent gates
# signature verification on a truthy value, so "" leaves the endpoint open.
[ -n "${WEBHOOK_SECRET//[[:space:]]/}" ] || die "WEBHOOK_SECRET is empty"

TMP="$(mktemp -t pr-agent-config.XXXXXX)"
trap 'rm -f "$TMP"' EXIT

# Only keys with exactly one dot are parsed by PR-Agent, anything deeper is
# silently dropped. jq -Rs keeps the PEM's newlines escaped inside one string.
jq -Rs \
  --arg app_id "$APP_ID" \
  --arg secret "$WEBHOOK_SECRET" \
  '{"github.app_id": $app_id, "github.webhook_secret": $secret, "github.private_key": .}' \
  < "$PEM" > "$TMP"

jq -e '."github.private_key" | startswith("-----BEGIN")' "$TMP" >/dev/null \
  || die "$PEM does not look like a PEM private key"

if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$REGION" >/dev/null 2>&1; then
  info "secret ${SECRET_NAME} exists, storing a new version"
  aws secretsmanager put-secret-value \
    --secret-id "$SECRET_NAME" \
    --secret-string "file://$TMP" \
    --region "$REGION" >/dev/null
else
  info "creating secret ${SECRET_NAME} in ${REGION}"
  aws secretsmanager create-secret \
    --name "$SECRET_NAME" \
    --description "PR-Agent GitHub App credentials" \
    --secret-string "file://$TMP" \
    --region "$REGION" >/dev/null
fi

info "done. the plaintext copy was written to a temp file and deleted."
