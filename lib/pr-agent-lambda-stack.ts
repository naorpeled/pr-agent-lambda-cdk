import * as cdk from 'aws-cdk-lib';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as ecr from 'aws-cdk-lib/aws-ecr';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import * as logs from 'aws-cdk-lib/aws-logs';
import { Construct } from 'constructs';

/**
 * Turns a cross-region inference profile id into the foundation model id it
 * wraps: "us.anthropic.claude-..." -> "anthropic.claude-...". Only strips a
 * known geography prefix, so a plain model id passes through untouched.
 */
function stripGeoPrefix(modelId: string): string {
  return modelId.replace(/^(us|eu|apac|ap|jp|au|ca|sa|global)\./, '');
}

export interface PrAgentLambdaStackProps extends cdk.StackProps {
  /** ECR repository the image was pushed to. See scripts/push-image.sh. */
  readonly ecrRepositoryName: string;
  /** Image tag in that repository, e.g. "0.46.0-github_lambda". */
  readonly imageTag: string;
  /** Secrets Manager secret holding the GitHub App credentials. */
  readonly secretName: string;
  /**
   * Must match the platform you pulled in push-image.sh. A mismatch deploys
   * fine and then fails at runtime with an exec format error.
   */
  readonly architecture: lambda.Architecture;
  /** Primary Bedrock model id. "us." prefix means cross-region inference profile. */
  readonly model: string;
  /** Model tried when the primary one raises. */
  readonly fallbackModel: string;
  /**
   * Context size to assume for models PR-Agent doesn't list in its own token
   * table, such as DeepSeek on Bedrock. Without it PR-Agent refuses to run
   * those models. Still clamped by max_model_tokens.
   */
  readonly customModelMaxTokens?: number;
  /**
   * Every region the inference profile can route to. Confirm with:
   *   aws bedrock get-inference-profile --inference-profile-identifier <model>
   */
  readonly inferenceRegions: string[];
  /** Lambda memory in MB. Memory buys CPU, 2 GB is a reasonable spot for this. */
  readonly memorySize: number;
  /**
   * Caps concurrent reviews. Set to undefined on accounts still holding the
   * default concurrency quota of 10, where reserving anything fails the deploy.
   */
  readonly reservedConcurrency?: number;
}

export class PrAgentLambdaStack extends cdk.Stack {
  public readonly functionUrl: lambda.FunctionUrl;

  constructor(scope: Construct, id: string, props: PrAgentLambdaStackProps) {
    super(scope, id, props);

    const repo = ecr.Repository.fromRepositoryName(this, 'PrAgentRepo', props.ecrRepositoryName);

    // Flat dotted keys, e.g. { "github.app_id": "...", "github.private_key": "..." }.
    // PR-Agent reads this at cold start and merges it into its Dynaconf settings.
    const config = secretsmanager.Secret.fromSecretNameV2(this, 'PrAgentConfig', props.secretName);

    const fn = new lambda.DockerImageFunction(this, 'PrAgentFunction', {
      code: lambda.DockerImageCode.fromEcr(repo, { tagOrDigest: props.imageTag }),
      architecture: props.architecture,
      memorySize: props.memorySize,
      // The review runs to completion inside the invocation. See the README.
      timeout: cdk.Duration.minutes(5),
      reservedConcurrentExecutions: props.reservedConcurrency,
      // Lambda log groups never expire by default.
      logGroup: new logs.LogGroup(this, 'PrAgentLogs', {
        retention: logs.RetentionDays.ONE_MONTH,
        removalPolicy: cdk.RemovalPolicy.DESTROY,
      }),
      environment: {
        // Env vars can't contain dots, and Dynaconf reads SECTION__KEY into section.key.
        CONFIG__GIT_PROVIDER: 'github',
        CONFIG__PUBLISH_OUTPUT: 'true',
        CONFIG__MODEL: `bedrock/${props.model}`,
        CONFIG__FALLBACK_MODELS: `["bedrock/${props.fallbackModel}"]`,
        // Default is 32000, which would waste most of a 200K context window.
        CONFIG__MAX_MODEL_TOKENS: '128000',
        ...(props.customModelMaxTokens
          ? { CONFIG__CUSTOM_MODEL_MAX_TOKENS: String(props.customModelMaxTokens) }
          : {}),
        CONFIG__SECRET_PROVIDER: 'aws_secrets_manager',
        AWS_SECRETS_MANAGER__SECRET_ARN: config.secretArn,
        // Read straight from the process env by PR-Agent's model layer. On Lambda
        // it makes boto3 resolve the execution role credentials the runtime
        // injects, so there are no static keys anywhere.
        AWS_USE_IMDS: 'true',
        AWS_REGION_NAME: this.region,
        // /tmp is the only writable path in a Lambda container.
        AZURE_DEVOPS_CACHE_DIR: '/tmp',
        HOME: '/tmp',
      },
    });

    config.grantRead(fn);

    // Bedrock needs two statements, not one.
    // 1. the cross-region inference profile, in your account
    fn.addToRolePolicy(
      new iam.PolicyStatement({
        actions: ['bedrock:InvokeModel', 'bedrock:InvokeModelWithResponseStream'],
        resources: [props.model, props.fallbackModel].map(
          (m) => `arn:aws:bedrock:${this.region}:${this.account}:inference-profile/${m}`,
        ),
      }),
    );

    // 2. the underlying foundation models, in every region the profile can route
    //    to. Foundation-model ARNs have an empty account field. Skip this and
    //    every call fails with AccessDenied.
    fn.addToRolePolicy(
      new iam.PolicyStatement({
        actions: ['bedrock:InvokeModel', 'bedrock:InvokeModelWithResponseStream'],
        resources: props.inferenceRegions.flatMap((r) =>
          [props.model, props.fallbackModel].map(
            (m) => `arn:aws:bedrock:${r}::foundation-model/${stripGeoPrefix(m)}`,
          ),
        ),
      }),
    );

    // GitHub can't sign requests with SigV4, and PR-Agent verifies the webhook
    // HMAC itself, rejecting unsigned requests (and, since v0.44.0, rejecting
    // everything when no webhook secret is configured).
    this.functionUrl = fn.addFunctionUrl({ authType: lambda.FunctionUrlAuthType.NONE });

    new cdk.CfnOutput(this, 'FunctionUrl', {
      value: this.functionUrl.url,
      description: 'Health check. GET this, expect {"status":"ok"}.',
    });
    new cdk.CfnOutput(this, 'WebhookUrl', {
      value: `${this.functionUrl.url}api/v1/github_webhooks`,
      description: "Paste this into your GitHub App's webhook URL.",
    });
    new cdk.CfnOutput(this, 'LogGroup', {
      value: fn.logGroup.logGroupName,
      description: 'aws logs tail <this> --follow',
    });
  }
}
