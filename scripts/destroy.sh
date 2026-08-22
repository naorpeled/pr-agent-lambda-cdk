#!/usr/bin/env bash
#
# Tears down everything, including the pieces CDK did not create.
# cdk destroy leaves the ECR repo and the secret behind, and both keep billing.

source "$(dirname "$0")/common.sh"

need aws

info "destroying stack ${STACK_NAME}"
npx cdk destroy --force

info "deleting ECR repository ${ECR_REPO}"
aws ecr delete-repository --repository-name "$ECR_REPO" --force --region "$REGION" >/dev/null 2>&1 \
  || info "repository already gone"

# Without --force-delete-without-recovery the secret sits in a recovery window
# for up to 30 days, still charged, still holding the name.
info "deleting secret ${SECRET_NAME}"
aws secretsmanager delete-secret \
  --secret-id "$SECRET_NAME" \
  --force-delete-without-recovery \
  --region "$REGION" >/dev/null 2>&1 \
  || info "secret already gone"

info "done."
info "the CDKToolkit bootstrap stack is left alone. It costs nothing when empty"
info "and is shared by every CDK app in this account and region."
