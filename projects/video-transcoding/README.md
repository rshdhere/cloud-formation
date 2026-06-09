# Video Transcoding Platform — Infrastructure

CloudFormation stacks for the VTP (YouTube-style video platform). This repo provisions AWS resources; application code lives in the separate `video-transcoding-pipeline` repo.

## Architecture

```text
Shared stacks (all projects)
├── shared-networking   VPC 10.0.0.0/16, public + private subnets, NAT
├── shared-security     ALB/app/proxy/DB security groups, GitHub OIDC
├── shared-database     RDS PostgreSQL Multi-AZ + RDS Proxy
├── shared-cache        ElastiCache Redis
└── shared-monitoring   CloudWatch alarms + SNS

Project stack
└── video-transcoding
    ├── Phase 1: S3, SQS+DLQ, Secrets Manager, ECR, SSM
    ├── Phase 2: ECS Fargate, ALB, WAF, IAM task roles
    └── Phase 3: CloudFront OAC, Route 53, ACM certificates
```

### Traffic flow

```text
Browser → ALB (WAF) [api.domain] → ECS API :3001
Browser → ALB [app.domain] → ECS Web :3000
Browser → CloudFront [cdn.domain] → S3 transcoded (OAC) — hls/, thumbnails/, audio/
Workers  → SQS (private subnets, no ALB)
```

## Deploy order

Stacks must be deployed in this order (the GitHub Actions workflow handles this automatically):

| Order | Stack | Phase |
|-------|-------|-------|
| 1 | `shared-networking` | Foundation |
| 2 | `shared-security` | Foundation |
| 3 | `shared-cache` | Foundation |
| 4 | `shared-database` | Foundation |
| 5 | `shared-monitoring` | Ops |
| 6 | `video-transcoding` | Phase 1-3 |

> **Deploy user IAM:** `shared-security` attaches `vtp-cloudformation-iam` to `transcoding-infra`, scoped to `vtp-*` roles/policies. Deploy `shared-security` via GitHub Actions (admin) once before local CLI can create ECS task roles.

### Manual deploy (single stack)

```bash
# Prerequisites: shared stacks already deployed
aws cloudformation deploy \
  --stack-name video-transcoding \
  --template-file projects/video-transcoding/template.yaml \
  --region ap-south-1 \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    TemplateBucketName=raashed-cf-templates-ap-south-1 \
    Environment=prod \
    DomainName=yourdomain.com \
    UploadsBucketName=vtp-uploads \
    TranscodedBucketName=vtp-transcoded \
    CorsAllowedOrigins=https://app.yourdomain.com \
    TranscodingQueueName=vtp-transcoding \
    EmailVerificationQueueName=vtp-email-verification \
    ResendFromEmail=noreply@yourdomain.com
```

Sync nested templates to S3 before deploying:

```bash
aws s3 sync projects/video-transcoding \
  s3://raashed-cf-templates-ap-south-1/projects/video-transcoding \
  --exclude "*" --include "*.yaml"
```

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `Environment` | `prod` | Environment tag (`dev`, `staging`, `prod`) |
| `DomainName` | `example.com` | Root domain for `api.`, `app.`, `cdn.` subdomains |
| `UploadsBucketName` | `vtp-uploads` | Raw uploads bucket |
| `TranscodedBucketName` | `vtp-transcoded` | HLS/thumbnail/audio output bucket |
| `CorsAllowedOrigins` | `https://app.example.com` | Browser origins for presigned PUT |
| `TranscodingQueueName` | `vtp-transcoding` | Main transcode queue |
| `EmailVerificationQueueName` | `vtp-email-verification` | Email verification queue |
| `TranscodingVisibilityTimeoutSeconds` | `1800` | 30 min visibility for long ffmpeg jobs |
| `ResendFromEmail` | `noreply@example.com` | Transactional email sender |
| `AlbCertificateArn` | _(empty)_ | Regional ACM cert for ALB HTTPS (`api.`, `app.`) |
| `CloudFrontCertificateArn` | _(empty)_ | **us-east-1** ACM cert for `cdn.` (CloudFront requirement) |
| `HostedZoneId` | _(empty)_ | Route 53 hosted zone ID — enables DNS records |
| `ApiImageTag` / `WorkerImageTag` / `WebImageTag` | `latest` | ECR image tags |
| `EnableWebService` | `true` | Deploy Next.js web on ECS |
| `ApiRateLimit` | `1000` | WAF rate limit per IP per 5 min |

