#!/usr/bin/env bash
#
# Gets a PR-Agent Lambda image into your ECR, and records what it pushed in
# .pushed-image so `make deploy` uses exactly that.
#
# GitHub and GitLab: copies PR-Agent's published image.
# Gitea, Bitbucket Data Center, Azure DevOps: PR-Agent doesn't publish Lambda
# images for these, so this builds one: the published GitHub image plus the
# small handler in lambda/provider. Nothing is compiled.
#
# Lambda only pulls from ECR, and it rejects multi-architecture images. The
# published tags cover both amd64 and arm64, so everything here is pinned to
# one platform.
#
#   ./scripts/push-image.sh                          # newest release, amd64
#   ARCH=arm64 ./scripts/push-image.sh               # 20% cheaper per GB-second
#   PR_AGENT_VERSION=0.45.0 ./scripts/push-image.sh  # pin a release
#   GIT_PROVIDER=gitea ./scripts/push-image.sh       # any supported provider

source "$(dirname "$0")/common.sh"

ARCH="${ARCH:-amd64}"
case "$ARCH" in amd64|arm64) ;; *) die "ARCH must be amd64 or arm64, got \"$ARCH\"" ;; esac

need docker
need aws

if [ -n "${IMAGE_TAG:-}" ]; then
  [ "$WRAPPED" = false ] || die "IMAGE_TAG can't pick an upstream image for ${GIT_PROVIDER}; use PR_AGENT_VERSION instead."
  UPSTREAM_TAG="$IMAGE_TAG"
  TAG="$IMAGE_TAG"
else
  if [ "$PR_AGENT_VERSION" = "latest" ]; then
    info "looking up the newest PR-Agent release on Docker Hub"
  fi
  VERSION="$(resolve_version)"
  UPSTREAM_TAG="${VERSION}-${UPSTREAM_FLAVOR}"
  TAG="${VERSION}-${LAMBDA_FLAVOR}"
fi

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

info "pulling ${UPSTREAM_IMAGE}:${UPSTREAM_TAG} for linux/${ARCH}"
docker pull --platform "linux/${ARCH}" "${UPSTREAM_IMAGE}:${UPSTREAM_TAG}"

if [ "$WRAPPED" = true ]; then
  info "building the ${GIT_PROVIDER} handler on top of it"
  # --provenance=false: BuildKit otherwise attaches an attestation, which turns
  # the result into a multi-manifest index that Lambda refuses.
  BUILDX_NO_DEFAULT_ATTESTATIONS=1 docker buildx build \
    --platform "linux/${ARCH}" \
    --provenance=false \
    --build-arg "BASE_IMAGE=${UPSTREAM_IMAGE}:${UPSTREAM_TAG}" \
    --build-arg "PR_AGENT_SERVER=${GIT_PROVIDER}" \
    --tag "$TARGET" \
    --load \
    "$(dirname "$0")/../lambda/provider"
else
  docker tag "${UPSTREAM_IMAGE}:${UPSTREAM_TAG}" "$TARGET"
fi

info "pushing ${TARGET}"
docker push "$TARGET"

# A single-platform image is a plain manifest with a "layers" array. If the
# containerd image store is enabled, docker can push an index instead, and
# Lambda will refuse it at deploy time.
info "verifying the pushed manifest is single-architecture"
if docker manifest inspect "$TARGET" 2>/dev/null | grep -q '"manifests"'; then
  warn "that tag is an image index, not a single-platform image. Lambda will reject it."
  warn "if you use Docker Desktop, turn off the containerd image store and re-run."
  exit 1
fi

printf 'IMAGE_TAG=%s\nARCH=%s\n' "$TAG" "$ARCH" > "$PUSHED_IMAGE_FILE"
info "done. ${TARGET}"
info "recorded in .pushed-image, so \`make deploy\` will use ${TAG} on ${ARCH}"
