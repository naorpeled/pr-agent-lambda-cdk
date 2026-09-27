#!/usr/bin/env node
import * as fs from 'fs';
import * as path from 'path';
import * as cdk from 'aws-cdk-lib';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import { GitProvider, PROVIDERS, PrAgentLambdaStack } from '../lib/pr-agent-lambda-stack';

/**
 * Everything here is overridable by environment variable so the Makefile can
 * drive it. The model defaults are the ones from the blog post.
 */
const region = process.env.AWS_REGION ?? process.env.CDK_DEFAULT_REGION ?? 'us-east-1';
const account = process.env.CDK_DEFAULT_ACCOUNT;

/**
 * `make image` records the tag and architecture it pushed in .pushed-image.
 * Reading them back means the deployed image is exactly the pushed one, and
 * "latest" is frozen to a real version number at push time.
 */
function readPushedImage(): Record<string, string> {
  const file = path.join(__dirname, '..', '.pushed-image');
  if (!fs.existsSync(file)) return {};
  return Object.fromEntries(
    fs
      .readFileSync(file, 'utf8')
      .split('\n')
      .map((line) => line.trim())
      .filter((line) => line.includes('='))
      .map((line) => [line.slice(0, line.indexOf('=')), line.slice(line.indexOf('=') + 1)]),
  );
}
const pushed = readPushedImage();

const imageTag = process.env.IMAGE_TAG || pushed.IMAGE_TAG;
if (!imageTag) {
  throw new Error(
    'No image to deploy yet. Run `make image` first (it records the tag it pushed in .pushed-image), or set IMAGE_TAG.',
  );
}

const arch = (process.env.ARCH || pushed.ARCH || 'amd64').toLowerCase();
if (arch !== 'amd64' && arch !== 'arm64') {
  throw new Error(`ARCH must be "amd64" or "arm64", got "${arch}"`);
}
// A function whose architecture doesn't match its image deploys fine and then
// fails every invocation with an exec format error, so refuse it up front.
if (!process.env.IMAGE_TAG && pushed.ARCH && process.env.ARCH && process.env.ARCH !== pushed.ARCH) {
  throw new Error(
    `ARCH=${process.env.ARCH} but the image in ECR was pushed for ${pushed.ARCH}. ` +
      `Re-run \`make image ARCH=${process.env.ARCH}\`, or drop ARCH to use ${pushed.ARCH}.`,
  );
}

// The image flavor decides which webhook handler runs, so the provider follows
// the image unless GIT_PROVIDER says otherwise, and a disagreement is refused:
// a GitLab image behind a GitHub config deploys fine and then 404s every webhook.
const providerNames = Object.keys(PROVIDERS) as GitProvider[];
const flavorProvider = providerNames.find((p) => imageTag.endsWith(`-${p}_lambda`));
const gitProvider = (process.env.GIT_PROVIDER || flavorProvider || 'github').toLowerCase() as GitProvider;
if (!providerNames.includes(gitProvider)) {
  throw new Error(`GIT_PROVIDER must be one of ${providerNames.join(', ')}; got "${gitProvider}"`);
}
if (flavorProvider && flavorProvider !== gitProvider) {
  throw new Error(
    `GIT_PROVIDER=${gitProvider} but the image ${imageTag} runs the ${flavorProvider} handler. ` +
      `Re-run \`make image GIT_PROVIDER=${gitProvider}\`.`,
  );
}

