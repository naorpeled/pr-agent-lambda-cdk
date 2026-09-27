"""Lambda handler for the git providers PR-Agent doesn't ship a Lambda image for.

PR-Agent publishes Lambda images for GitHub and GitLab only. Its webhook
servers for Azure DevOps, Bitbucket Data Center and Gitea are the same kind of
FastAPI router, so this wraps whichever one PR_AGENT_SERVER names in Mangum,
the same way PR-Agent's own github_lambda_webhook.py does. The image is the
published GitHub Lambda image plus this file.
"""

import importlib
import os

# Load the config secret before importing the server module. The Azure DevOps
# server reads its webhook username and password once, at import time, and
# without them it accepts every request unauthenticated.
try:
    from pr_agent.config_loader import apply_secrets_manager_config

    apply_secrets_manager_config()
except Exception as e:  # same fallback as PR-Agent's own Lambda handlers
    try:
        from pr_agent.log import get_logger

        get_logger().error(f"AWS Secrets Manager initialization failed: {e}")
    except Exception:
        pass

from fastapi import FastAPI  # noqa: E402
from mangum import Mangum  # noqa: E402
from starlette.middleware import Middleware  # noqa: E402
from starlette_context.middleware import RawContextMiddleware  # noqa: E402

SERVERS = {
    "azure_devops": "pr_agent.servers.azuredevops_server_webhook",
    "bitbucket_server": "pr_agent.servers.bitbucket_server_webhook",
    "gitea": "pr_agent.servers.gitea_app",
}

server = os.environ.get("PR_AGENT_SERVER", "")
if server not in SERVERS:
    raise RuntimeError(f"PR_AGENT_SERVER must be one of {sorted(SERVERS)}, got {server!r}")

router = importlib.import_module(SERVERS[server]).router

app = FastAPI(middleware=[Middleware(RawContextMiddleware)])
app.include_router(router)


# Gitea's server has no health route. Routes match in order, so for the servers
# that do have one, theirs is the one that answers.
@app.get("/")
async def health():
    return {"status": "ok"}


handler = Mangum(app, lifespan="off")


def lambda_handler(event, context):
    return handler(event, context)
