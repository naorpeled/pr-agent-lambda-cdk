# shellcheck shell=bash
# Shared config and helpers. Sourced by the other scripts, not run directly.
# Every value can be overridden from the environment.

set -euo pipefail

REGION="${REGION:-us-east-1}"
ECR_REPO="${ECR_REPO:-pr-agent}"
UPSTREAM_IMAGE="${UPSTREAM_IMAGE:-pragent/pr-agent}"
PR_AGENT_VERSION="${PR_AGENT_VERSION:-latest}"
LAMBDA_FLAVOR="${LAMBDA_FLAVOR:-github_lambda}"
SECRET_NAME="${SECRET_NAME:-pr-agent/config}"
STACK_NAME="${STACK_NAME:-PrAgentLambdaStack}"

# Written by push-image.sh, read by check-image.sh and the CDK app, so the tag
# and architecture that get deployed are exactly the ones that were pushed.
PUSHED_IMAGE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.pushed-image"

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is not installed or not on PATH"
}

account_id() {
  aws sts get-caller-identity --query Account --output text --region "$REGION" 2>/dev/null \
    || die "could not reach AWS. Is the CLI configured with credentials?"
}

# Prints an output value, or nothing if the stack or the output is missing.
# Deliberately never fails, so callers can check for an empty string under set -e.
stack_output() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text --region "$REGION" 2>/dev/null || true
}

# Newest released version that has a Lambda image for LAMBDA_FLAVOR, e.g. 0.46.0.
# Resolved to a number rather than using the rolling tag on purpose: a rolling
# tag never changes in the CloudFormation template, so redeploying after a new
# release would silently keep the old image.
latest_version() {
  need curl
  need jq
  local url="https://hub.docker.com/v2/repositories/${UPSTREAM_IMAGE}/tags?page_size=100&name=-${LAMBDA_FLAVOR}"
  local names="" page=0
  while [ -n "$url" ] && [ "$url" != "null" ] && [ "$page" -lt 5 ]; do
    local body
    body="$(curl -fsSL --max-time 30 "$url")" || die "could not query Docker Hub for ${UPSTREAM_IMAGE} tags"
    names+="$(jq -r '.results[].name' <<<"$body")"$'\n'
    url="$(jq -r '.next' <<<"$body")"
    page=$((page + 1))
  done
  local version
  version="$( { grep -E "^[0-9]+\.[0-9]+\.[0-9]+-${LAMBDA_FLAVOR}\$" <<<"$names" || true; } \
    | sed "s/-${LAMBDA_FLAVOR}\$//" | sort -V | tail -n 1)"
  [ -n "$version" ] || die "no released ${LAMBDA_FLAVOR} images found on Docker Hub for ${UPSTREAM_IMAGE}"
  printf '%s\n' "$version"
}

# The image tag to pull and push: IMAGE_TAG if set, else PR_AGENT_VERSION with
# "latest" resolved to a concrete release.
resolve_image_tag() {
  if [ -n "${IMAGE_TAG:-}" ]; then
    printf '%s\n' "$IMAGE_TAG"
    return
  fi
  local version="$PR_AGENT_VERSION"
  if [ "$version" = "latest" ]; then
    version="$(latest_version)"
  fi
  printf '%s-%s\n' "$version" "$LAMBDA_FLAVOR"
}

# The tag to deploy: IMAGE_TAG if set, else whatever push-image.sh recorded.
deployed_image_tag() {
  if [ -n "${IMAGE_TAG:-}" ]; then
    printf '%s\n' "$IMAGE_TAG"
  elif [ -f "$PUSHED_IMAGE_FILE" ]; then
    sed -n 's/^IMAGE_TAG=//p' "$PUSHED_IMAGE_FILE"
  fi
}
