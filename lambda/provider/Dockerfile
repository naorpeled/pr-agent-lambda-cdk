# The published PR-Agent GitHub Lambda image already contains every provider's
# dependencies; this only adds a handler that serves a different webhook server.
# Built by scripts/push-image.sh, for one architecture at a time.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
ARG PR_AGENT_SERVER
ENV PR_AGENT_SERVER=${PR_AGENT_SERVER}
COPY pr_agent_lambda.py ${LAMBDA_TASK_ROOT}/
CMD ["pr_agent_lambda.lambda_handler"]
