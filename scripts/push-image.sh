#!/usr/bin/env bash
#
# Copies a published PR-Agent Lambda image from Docker Hub into your own ECR.
#
# Lambda only pulls from ECR, and it rejects multi-architecture images. The
# published tag is a manifest covering both amd64 and arm64, so the --platform
# on the pull is what makes this work.
#
#   ./scripts/push-image.sh
#   ARCH=arm64 ./scripts/push-image.sh
#   IMAGE_TAG=0.41.0-gitlab_lambda ./scripts/push-image.sh

source "$(dirname "$0")/common.sh"

need docker
need aws

ACCOUNT="$(account_id)"
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
TARGET="${REGISTRY}/${ECR_REPO}:${IMAGE_TAG}"

info "creating ECR repository ${ECR_REPO} in ${REGION} (ok if it already exists)"
aws ecr create-repository \
  --repository-name "$ECR_REPO" \
  --image-scanning-configuration scanOnPush=true \
  --region "$REGION" >/dev/null 2>&1 \
  || info "repository already exists, continuing"

info "logging docker in to ${REGISTRY}"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

info "pulling ${UPSTREAM_IMAGE}:${IMAGE_TAG} for linux/${ARCH}"
docker pull --platform "linux/${ARCH}" "${UPSTREAM_IMAGE}:${IMAGE_TAG}"

info "tagging and pushing ${TARGET}"
docker tag "${UPSTREAM_IMAGE}:${IMAGE_TAG}" "$TARGET"
docker push "$TARGET"

# A single-platform image is a plain manifest with a "layers" array. If the
# containerd image store is enabled, docker can push the whole index back
# instead, and Lambda will refuse it at deploy time.
info "verifying the pushed manifest is single-architecture"
if docker manifest inspect "$TARGET" 2>/dev/null | grep -q '"manifests"'; then
  warn "that tag is an image index, not a single-platform image. Lambda will reject it."
  warn "if you use Docker Desktop, turn off the containerd image store and re-run,"
  warn "or copy it with a tool that preserves one platform, e.g."
  warn "  crane copy --platform linux/${ARCH} ${UPSTREAM_IMAGE}:${IMAGE_TAG} ${TARGET}"
  exit 1
fi

info "done. ${TARGET}"
info "set ARCH=${ARCH} when you deploy so the function architecture matches."
