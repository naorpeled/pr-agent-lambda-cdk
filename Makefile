# PR-Agent on AWS Lambda.
# Every variable here can be overridden: make deploy REGION=eu-west-1 ARCH=arm64

REGION        ?= us-east-1
ECR_REPO      ?= pr-agent
IMAGE_TAG     ?= 0.41.0-github_lambda
SECRET_NAME   ?= pr-agent/config
STACK_NAME    ?= PrAgentLambdaStack
ARCH          ?= amd64

export REGION ECR_REPO IMAGE_TAG SECRET_NAME STACK_NAME ARCH
export AWS_REGION = $(REGION)

CDK = npx cdk

.DEFAULT_GOAL := help
.PHONY: help install typecheck synth image secret bootstrap deploy smoke logs outputs destroy check

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Typical first run:"
	@echo "    make install"
	@echo "    export WEBHOOK_SECRET=\$$(openssl rand -hex 32)"
	@echo "    make secret APP_ID=123456 PEM=./my-app.private-key.pem"
	@echo "    make image"
	@echo "    make bootstrap deploy smoke"

install: ## Install node dependencies
	npm install

typecheck: ## Typecheck the CDK app without emitting
	npx tsc --noEmit

synth: ## Synthesize CloudFormation (runs offline, no Docker, no AWS calls)
	$(CDK) synth

image: ## Copy the published PR-Agent Lambda image into your ECR
	./scripts/push-image.sh

secret: ## Create/update the GitHub App credentials secret (needs APP_ID, PEM, WEBHOOK_SECRET)
	./scripts/create-secret.sh

bootstrap: ## Bootstrap CDK in this account and region (once)
	$(CDK) bootstrap

deploy: ## Deploy the stack
	$(CDK) deploy

smoke: ## Hit the health check and look for a secrets failure in the logs
	./scripts/smoke-test.sh

outputs: ## Print the stack outputs
	@aws cloudformation describe-stacks --stack-name $(STACK_NAME) --region $(REGION) \
		--query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output table

logs: ## Tail the function's logs
	@aws logs tail "$$(aws cloudformation describe-stacks --stack-name $(STACK_NAME) \
		--query "Stacks[0].Outputs[?OutputKey=='LogGroup'].OutputValue" \
		--output text --region $(REGION))" --follow

check: typecheck synth ## Everything CI runs
	@command -v shellcheck >/dev/null 2>&1 && shellcheck -e SC1091 scripts/*.sh || echo "shellcheck not installed, skipping"

destroy: ## Tear down the stack, the ECR repo and the secret
	./scripts/destroy.sh
