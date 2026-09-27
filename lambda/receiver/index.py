"""Webhook receiver for async mode.

Sits behind the Function URL, hands each webhook to the PR-Agent function with
an asynchronous invoke, and answers straight away. GitLab.com disables webhooks
that time out repeatedly, and a review takes far longer than any webhook
timeout, so on GitLab this is what keeps the webhook alive. On GitHub it just
turns the timed-out deliveries green.

The event is forwarded untouched, so PR-Agent still checks the webhook secret
itself. The one check done here is cheap: a request without the provider's
auth header can't be a real delivery, so it's refused before it costs a
PR-Agent invocation.
"""

import json
import os

import boto3

WORKER = os.environ["WORKER_FUNCTION"]
AUTH_HEADER = os.environ["AUTH_HEADER"].lower()

lambda_client = boto3.client("lambda")


def _response(status, body=None):
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body if body is not None else {}),
    }


def handler(event, context):
    method = event.get("requestContext", {}).get("http", {}).get("method", "")
    payload = json.dumps(event).encode()

    if method != "POST":
        # Health checks and anything else go through synchronously, so the
        # answer still comes from PR-Agent and proves its image and config load.
        result = lambda_client.invoke(
            FunctionName=WORKER, InvocationType="RequestResponse", Payload=payload
        )
        if result.get("FunctionError"):
            return _response(502, {"message": "PR-Agent function failed"})
        return json.loads(result["Payload"].read() or b"null") or _response(502)

    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    if not headers.get(AUTH_HEADER):
        return _response(401, {"message": f"missing {AUTH_HEADER} header"})

    # Async invokes accept payloads up to 1 MB. Larger deliveries fail here with
    # a 500, which the provider shows in its delivery log.
    lambda_client.invoke(FunctionName=WORKER, InvocationType="Event", Payload=payload)
    return _response(202, {"message": "accepted"})
