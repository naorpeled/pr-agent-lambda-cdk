#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import { PrAgentLambdaStack } from '../lib/pr-agent-lambda-stack';

/**
 * Everything here is overridable by environment variable so the Makefile can
 * drive it. The defaults are the ones from the blog post.
 */
const region = process.env.AWS_REGION ?? process.env.CDK_DEFAULT_REGION ?? 'us-east-1';
const account = process.env.CDK_DEFAULT_ACCOUNT;

const arch = (process.env.ARCH ?? 'amd64').toLowerCase();
if (arch !== 'amd64' && arch !== 'arm64') {
  throw new Error(`ARCH must be "amd64" or "arm64", got "${arch}"`);
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
  imageTag: process.env.IMAGE_TAG ?? '0.41.0-github_lambda',
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