Set these GitHub repository variables for CI deploys:

| Variable | Example | Notes |
|----------|---------|-------|
| `DOMAIN_NAME` | `yourdomain.com` | Root domain |
| `HOSTED_ZONE_ID` | `Z1234567890ABC` | Route 53 zone for the domain |
| `ALB_CERTIFICATE_ARN` | `arn:aws:acm:ap-south-1:...` | Regional wildcard or SAN cert |
| `CLOUDFRONT_CERTIFICATE_ARN` | `arn:aws:acm:us-east-1:...` | **Must be us-east-1** for CloudFront |

### ACM certificates (one-time setup)

```bash
# Regional cert (ap-south-1) — ALB HTTPS: api.domain, app.domain
aws acm request-certificate \
  --region ap-south-1 \
  --domain-name yourdomain.com \
  --subject-alternative-names "api.yourdomain.com" "app.yourdomain.com" "cdn.yourdomain.com" \
  --validation-method DNS

# CloudFront cert (us-east-1) — cdn.domain
aws acm request-certificate \
  --region us-east-1 \
  --domain-name "cdn.yourdomain.com" \
  --validation-method DNS
```

Add the ACM validation CNAME records to Route 53, wait for `ISSUED` status, then set the GitHub vars above.

## S3 key layout

```text
s3://vtp-uploads/uploads/{userId}/{uuid}/{filename}
s3://vtp-transcoded/
  hls/{videoId}/master.m3u8
  hls/{videoId}/{480p|720p|1080p|2160p}/playlist.m3u8
  hls/{videoId}/{resolution}/segment_*.ts
  thumbnails/{videoId}/poster.jpg
  audio/{videoId}/audio.mp3
```

Both buckets block all public access. Transcoded reads are served via CloudFront OAC only.

### CloudFront cache behaviors

| Path | TTL | Notes |
|------|-----|-------|
| `/hls/*/*/*.ts` | 1 year | Immutable segments |
| `/hls/*/*.m3u8`, `/hls/*/master.m3u8` | 60s | Playlists |
| `/thumbnails/*` | 7 days | Poster images |
| `/audio/*` | 24 hours | MP3 delivery |

S3 bucket policy allows `s3:GetObject` from CloudFront **only** on `hls/*`, `thumbnails/*`, and `audio/*` prefixes.

## Stack outputs

| Output | Used by |
|--------|---------|
| `S3UploadBucketName` | API/worker `S3_UPLOAD_BUCKET` |
| `S3TranscodedBucketName` | API/worker `S3_TRANSCODED_BUCKET` |
| `SqsTranscodingQueueUrl` | API/worker `SQS_TRANSCODING_QUEUE_URL` |
| `SqsEmailVerificationQueueUrl` | API/worker `SQS_EMAIL_VERIFICATION_QUEUE_URL` |
| `RdsProxyEndpoint` | `DB_HOST` on API/worker ECS tasks |
| `DatabaseSecretArn` | RDS-managed `DB_USERNAME` / `DB_PASSWORD` injection |
| `BetterAuthSecretArn` | `BETTER_AUTH_SECRET` injection |
| `ResendApiKeySecretArn` | `RESEND_API_KEY` injection |
| `EcrApiRepositoryUri` | CI image push + ECS task def |
| `EcrWorkerRepositoryUri` | CI image push + ECS task def |
| `EcrWebRepositoryUri` | CI image push + ECS task def |
| `ApiPublicUrl` | `BETTER_AUTH_URL` |
| `WebPublicUrl` | `TRUSTED_ORIGINS` |
| `CloudFrontDomainName` | `CLOUDFRONT_DOMAIN` on API ECS task |
| `CloudFrontDistributionId` | Monitoring, debugging |
| `AlbDnsName` | Route 53 `app.` alias target |
| `ApiEndpoint` | Public API URL (`api.domain` or ALB DNS until Route 53 wired) |
| `WebAclArn` | Regional WAF WebACL on the ALB |
| `EcsClusterName` | ECS cluster (`vtp-prod`) |
| `ApiTaskRoleArn` / `WorkerTaskRoleArn` | IAM task roles (no static AWS keys) |
| `RedisCacheEndpoint` | Future session/cache wiring |

