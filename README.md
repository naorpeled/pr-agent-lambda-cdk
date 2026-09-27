# pr-agent-lambda-cdk

Run [PR-Agent](https://github.com/The-PR-Agent/pr-agent), the open source AI code reviewer, on AWS Lambda with Amazon Bedrock. Supports GitHub, GitLab, Gitea, Bitbucket Data Center and Azure DevOps. The [blog post](https://dev.to/naorpeled) explains how it works.

![Architecture: a pull request webhook hits a Lambda Function URL, the function runs a container image from ECR, reads credentials from Secrets Manager, calls Bedrock, and posts the review back on the PR](docs/architecture.png)

You need AWS CLI v2, Docker, Node 20+, `jq`, `openssl`, and Bedrock access to your [model](#choosing-a-model).

## Deploy on GitHub

1. Create a GitHub App (Settings, Developer settings, GitHub Apps):
   - Permissions: Pull requests and Issues read and write, Contents and Metadata read-only
   - Events: Pull request, Pull request review, Pull request review comment, Issue comment
   - Webhook URL `https://example.com` for now, and a secret from `openssl rand -hex 32`

   Generate a private key, note the App ID, and install the App on your repos.

2. Deploy:

   ```bash
   export WEBHOOK_SECRET=<the secret from step 1>
   make secret APP_ID=123456 PEM=./my-app.private-key.pem
   make image
   make bootstrap    # once per account and region
   make deploy
   make smoke        # prints the WebhookUrl
   ```

3. Replace `example.com` in the App's webhook settings with the `WebhookUrl`.

## Deploy on other providers

Same steps with `GIT_PROVIDER` and an access token, for example:

```bash
export WEBHOOK_SECRET=$(openssl rand -hex 32)
make secret GIT_PROVIDER=gitea TOKEN=<access token>
make image GIT_PROVIDER=gitea
make bootstrap
make deploy PROVIDER_URL=https://gitea.example.com
make smoke
```

Then add a webhook to the `WebhookUrl` with `WEBHOOK_SECRET` as its secret:

| `GIT_PROVIDER` | Token | `PROVIDER_URL` | Webhook events |
|---|---|---|---|
| `gitlab` | `api` scope | self-managed only | Merge request, Comments |
| `gitea` | repository and issue write | self-hosted only | Pull request, Issue comment |
| `bitbucket_server` | HTTP access token, repository write | required | Pull request opened, Comment added |
| `azure_devops` | PAT, Code read and write | required, e.g. `https://dev.azure.com/org` | Service hook Web Hooks: PR created, PR commented on (v2.0). Basic auth `pr-agent` / `WEBHOOK_SECRET` |

Bitbucket Cloud isn't supported.

## Choosing a model

Set `MODEL` and `FALLBACK_MODEL` to Bedrock model IDs, and `INFERENCE_REGIONS` to where they run: the regions a cross-region profile (`us.…`, `eu.…`) routes to, or just your region. For example, DeepSeek V3.2:

```bash
make deploy MODEL=deepseek.v3.2 FALLBACK_MODEL=deepseek.v3.2 INFERENCE_REGIONS=us-east-1
```

The default is Claude, which needs a one-time use-case form in the Bedrock console. `aws bedrock list-foundation-models` shows what your account can use.

## Settings

Pass to `make`, or save them in `settings.mk` (see `settings.mk.example`) so later runs keep them.

| Setting | Default | |
|---|---|---|
| `REGION` | `us-east-1` | Keep the secret, image and stack together |
| `PR_AGENT_VERSION` | newest | Release for `make image` |
| `ARCH` | `amd64` | `arm64` is 20% cheaper. Set on `make image` |
| `ASYNC_REVIEWS` | off for GitHub, on otherwise | Answer webhooks immediately, review in the background |
| `RESERVED_CONCURRENCY` | `5` | Max parallel reviews. Empty to disable |
| `MEMORY_SIZE` | `2048` | MB |

## Common tasks

| | |
|---|---|
| Upgrade PR-Agent | `make image && make deploy` |
| Watch reviews | `make logs` |
| Remove everything | `make destroy` |

## Troubleshooting

| Symptom | Fix |
|---|---|
| GitHub deliveries time out, but reviews appear | Expected. `ASYNC_REVIEWS=true` makes them green |
| Deliveries rejected (401/403) | Webhook secret doesn't match `make secret` |
| Deliveries accepted, no reviews | Check `make logs` |
| `AccessDeniedException` in logs | No Bedrock access to the model, or it's outside `INFERENCE_REGIONS` |
| Deploy fails on `UnreservedConcurrentExecution` | New account. Deploy with `RESERVED_CONCURRENCY=` |

## License

MIT
