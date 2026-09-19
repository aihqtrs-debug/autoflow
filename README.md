# AutoFlow

A serverless file-processing and orchestration platform on AWS — upload an XML, CSV, or JSON file and watch it move automatically through validation, transformation, business-rule checks, and notification, with full retry/error handling, live status, and a real ops dashboard.

Built as a portfolio project to demonstrate hands-on AWS Solutions Architect skills: event-driven serverless architecture, Infrastructure as Code, least-privilege IAM, and CI/CD.

## Live demo

- App: `https://<cloudfront-domain>` (see Terraform output `cloudfront_domain`)
- Sign up with any email, confirm via the emailed code, upload a file, watch it process.

## Architecture

See `docs/architecture.md` for the full blueprint and diagram.

**In one sentence:** a file lands in S3 → EventBridge fires → Step Functions runs a 4-stage Lambda pipeline (validate → transform → apply rules → store & notify) with retries and a Catch-based failure path → results in DynamoDB, notifications via SNS, failures parked in an SQS dead-letter queue for review → a Cognito-authenticated React-free dashboard on S3/CloudFront polls the API for live status.

## Services used

| Service | Role |
|---|---|
| S3 | File landing zone + static frontend hosting |
| EventBridge | Event-driven trigger (the "automation" layer) |
| Step Functions | Pipeline orchestration, retries, error handling |
| Lambda (Python) | Validate, transform, apply rules, store & notify, handle failure |
| DynamoDB | Job status/history table |
| Cognito | User sign-up/sign-in |
| API Gateway (HTTP API) | REST API, Cognito JWT-protected |
| SNS | Job completion/failure notifications |
| SQS | Dead-letter queue for failed jobs |
| CloudFront | HTTPS CDN in front of the frontend |
| CloudWatch Logs | Logs for every Lambda + Step Functions execution history |
| CloudWatch Dashboard | Single-pane-of-glass ops view (invocations, errors, latency, DLQ depth, API 4xx/5xx) |
| CloudWatch Alarms | 4 alarms → SNS: pipeline failures, Step Functions failures, non-empty DLQ, API 5xx |
| X-Ray | End-to-end distributed tracing across API Gateway → Lambda → Step Functions → Lambda |
| CloudTrail | Multi-region audit trail of every management-plane API call, 90-day log retention |
| API Gateway throttling + access logs | Rate limiting (10 rps / 20 burst) + structured JSON access logs |
| AWS Budgets | $10/month tracked cap with 80%/100% alerts |
| Terraform | 100% Infrastructure as Code |
| GitHub Actions | CI/CD — deploys on every push to main |

## Repo layout

```
autoflow/
  terraform/     # all infrastructure, one `terraform apply` deploys everything
  lambda/        # one folder per Lambda function
  frontend/      # the dashboard (single static HTML/JS file)
  docs/          # architecture blueprint, CI/CD setup, cost/teardown, resume writeup
  .github/workflows/deploy.yml
```

## Running it yourself

```
cd terraform
terraform init
terraform plan
terraform apply
```

Then sync `frontend/index.html` (with the Terraform outputs filled in) to the `frontend_bucket` output and invalidate CloudFront.

## Cost

Everything here runs inside the AWS Free Tier at hobby-project scale. See `docs/cost-and-teardown.md` for the billing alarm setup and full teardown instructions (`terraform destroy`).

## Observability & governance

- **Dashboard:** `terraform output dashboard_url` — invocations, errors, p50/p99 latency, Step Functions executions, DynamoDB capacity, DLQ depth, and API Gateway traffic, all on one CloudWatch dashboard.
- **Distributed tracing:** `terraform output xray_console_url` — X-Ray active tracing is on for every Lambda and the Step Functions state machine, so a single request's full path (API Gateway → Lambda → EventBridge → Step Functions → 5 Lambdas → DynamoDB/SNS/SQS) is visible as one trace/service map.
- **Alerting:** 4 CloudWatch alarms (pipeline failure, Step Functions execution failure, non-empty DLQ, API 5xx) fire into the same SNS topic used for job notifications.
- **Audit trail:** a multi-region CloudTrail trail logs every management-plane API call in the account (who did what, when, from where), stored in a dedicated, public-access-blocked S3 bucket with a 90-day lifecycle expiration.
- **API governance:** throttling (10 req/s steady, 20 burst) and structured JSON access logs on every API Gateway request.

## CI/CD

GitHub Actions deploys on every push to `main`, authenticating to AWS via OIDC
federation (no stored access keys). See `docs/ci-cd-setup.md` for the exact one-time
setup — remote Terraform state (S3 + DynamoDB lock table) plus a repo/branch-scoped
IAM deploy role (`terraform/github_oidc.tf`).

## What I'd do differently in production

See `docs/architecture.md#honest-tradeoffs` — per-function IAM roles and a non-root operating identity are the top two remaining. Remote state, observability, and native WebSocket push (instead of polling) have all been addressed — see above and the tradeoffs doc for what's still partial.
