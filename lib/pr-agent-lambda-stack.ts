import * as cdk from 'aws-cdk-lib';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as ecr from 'aws-cdk-lib/aws-ecr';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import * as logs from 'aws-cdk-lib/aws-logs';
import { Construct } from 'constructs';
import * as fs from 'fs';
import * as path from 'path';

export type GitProvider = 'github' | 'gitlab' | 'gitea' | 'bitbucket_server' | 'azure_devops';

interface ProviderSpec {
  /** Value of PR-Agent's config.git_provider. */
  readonly configName: string;
  /** Path PR-Agent's webhook server listens on, relative to the Function URL. */
  readonly webhookPath: string;
  /** Header every genuine delivery carries; the async receiver refuses requests without it. */
  readonly authHeader: string;
  /**
   * The setting PROVIDER_URL goes into, as an env var. These all have to be env
   * vars rather than secret keys: PR-Agent only applies secret keys to settings
   * that are still unset, and some of these have defaults.
   */
  readonly urlSetting?: { env: string; required: boolean; example: string };
  /** Where the provider's webhook settings live, for the stack output's hint. */
  readonly webhookHint: string;
}

/** Per-provider differences. Everything else about the deployment is shared. */
export const PROVIDERS: Record<GitProvider, ProviderSpec> = {
  // HMAC in X-Hub-Signature-256, checked against github.webhook_secret.
  github: {
    configName: 'github',
    webhookPath: 'api/v1/github_webhooks',
    authHeader: 'x-hub-signature-256',
    webhookHint: "your GitHub App's webhook URL",
  },
  // X-Gitlab-Token, compared against gitlab.shared_secret.
  gitlab: {
    configName: 'gitlab',
    webhookPath: 'webhook',
    authHeader: 'x-gitlab-token',
    urlSetting: { env: 'GITLAB__URL', required: false, example: 'https://gitlab.example.com' },
    webhookHint: "the project's or group's webhook settings",
  },
  // HMAC in X-Gitea-Signature, checked against gitea.webhook_secret.
  gitea: {
    configName: 'gitea',
    webhookPath: 'api/v1/gitea_webhooks',
    authHeader: 'x-gitea-signature',
    urlSetting: { env: 'GITEA__URL', required: false, example: 'https://gitea.example.com' },
    webhookHint: "the repository's or organization's webhook settings",
  },
  // HMAC in X-Hub-Signature, checked against bitbucket_server.webhook_secret.
  bitbucket_server: {
    configName: 'bitbucket_server',
    webhookPath: 'webhook',
    authHeader: 'x-hub-signature',
    urlSetting: { env: 'BITBUCKET_SERVER__URL', required: true, example: 'https://bitbucket.example.com' },
    webhookHint: "the repository's webhook settings",
  },
  // HTTP basic auth, checked against azure_devops_server.webhook_username/password.
  azure_devops: {
    configName: 'azure',
    webhookPath: '',
    authHeader: 'authorization',
    urlSetting: { env: 'AZURE_DEVOPS__ORG', required: true, example: 'https://dev.azure.com/your-org' },
    webhookHint: "a Service Hook subscription (Web Hooks) in the project settings",
  },
};

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
  /** Secrets Manager secret holding the git provider credentials. */
  readonly secretName: string;
  /** Which webhook handler the image runs. Must match the image flavor. */
  readonly gitProvider: GitProvider;
  /**
   * Server or organization URL: self-managed GitLab or Gitea, the Bitbucket Data
   * Center server, or the Azure DevOps organization. See PROVIDERS.
   */
  readonly providerUrl?: string;
  /**
   * Put a small receiver in front that invokes PR-Agent asynchronously and
   * answers the webhook immediately. Required on GitLab.com, which disables
   * webhooks that keep timing out; optional on GitHub.
   */
  readonly asyncReviews: boolean;
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
   * Context size to assume for a model that neither PR-Agent's token table nor
   * LiteLLM knows. Since 0.45.0 PR-Agent falls back to LiteLLM, so most models,
   * DeepSeek on Bedrock included, don't need it. Still clamped by max_model_tokens.
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
    // scripts/create-secret.sh builds it for each provider.
    // PR-Agent reads this at cold start and merges it into its Dynaconf settings.
    const config = secretsmanager.Secret.fromSecretNameV2(this, 'PrAgentConfig', props.secretName);

    const fn = new lambda.DockerImageFunction(this, 'PrAgentFunction', {
      code: lambda.DockerImageCode.fromEcr(repo, { tagOrDigest: props.imageTag }),
      architecture: props.architecture,
      memorySize: props.memorySize,
      // The review runs to completion inside the invocation. Large PRs and slow
      // fallback chains can take minutes, so use Lambda's maximum.
      timeout: cdk.Duration.minutes(15),
      description: `PR-Agent ${props.gitProvider} reviews (${props.imageTag})`,
      reservedConcurrentExecutions: props.reservedConcurrency,
      // Lambda log groups never expire by default.
      logGroup: new logs.LogGroup(this, 'PrAgentLogs', {
        retention: logs.RetentionDays.ONE_MONTH,
        removalPolicy: cdk.RemovalPolicy.DESTROY,
      }),
      environment: {
        // Env vars can't contain dots, and Dynaconf reads SECTION__KEY into section.key.
        CONFIG__GIT_PROVIDER: PROVIDERS[props.gitProvider].configName,
        ...(props.providerUrl && PROVIDERS[props.gitProvider].urlSetting
          ? { [PROVIDERS[props.gitProvider].urlSetting!.env]: props.providerUrl }
          : {}),
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

    const provider = PROVIDERS[props.gitProvider];

    // Providers can't sign requests with SigV4, so the URL is public and
    // PR-Agent authenticates each webhook itself: an HMAC signature, a shared
    // token or basic auth, depending on the provider. scripts/create-secret.sh
    // refuses to store a config without those credentials.
    if (props.asyncReviews) {
      // Reviews arrive as async events. Lambda retries failed async events
      // twice by default, which here would mean duplicate review comments.
      fn.configureAsyncInvoke({ retryAttempts: 0, maxEventAge: cdk.Duration.hours(1) });

      const receiver = new lambda.Function(this, 'WebhookReceiver', {
        runtime: lambda.Runtime.PYTHON_3_13,
        architecture: lambda.Architecture.ARM_64,
        handler: 'index.handler',
        // Inlined into the template, so there's still no asset to upload.
        code: lambda.Code.fromInline(
          fs.readFileSync(path.join(__dirname, '..', 'lambda', 'receiver', 'index.py'), 'utf8'),
        ),
        memorySize: 256,
        // Long enough for a health check to wait out a PR-Agent cold start.
        timeout: cdk.Duration.seconds(30),
        description: `Answers ${props.gitProvider} webhooks and hands them to PR-Agent asynchronously`,
        logGroup: new logs.LogGroup(this, 'ReceiverLogs', {
          retention: logs.RetentionDays.ONE_MONTH,
          removalPolicy: cdk.RemovalPolicy.DESTROY,
        }),
        environment: {
          WORKER_FUNCTION: fn.functionArn,
          AUTH_HEADER: provider.authHeader,
        },
      });
      fn.grantInvoke(receiver);
      this.functionUrl = receiver.addFunctionUrl({ authType: lambda.FunctionUrlAuthType.NONE });
    } else {
      this.functionUrl = fn.addFunctionUrl({ authType: lambda.FunctionUrlAuthType.NONE });
    }

    new cdk.CfnOutput(this, 'FunctionUrl', {
      value: this.functionUrl.url,
      description: 'Health check. GET this, expect {"status":"ok"}.',
    });
    new cdk.CfnOutput(this, 'WebhookUrl', {
      value: `${this.functionUrl.url}${provider.webhookPath}`,
      description: `Paste this into ${provider.webhookHint}.`,
    });
    new cdk.CfnOutput(this, 'LogGroup', {
      value: fn.logGroup.logGroupName,
      description: 'PR-Agent logs. aws logs tail <this> --follow',
    });
  }
}
