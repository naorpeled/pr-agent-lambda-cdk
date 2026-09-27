#!/usr/bin/env bash
#
# Runs before `cdk deploy`. Fails in seconds, rather than a few minutes into a
# CloudFormation deploy, when the image the stack points at isn't in ECR.

source "$(dirname "$0")/common.sh"

TAG="$(deployed_image_tag)"
[ -n "$TAG" ] || die "no image to deploy yet. Run \`make image\` first, or set IMAGE_TAG."

need aws

if ! aws ecr describe-images \
    --repository-name "$ECR_REPO" \
    --image-ids "imageTag=${TAG}" \
    --region "$REGION" >/dev/null 2>&1; then
  die "${ECR_REPO}:${TAG} is not in ECR in ${REGION}. Run \`make image\` first."
fi

info "deploying ${ECR_REPO}:${TAG}"
