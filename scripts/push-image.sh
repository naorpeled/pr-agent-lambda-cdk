#!/usr/bin/env bash
#
# Copies a published PR-Agent Lambda image from Docker Hub into your own ECR,
# and records what it pushed in .pushed-image so `make deploy` uses exactly that.
#
# Lambda only pulls from ECR, and it rejects multi-architecture images. The
# published tags are manifests covering both amd64 and arm64, so the --platform
# on the pull is what makes this work.
#
#   ./scripts/push-image.sh                          # newest release, amd64
#   ARCH=arm64 ./scripts/push-image.sh               # 20% cheaper per GB-second
#   PR_AGENT_VERSION=0.45.0 ./scripts/push-image.sh  # pin a release
#   LAMBDA_FLAVOR=gitlab_lambda ./scripts/push-image.sh
#   IMAGE_TAG=0.45.0-github_lambda ./scripts/push-image.sh  # exact tag

source "$(dirname "$0")/common.sh"

ARCH="${ARCH:-amd64}"
case "$ARCH" in amd64|arm64) ;; *) die "ARCH must be amd64 or arm64, got \"$ARCH\"" ;; esac

need docker
need aws

if [ -z "${IMAGE_TAG:-}" ] && [ "$PR_AGENT_VERSION" = "latest" ]; then
  info "looking up the newest ${LAMBDA_FLAVOR} release on Docker Hub"
fi
TAG="$(resolve_image_tag)"

ACCOUNT="$(account_id)"
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
TARGET="${REGISTRY}/${ECR_REPO}:${TAG}"

info "creating ECR repository ${ECR_REPO} in ${REGION} (ok if it already exists)"
aws ecr create-repository \
  --repository-name "$ECR_REPO" \
  --image-scanning-configuration scanOnPush=true \
  --region "$REGION" >/dev/null 2>&1 \
  || info "repository already exists, continuing"

info "logging docker in to ${REGISTRY}"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

info "pulling ${UPSTREAM_IMAGE}:${TAG} for linux/${ARCH}"
docker pull --platform "linux/${ARCH}" "${UPSTREAM_IMAGE}:${TAG}"

info "tagging and pushing ${TARGET}"
docker tag "${UPSTREAM_IMAGE}:${TAG}" "$TARGET"
docker push "$TARGET"

# A single-platform image is a plain manifest with a "layers" array. If the
# containerd image store is enabled, docker can push the whole index back
# instead, and Lambda will refuse it at deploy time.
info "verifying the pushed manifest is single-architecture"
if docker manifest inspect "$TARGET" 2>/dev/null | grep -q '"manifests"'; then
  warn "that tag is an image index, not a single-platform image. Lambda will reject it."
  warn "if you use Docker Desktop, turn off the containerd image store and re-run,"
  warn "or copy it with a tool that preserves one platform, e.g."
  warn "  crane copy --platform linux/${ARCH} ${UPSTREAM_IMAGE}:${TAG} ${TARGET}"
  exit 1
fi

printf 'IMAGE_TAG=%s\nARCH=%s\n' "$TAG" "$ARCH" > "$PUSHED_IMAGE_FILE"
info "done. ${TARGET}"
info "recorded in .pushed-image, so \`make deploy\` will use ${TAG} on ${ARCH}"
