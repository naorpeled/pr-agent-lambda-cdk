# PR-Agent on AWS Lambda.
# Every variable here can be overridden: make deploy REGION=eu-west-1

# Your own settings, kept between runs: copy settings.mk.example to settings.mk.
# Anything passed on the command line still wins.
-include settings.mk

REGION           ?= us-east-1
ECR_REPO         ?= pr-agent
SECRET_NAME      ?= pr-agent/config
STACK_NAME       ?= PrAgentLambdaStack
# "latest" resolves to the newest release number when `make image` runs, e.g.
# 0.46.0, and that exact tag is what gets deployed. Pin with PR_AGENT_VERSION=0.45.0.
PR_AGENT_VERSION ?= latest

export REGION ECR_REPO SECRET_NAME STACK_NAME PR_AGENT_VERSION
export AWS_REGION = $(REGION)

# Left unset on purpose. `make image` records the tag and architecture it pushed
# in .pushed-image, and deploy reads them from there; the provider follows the
# image. Set any of them to override:
#   GIT_PROVIDER   github (default), gitlab, gitea, bitbucket_server, azure_devops
#   PROVIDER_URL   server or organization URL, where the provider needs one
#   ASYNC_REVIEWS  true or false; defaults to false for github, true otherwise
#   IMAGE_TAG, ARCH
ifdef IMAGE_TAG
export IMAGE_TAG
endif
ifdef ARCH
export ARCH
endif
ifdef GIT_PROVIDER
export GIT_PROVIDER
endif

CDK = npx cdk

.DEFAULT_GOAL := help
.PHONY: help install typecheck synth image secret bootstrap deploy smoke logs outputs destroy check

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Typical first run (GitHub):"
	@echo "    export WEBHOOK_SECRET=\$$(openssl rand -hex 32)"
	@echo "    make secret APP_ID=123456 PEM=./my-app.private-key.pem"
	@echo "    make image"
	@echo "    make bootstrap deploy smoke"
	@echo ""
	@echo "  Other providers: pass GIT_PROVIDER to secret and image, and TOKEN"
	@echo "  instead of APP_ID and PEM. Deploy follows the image. See the README."

install: node_modules ## Install node dependencies (the CDK targets do this for you)

# Everything that runs cdk or tsc depends on this, so a fresh clone can go
# straight to `make deploy`. Without it, npx fetches a standalone cdk and
# ts-node that can't find TypeScript, and fails with a confusing traceback.
node_modules: package.json package-lock.json
	npm ci
	@touch node_modules

typecheck: node_modules ## Typecheck the CDK app without emitting
	npx tsc --noEmit

synth: node_modules ## Synthesize CloudFormation (offline; needs `make image` first, or IMAGE_TAG)
	$(CDK) synth

image: ## Get a PR-Agent Lambda image into your ECR (newest release by default)
	./scripts/push-image.sh

secret: ## Create/update the provider credentials secret (see README for the inputs)
	./scripts/create-secret.sh

bootstrap: node_modules ## Bootstrap CDK in this account and region (once)
	$(CDK) bootstrap

deploy: node_modules ## Deploy the stack (checks the image is in ECR first)
	./scripts/check-image.sh
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

# CI and local checks synthesize without an image in ECR, so give them a stand-in tag.
check: export IMAGE_TAG ?= 0.0.0-check-github_lambda
check: typecheck synth ## Everything CI runs
	@command -v shellcheck >/dev/null 2>&1 && shellcheck -e SC1091 scripts/*.sh || echo "shellcheck not installed, skipping"

destroy: node_modules ## Tear down the stack, the ECR repo and the secret
	./scripts/destroy.sh