## SSM parameter layout

All parameters are under `/vtp/{Environment}/`:

```text
/vtp/prod/s3/upload-bucket
/vtp/prod/s3/transcoded-bucket
/vtp/prod/sqs/transcoding-queue-url
/vtp/prod/sqs/email-verification-queue-url
/vtp/prod/rds/proxy-endpoint
/vtp/prod/rds/database-secret-arn
/vtp/prod/ecr/api-repository-uri
/vtp/prod/ecr/worker-repository-uri
/vtp/prod/ecr/web-repository-uri
/vtp/prod/secrets/auth-arn
/vtp/prod/secrets/resend-arn
/vtp/prod/urls/api-public-url
/vtp/prod/urls/web-public-url
/vtp/prod/urls/cloudfront-domain
/vtp/prod/alb/dns-name
/vtp/prod/cloudfront/distribution-id
```

Read at deploy time:

```bash
aws ssm get-parameter --name /vtp/prod/s3/upload-bucket --query Parameter.Value --output text
```

## Secrets Manager

```text
┌─────────────────┐
│ Secrets Manager │
└──────┬──────────┘
       │
       ├── vtp/prod/auth          (BETTER_AUTH_SECRET — auto-generated)
       ├── vtp/prod/resend        (RESEND_API_KEY — set after deploy)
       └── RDS managed secret     (DB_USERNAME / DB_PASSWORD — auto-managed)
              │
              ▼
┌─────────────────┐
│   RDS Proxy     │
└──────┬──────────┘
       │
       ▼
┌─────────────────┐
│ ECS API/Worker  │
└─────────────────┘
```

| Secret | Path | Notes |
|--------|------|-------|
| `BETTER_AUTH_SECRET` | `vtp/prod/auth` | Auto-generated 64-char secret |
| `RESEND_API_KEY` | `vtp/prod/resend` | Placeholder — update after deploy |
| `DB_USERNAME` / `DB_PASSWORD` | RDS-managed secret | `ManageMasterUserPassword: true` — no manual password handling |

RDS creates and rotates the database password. ECS tasks receive `DB_USERNAME` and `DB_PASSWORD` via Secrets Manager JSON key references; `DB_HOST`, `DB_NAME`, and `DB_PORT` are plain environment variables pointing at RDS Proxy.

**Do not store:** `DATABASE_URL`, `JWT_SECRET`, `API_KEY`, `AWS_ACCESS_KEY_ID`, or `AWS_SECRET_ACCESS_KEY` in Secrets Manager. Use IAM task roles for AWS API access.

### Update RESEND_API_KEY

```bash
aws secretsmanager put-secret-value \
  --secret-id vtp/prod/resend \
  --secret-string "re_your_actual_key"
```

## ECS services (Phase 2 — provisioned by CloudFormation)

| Service | Cluster | Port | ALB | Autoscaling |
|---------|---------|------|-----|-------------|
| `vtp-prod-api` | `vtp-prod` | 3001 | Yes (`/health`) | Fixed desired count |
| `vtp-prod-worker` | `vtp-prod` | — | No | SQS depth (target 5 msgs/task) |
| `vtp-prod-web` | `vtp-prod` | 3000 | Yes (`/`) | Fixed desired count |

Task definitions inject all env vars and Secrets Manager values automatically. IAM task roles replace static AWS keys.

### Push container images

```bash
AWS_REGION=ap-south-1
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# From the application repo after building images
for APP in api worker web; do
  ECR_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/vtp-${APP}"
  aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
  docker tag "vtp-${APP}:latest" "${ECR_URI}:latest"
  docker push "${ECR_URI}:latest"
done

# Force new deployment after push
aws ecs update-service --cluster vtp-prod --service vtp-prod-api --force-new-deployment
aws ecs update-service --cluster vtp-prod --service vtp-prod-worker --force-new-deployment
aws ecs update-service --cluster vtp-prod --service vtp-prod-web --force-new-deployment
```

