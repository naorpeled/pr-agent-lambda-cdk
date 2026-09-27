#!/usr/bin/env bash
#
# Builds the PR-Agent config secret from your git provider credentials and
# stores it in Secrets Manager, in the same region as everything else.
#
# The secret has to live in the function's region. PR-Agent's secrets provider
# builds its boto3 client without an explicit region, so a secret somewhere else
# fails the lookup, and the Lambda handler swallows that and falls back to
# environment variables. You end up with no credentials, announced only by an
# error line in the logs. (Before PR-Agent v0.44.0 it also meant no webhook
# signature verification on GitHub. Since then, webhooks are rejected instead.)
#
# GitHub (a GitHub App):
#   APP_ID=123456 PEM=./my-app.private-key.pem ./scripts/create-secret.sh
#
# Everything else takes an access token for the account that posts reviews:
#   GIT_PROVIDER=gitlab           TOKEN=glpat-...  (api scope)
#   GIT_PROVIDER=gitea            TOKEN=...        (read/write on repositories and issues)
#   GIT_PROVIDER=bitbucket_server TOKEN=...        (HTTP access token, repository write)
#   GIT_PROVIDER=azure_devops     TOKEN=...        (PAT with Code read and write)
#
# WEBHOOK_SECRET is read from the environment and has to match what you set on
# the webhook. For Azure DevOps it's the basic auth password, with the username
# from WEBHOOK_USERNAME (default pr-agent). Generate one with:
#   export WEBHOOK_SECRET=$(openssl rand -hex 32)

source "$(dirname "$0")/common.sh"

need aws
need jq

: "${WEBHOOK_SECRET:?set WEBHOOK_SECRET first, see the comment at the top of this script}"

# Never store a config without webhook credentials. Depending on the provider
# and version, PR-Agent then either rejects every webhook or accepts them all
# unauthenticated (Bitbucket Data Center and Azure DevOps skip the check when
# nothing is configured).
[ -n "${WEBHOOK_SECRET//[[:space:]]/}" ] || die "WEBHOOK_SECRET is empty"

TMP="$(mktemp -t pr-agent-config.XXXXXX)"
trap 'rm -f "$TMP"' EXIT

# Only keys with exactly one dot are parsed by PR-Agent, anything deeper is
# silently dropped.
case "$GIT_PROVIDER" in
  github)
    : "${APP_ID:?set APP_ID to the App ID of your GitHub App}"
    : "${PEM:?set PEM to the path of your GitHub App private key .pem}"
    [ -f "$PEM" ] || die "no such file: $PEM"
    # jq -Rs keeps the PEM's newlines escaped inside one JSON string.
    jq -Rs \
      --arg app_id "$APP_ID" \
      --arg secret "$WEBHOOK_SECRET" \
      '{"github.app_id": $app_id, "github.webhook_secret": $secret, "github.private_key": .}' \
      < "$PEM" > "$TMP"
    jq -e '."github.private_key" | startswith("-----BEGIN")' "$TMP" >/dev/null \
      || die "$PEM does not look like a PEM private key"
    ;;
  gitlab|gitea|bitbucket_server|azure_devops)
    : "${TOKEN:?set TOKEN to an access token for ${GIT_PROVIDER}, see the comment at the top of this script}"
    [ -n "${TOKEN//[[:space:]]/}" ] || die "TOKEN is empty"
    # Server URLs are deliberately not in here: some have defaults, and PR-Agent
    # ignores secret keys for settings that already have a value. They go in
    # PROVIDER_URL at deploy time instead.
    case "$GIT_PROVIDER" in
      gitlab)
        jq -n --arg token "$TOKEN" --arg secret "$WEBHOOK_SECRET" \
          '{"gitlab.personal_access_token": $token, "gitlab.shared_secret": $secret}' > "$TMP" ;;
      gitea)
        jq -n --arg token "$TOKEN" --arg secret "$WEBHOOK_SECRET" \
          '{"gitea.personal_access_token": $token, "gitea.webhook_secret": $secret}' > "$TMP" ;;
      bitbucket_server)
        jq -n --arg token "$TOKEN" --arg secret "$WEBHOOK_SECRET" \
          '{"bitbucket_server.bearer_token": $token, "bitbucket_server.webhook_secret": $secret}' > "$TMP" ;;
      azure_devops)
        WEBHOOK_USERNAME="${WEBHOOK_USERNAME:-pr-agent}"
        jq -n --arg token "$TOKEN" --arg user "$WEBHOOK_USERNAME" --arg secret "$WEBHOOK_SECRET" \
          '{"azure_devops.pat": $token,
            "azure_devops_server.webhook_username": $user,
            "azure_devops_server.webhook_password": $secret}' > "$TMP"
        info "webhook basic auth: username ${WEBHOOK_USERNAME}, password \$WEBHOOK_SECRET" ;;
    esac
    ;;
esac

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
    --description "PR-Agent ${GIT_PROVIDER} credentials" \
    --secret-string "file://$TMP" \
    --region "$REGION" >/dev/null
fi

info "done. the plaintext copy was written to a temp file and deleted."
