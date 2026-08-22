# shellcheck shell=bash
# Shared config and helpers. Sourced by the other scripts, not run directly.
# Every value can be overridden from the environment.

set -euo pipefail

REGION="${REGION:-us-east-1}"
ECR_REPO="${ECR_REPO:-pr-agent}"
IMAGE_TAG="${IMAGE_TAG:-0.41.0-github_lambda}"
UPSTREAM_IMAGE="${UPSTREAM_IMAGE:-pragent/pr-agent}"
SECRET_NAME="${SECRET_NAME:-pr-agent/config}"
STACK_NAME="${STACK_NAME:-PrAgentLambdaStack}"
ARCH="${ARCH:-amd64}"

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