// Minimum PR-Agent versions, where older ones are unsafe or untested here.
// GitLab: before 0.46.0, PR-Agent looked up GitLab's webhook token as a Secrets
// Manager secret name and logged the name (the token itself) when the lookup
// failed, which with this stack is every webhook.
// Gitea, Bitbucket Data Center, Azure DevOps: wrapped by lambda/provider, which
// was tested against 0.46.0's webhook servers.
const MIN_VERSION: Partial<Record<GitProvider, number[]>> = {
  gitlab: [0, 46, 0],
  gitea: [0, 46, 0],
  bitbucket_server: [0, 46, 0],
  azure_devops: [0, 46, 0],
};
const minVersion = MIN_VERSION[gitProvider];
const tagVersion = imageTag.match(/^(\d+)\.(\d+)\.(\d+)-/)?.slice(1).map(Number);
if (minVersion && tagVersion) {
  const differs = tagVersion.findIndex((n, i) => n !== minVersion[i]);
  if (differs !== -1 && tagVersion[differs] < minVersion[differs]) {
    throw new Error(
      `${gitProvider} needs PR-Agent ${minVersion.join('.')} or newer, got ${tagVersion.join('.')}. ` +
        `Run \`make image GIT_PROVIDER=${gitProvider}\` for the newest release.`,
    );
  }
}

const providerUrl = process.env.PROVIDER_URL || undefined;
const urlSetting = PROVIDERS[gitProvider].urlSetting;
if (urlSetting?.required && !providerUrl) {
  throw new Error(`${gitProvider} needs PROVIDER_URL, e.g. PROVIDER_URL=${urlSetting.example}`);
}
if (providerUrl && !urlSetting) {
  throw new Error(`PROVIDER_URL doesn't apply to ${gitProvider}; leave it unset.`);
}

// Off only for GitHub by default. Every review outlasts a webhook timeout, and
// providers count timeouts as failed deliveries; GitLab.com disables webhooks
// that keep failing. GitHub just shows them as timed out.
const asyncSetting = (process.env.ASYNC_REVIEWS ?? '').toLowerCase();
if (!['', 'true', 'false'].includes(asyncSetting)) {
  throw new Error(`ASYNC_REVIEWS must be "true" or "false", got "${process.env.ASYNC_REVIEWS}"`);
}
const asyncReviews = asyncSetting === '' ? gitProvider !== 'github' : asyncSetting === 'true';

const reserved = process.env.RESERVED_CONCURRENCY;
if (reserved !== undefined && reserved !== '' && Number.isNaN(Number(reserved))) {
  throw new Error(`RESERVED_CONCURRENCY must be a number or empty, got "${reserved}"`);
}

const customMax = process.env.CUSTOM_MODEL_MAX_TOKENS;
if (customMax !== undefined && customMax !== '' && !(Number(customMax) > 0)) {
  throw new Error(`CUSTOM_MODEL_MAX_TOKENS must be a positive number, got "${customMax}"`);
}

const app = new cdk.App();

new PrAgentLambdaStack(app, process.env.STACK_NAME ?? 'PrAgentLambdaStack', {
  // Pinned on purpose. The Bedrock ARNs and the ECR lookup are both
  // region-specific, so a region-agnostic stack would be a trap.
  env: { account, region },

  ecrRepositoryName: process.env.ECR_REPO ?? 'pr-agent',
  imageTag,
  secretName: process.env.SECRET_NAME ?? 'pr-agent/config',
  gitProvider,
  providerUrl,
  asyncReviews,

  architecture: arch === 'arm64' ? lambda.Architecture.ARM_64 : lambda.Architecture.X86_64,

  model: process.env.MODEL ?? 'us.anthropic.claude-sonnet-4-5-20250929-v1:0',
  fallbackModel: process.env.FALLBACK_MODEL ?? 'us.anthropic.claude-haiku-4-5-20251001-v1:0',
  customModelMaxTokens: customMax ? Number(customMax) : undefined,
  inferenceRegions: (process.env.INFERENCE_REGIONS ?? 'us-east-1,us-east-2,us-west-2')
    .split(',')
    .map((r) => r.trim())
    .filter(Boolean),

  memorySize: Number(process.env.MEMORY_SIZE ?? 2048),
  reservedConcurrency:
    reserved === '' || reserved === 'none' ? undefined : Number(reserved ?? 5),

  description: `PR-Agent AI code review for ${gitProvider} on Lambda, behind a Function URL, with Bedrock`,
});
