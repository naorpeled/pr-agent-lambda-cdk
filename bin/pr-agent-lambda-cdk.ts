#!/usr/bin/env node
import * as fs from 'fs';
import * as path from 'path';
import * as cdk from 'aws-cdk-lib';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import { PrAgentLambdaStack } from '../lib/pr-agent-lambda-stack';

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

  description: 'PR-Agent AI code review on Lambda, behind a Function URL, with Bedrock',
});