Set GitHub vars `API_IMAGE_TAG`, `WORKER_IMAGE_TAG`, `WEB_IMAGE_TAG` to pin versions in CI.

## ECS task definition reference

Use IAM task roles — do **not** set `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`.

### API task — environment variables

```json
{
  "environment": [
    { "name": "BETTER_AUTH_URL", "value": "https://api.yourdomain.com" },
    { "name": "TRUSTED_ORIGINS", "value": "https://app.yourdomain.com,https://api.yourdomain.com" },
    { "name": "SERVER_PORT", "value": "3001" },
    { "name": "AWS_ENABLED", "value": "true" },
    { "name": "AWS_REGION", "value": "ap-south-1" },
    { "name": "S3_UPLOAD_BUCKET", "value": "vtp-uploads" },
    { "name": "S3_TRANSCODED_BUCKET", "value": "vtp-transcoded" },
    { "name": "SQS_TRANSCODING_QUEUE_URL", "value": "<from stack output>" },
    { "name": "SQS_EMAIL_VERIFICATION_QUEUE_URL", "value": "<from stack output>" },
    { "name": "CLOUDFRONT_DOMAIN", "value": "cdn.yourdomain.com" },
    { "name": "TRANSCODING_RESOLUTIONS", "value": "480p,720p,1080p,2160p,mp3" },
    { "name": "MAX_DAILY_DOWNLOADS", "value": "10" },
    { "name": "UPLOAD_COOLDOWN_SECONDS", "value": "30" },
    { "name": "MAIL_ENABLED", "value": "true" },
    { "name": "RESEND_FROM_EMAIL", "value": "noreply@yourdomain.com" },
    { "name": "DB_HOST", "value": "<rds-proxy-endpoint>" },
    { "name": "DB_NAME", "value": "transcodingDB" },
    { "name": "DB_PORT", "value": "5432" }
  ],
  "secrets": [
    { "name": "DB_USERNAME", "valueFrom": "arn:aws:secretsmanager:...:rds!cluster-...:username::" },
    { "name": "DB_PASSWORD", "valueFrom": "arn:aws:secretsmanager:...:rds!cluster-...:password::" },
    { "name": "BETTER_AUTH_SECRET", "valueFrom": "arn:aws:secretsmanager:...:secret:vtp/prod/auth:secret::" },
    { "name": "RESEND_API_KEY", "valueFrom": "arn:aws:secretsmanager:...:secret:vtp/prod/resend" }
  ]
}
```

### Worker task — environment variables

```json
{
  "environment": [
    { "name": "WORKERS_TRANSCODE_ENABLED", "value": "true" },
    { "name": "WORKERS_EMAIL_ENABLED", "value": "true" },
    { "name": "WORKERS_MAX_CONCURRENT_POLLS", "value": "3" },
    { "name": "THUMBNAIL_SEEK_SECONDS", "value": "5" },
    { "name": "TRANSCODING_RESOLUTIONS", "value": "480p,720p,1080p,2160p,mp3" },
    { "name": "FFMPEG_PATH", "value": "ffmpeg" },
    { "name": "S3_UPLOAD_BUCKET", "value": "vtp-uploads" },
    { "name": "S3_TRANSCODED_BUCKET", "value": "vtp-transcoded" },
    { "name": "SQS_TRANSCODING_QUEUE_URL", "value": "<from stack output>" },
    { "name": "SQS_EMAIL_VERIFICATION_QUEUE_URL", "value": "<from stack output>" },
    { "name": "WORKERS_VERIFICATION_URL", "value": "https://api.yourdomain.com/api/v1/auth/verify-email" },
    { "name": "MAIL_ENABLED", "value": "true" },
    { "name": "RESEND_FROM_EMAIL", "value": "noreply@yourdomain.com" },
    { "name": "DB_HOST", "value": "<rds-proxy-endpoint>" },
    { "name": "DB_NAME", "value": "transcodingDB" },
    { "name": "DB_PORT", "value": "5432" }
  ],
  "secrets": [
    { "name": "DB_USERNAME", "valueFrom": "arn:aws:secretsmanager:...:rds!cluster-...:username::" },
    { "name": "DB_PASSWORD", "valueFrom": "arn:aws:secretsmanager:...:rds!cluster-...:password::" },
    { "name": "RESEND_API_KEY", "valueFrom": "arn:aws:secretsmanager:...:secret:vtp/prod/resend" }
  ]
}
```

