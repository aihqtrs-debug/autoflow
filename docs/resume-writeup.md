# AutoFlow — Resume & Interview Package

**Live demo:** https://dr6j5i2t4pldu.cloudfront.net
**Architecture:** [`architecture.md`](./architecture.md) · **Diagram:** [`architecture-diagram.svg`](./architecture-diagram.svg)

---

## Resume bullet points

Pick 2–3 depending on the role. Written to lead with the AWS/architecture skill being
demonstrated, then the concrete evidence.

**For an AWS/Cloud/Solutions Architect-track role:**

> Designed and deployed AutoFlow, a serverless event-driven file-processing platform
> on AWS (S3, EventBridge, Step Functions, Lambda, DynamoDB, Cognito, API Gateway,
> CloudFront), provisioning 100% of infrastructure as code with Terraform and
> deploying via a GitHub Actions CI/CD pipeline using OIDC federated roles (no
> long-lived credentials).

> Built a 5-stage Step Functions orchestration with per-state retry policies and a
> centralized failure-handling path (SQS dead-letter queue + SNS alerting), ensuring
> every job reaches a known terminal state and no failure is silently lost.

> Implemented JWT-based authentication and authorization end-to-end using Amazon
> Cognito and API Gateway JWT authorizers, and engineered a zero-backend-proxy upload
> path using S3 presigned URLs to avoid payload-size and cost overhead on the API
> layer.

> Instrumented the full request path with AWS X-Ray distributed tracing (API Gateway →
> Lambda → Step Functions → downstream Lambdas), built a CloudWatch operations
> dashboard and 4 metric alarms wired to SNS for automated failure alerting, and
> deployed a dedicated multi-region CloudTrail audit trail plus API Gateway throttling
> and structured access logging — enterprise-grade observability and governance
> practices applied to a personal-scale project.

**For a general SWE/automation/CI-CD-leaning role (ties to current bank/release work):**

> Automated a file validation-transformation-notification pipeline (the same pattern
> used in release/batch orchestration tools like Control-M) using AWS Step Functions
> and Lambda, replacing what would traditionally be a manually-triggered batch job
> with a fully event-driven, retried, and audited workflow.

> Owned the project end-to-end: infrastructure design, IaC (Terraform), CI/CD
> (GitHub Actions), and a live, publicly-verifiable deployment — demonstrating the
> same release-engineering discipline (versioned infra, repeatable deploys, rollback
> via `terraform destroy`) applied at a personal-project scale.

---

## The 60-second verbal pitch

*"I built and deployed a serverless file-processing platform on AWS called AutoFlow —
think of it as a mini Control-M. You upload an XML, CSV, or JSON file through a web
dashboard I built, and it automatically flows through a Step Functions pipeline:
validation, transformation into a canonical format, business-rule checks, and
notification — with automatic retries and a dead-letter queue for anything that
fails. Everything's provisioned with Terraform, deployed through a GitHub Actions
CI/CD pipeline using OIDC so there are no long-lived AWS keys anywhere, and the whole
thing is live right now behind CloudFront with Cognito authentication. I built it to
go deep on the AWS services I'd use daily as a Solutions Architect, and specifically
chose the event-driven / orchestration pattern because it maps directly to the
release-automation work I already do."*

---

## Questions an interviewer will likely ask — and the honest answers

**"Why Step Functions instead of just chaining Lambdas?"**
Declarative retry and centralized error handling — every state gets the same
`Catch → HandleFailure` behavior for free, plus a full execution history/audit trail
in the console without building one. See [`architecture.md §2.2`](./architecture.md#22-step-functions-for-orchestration-not-lambda-chaining).

**"What would you do differently for production?"**
Answer with the [Honest Tradeoffs](./architecture.md#4-honest-tradeoffs) section
verbatim — remote Terraform state with locking, per-function least-privilege IAM
roles instead of one shared role, a non-root operating identity, and native WebSocket
push instead of 4-second polling. Being able to name real gaps unprompted is a
stronger signal than pretending the project is flawless.

**"How do you keep this from costing money?"**
Explain the AWS Free Plan credit window, that every service used sits inside its own
free tier at this traffic level, and that a real `aws_budgets_budget` Terraform
resource is deployed as a tracked $10/month cap with 80%/100% alert thresholds — see
[`cost-and-teardown.md`](./cost-and-teardown.md).

**"How would you scale this?"**
DynamoDB PAY_PER_REQUEST already scales to whatever load arrives. Lambda scales
horizontally by default. The one deliberate serial point is Step Functions Standard
workflows processing one file per execution — for very high throughput, the
`transform`/`apply-rules` stages could become a `Map` state to fan out, or the
pipeline could shard by upload volume across multiple state machines.

**"How would you debug a slow or failing request in this system, given it crosses
seven services?"**
This is the one question this project is specifically built to answer well. Point to
X-Ray: every Lambda and the Step Functions state machine has active tracing enabled,
so a single request shows up as one end-to-end trace/service map — API Gateway →
Lambda → EventBridge → Step Functions → the 5 pipeline Lambdas → DynamoDB/SNS/SQS —
instead of having to manually correlate timestamps across seven separate CloudWatch
Log Groups. Pair that with the CloudWatch ops dashboard (`dashboard_url` output),
which surfaces invocation/error/latency/DLQ-depth/API-error trends in one view, and
4 CloudWatch alarms that page the same SNS topic the app already uses for job
notifications — so "the system is unhealthy" and "your file finished processing"
arrive through the same channel. This is the kind of day-2 operability question a
large organization cares about far more than whether the happy path works.

**"What governance or security controls does this have, beyond IAM?"**
A dedicated multi-region CloudTrail trail logs every management-plane API call in the
account to a public-access-blocked S3 bucket with a 90-day lifecycle expiration —
the same "who did what, when, from where" audit primitive a bank's compliance or
security team requires before signing off on a workload. The public API also has a
sane default throttle (10 req/s, 20-burst) so one bad client can't exhaust Lambda
concurrency or run up cost, plus structured JSON access logs (request id, source IP,
route, status, latency) for after-the-fact investigation.

**"Walk me through what happens when a file fails validation."**
Walk through [`architecture.md §3`](./architecture.md#3-how-it-actually-works-the-practical-walkthrough)
steps 5 and 9: the `validate` Lambda raises a typed exception, Step Functions' `Catch`
on `States.ALL` routes to `HandleFailure`, which writes `status: FAILED` to DynamoDB
with the error message, publishes an SNS alert, and puts a record on the SQS DLQ —
so a human can see exactly what happened and replay it if needed.

---

## Links to have ready

- **Live app:** https://dr6j5i2t4pldu.cloudfront.net
- **GitHub repo:** _(add once pushed — see the main `README.md` for the CI/CD workflow
  that deploys from it)_
- **Architecture doc:** `docs/architecture.md` in the repo
- **CloudWatch ops dashboard:** `terraform output dashboard_url` (console link, requires
  sign-in to the AWS account — screenshot it for a slide/portfolio if showing someone
  without account access)
- **X-Ray service map:** `terraform output xray_console_url` (same access note as above)