### Web task

```json
{
  "environment": [
    { "name": "API_URL", "value": "https://api.yourdomain.com" }
  ]
}
```

## Database migrations

Run migrations from the app repo (`packages/drizzle`) against RDS Proxy — not embedded in this infra repo.

**Option A — one-off ECS task** (after Phase 2):

```bash
# Run migration container with DB_* env vars + RDS secret, same VPC/subnets as API
aws ecs run-task \
  --cluster vtp-prod \
  --task-definition vtp-migrate \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-xxx],securityGroups=[sg-xxx]}"
```

**Option B — CI step** (from a runner with VPC access or SSM port-forward):

```bash
DB_HOST="<proxy-endpoint>" DB_NAME=transcodingDB DB_PORT=5432 \
  DB_USERNAME=postgres DB_PASSWORD="<from-rds-secret>" bun run db:migrate
```

## Post-deploy checklist

- [ ] Set GitHub variable `DOMAIN_NAME` to your real domain
- [ ] Populate `vtp/prod/resend` secret
- [ ] Push container images to ECR (`vtp-api`, `vtp-worker`, `vtp-web`)
- [ ] Run DB migrations via app repo
- [ ] Request ACM certs (regional + us-east-1) and complete DNS validation
- [ ] Set `ALB_CERTIFICATE_ARN`, `CLOUDFRONT_CERTIFICATE_ARN`, `HOSTED_ZONE_ID` GitHub vars
- [ ] Redeploy stack — Route 53 records created automatically when `HOSTED_ZONE_ID` is set
- [ ] Confirm `CLOUDFRONT_DOMAIN=cdn.<domain>` on API task (already set via ECS task def)

## Smoke test

### Health check

```bash
# API (WAF-protected ALB, via api.domain)
curl -sf "https://api.yourdomain.com/health"

# Or interim ALB DNS (HTTP until ACM + Route 53 are configured)
curl -sf "http://$(aws ssm get-parameter --name /vtp/prod/alb/dns-name --query Parameter.Value --output text)/health" \
  -H "Host: api.yourdomain.com"
```

1. `GET /health` returns 200
2. ECS services show running tasks: `aws ecs describe-services --cluster vtp-prod --services vtp-prod-api vtp-prod-worker`

### Full pipeline

3. Presigned PUT to `vtp-uploads` succeeds from `https://app.<domain>` (CORS)
4. Worker consumes SQS message, writes `hls/`, `thumbnails/`, `audio/` objects
5. `https://cdn.<domain>/thumbnails/{videoId}/poster.jpg` loads via CloudFront
6. `https://cdn.<domain>/hls/{videoId}/720p/playlist.m3u8` loads via CloudFront

```bash
# Verify CloudFront serves an object (after worker writes output)
curl -sI "https://cdn.yourdomain.com/thumbnails/VIDEO_ID/poster.jpg"
# Expect: HTTP/2 200, x-cache: Hit from cloudfront
```

## Phase roadmap

| Phase | Status | Resources |
|-------|--------|-----------|
| **1 — Foundation** | Implemented | S3, SQS+DLQ, Secrets, ECR, SSM |
| **2 — Compute** | Implemented | ECS Fargate, ALB, WAF, IAM task roles, worker autoscaling |
| **3 — CDN** | Implemented | CloudFront OAC, S3 bucket policy, Route 53 (`api.`, `app.`, `cdn.`) |
| **4 — Ops** | Implemented | DLQ, ECS, CloudFront 5xx alarms via shared SNS |
