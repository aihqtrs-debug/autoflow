# AutoFlow — Architecture Blueprint

**Live app:** https://dr6j5i2t4pldu.cloudfront.net
**Diagram:** [`architecture-diagram.svg`](./architecture-diagram.svg)
**Region:** ap-southeast-2 (Sydney) · **IaC:** Terraform, 100% of the infrastructure below

---

## 1. What this is, in one sentence

A file lands in S3 → EventBridge fires → Step Functions runs a 4-stage Lambda pipeline
(validate → transform → apply rules → store & notify) with automatic retries and a
Catch-based failure path → results land in DynamoDB, a success notification goes out
over SNS, failures are parked on an SQS dead-letter queue for review → a
Cognito-authenticated dashboard served from S3/CloudFront polls the API for live status.

It's a small, real "mini Control-M": instead of a human kicking off a batch job and
watching a screen, an event kicks off an orchestrated, retried, auditable workflow —
which is exactly the pattern behind release automation and scheduled batch processing,
just rebuilt as managed, serverless AWS primitives instead of an on-prem scheduler.

---

## 2. Why this design (the theory)

### 2.1 Event-driven, not polling
The pipeline starts from an **S3 → EventBridge "Object Created"** rule, not from the
frontend calling an API to "start a job." This matters because it decouples the trigger
from the actor: anything that can write to the `incoming/` prefix of the uploads bucket
(the web app today, a batch script or a partner's SFTP-to-S3 sync tomorrow) kicks off
the same pipeline without code changes. This is the same principle behind
event-driven release pipelines — a merge, not a person, triggers the build.

### 2.2 Step Functions for orchestration, not Lambda-chaining
Each pipeline stage is a small, single-purpose Lambda. They're wired together with a
**Step Functions Standard workflow**, not by having one Lambda invoke the next. Reasons:

- **Retries are declarative.** Each state has a `Retry` block (2 attempts, exponential
  backoff) for transient AWS errors (`Lambda.TooManyRequestsException`,
  `Lambda.ServiceException`) — no hand-rolled retry loops in application code.
- **Failure handling is centralized.** Every state has a `Catch` on `States.ALL` routing
  to a single `HandleFailure` state — one place that always runs on any failure, so a
  failed job always ends in a known state (DynamoDB `FAILED`, an SNS alert, and a
  message on the DLQ), never silently disappears.
- **Execution history is free.** Every run is visible in the Step Functions console
  (and CloudWatch Logs) with full input/output per state — the audit trail a batch
  operator would expect from Control-M, without building one.
- **Fan-out later is easy.** If a stage needed to run for 100 files in parallel, that's
  a `Map` state, not a rewrite.

### 2.3 DynamoDB, single-table, PAY_PER_REQUEST
One table (`jobs`), partition key `user_id`, sort key `job_id`. A GSI on `status` lets
the (unused today, but wired) "show me all FAILED jobs across users" query run without
a table scan. PAY_PER_REQUEST billing means idle cost is genuinely $0 — the right choice
for a portfolio project with bursty, low, unpredictable traffic.

### 2.4 Cognito + raw HTTP calls, not the Amplify SDK
The frontend is one dependency-free HTML file. Rather than pull in the (fairly large)
AWS Amplify or Cognito Identity SDK, it calls the Cognito Identity Provider API directly
over `fetch()` with the `X-Amz-Target` header contract. This keeps the frontend
auditable in one file and loads instantly — a deliberate trade of "less abstraction" for
"nothing to explain away in an interview."

### 2.5 Presigned URLs, not proxying bytes through API Gateway
The browser never uploads file bytes to a Lambda. It asks `POST /upload-url` for a
short-lived (5 minute) presigned S3 PUT URL, then `PUT`s the file straight to S3. This
avoids API Gateway's payload size limits entirely and means Lambda spends zero time or
memory shuttling bytes — it only ever does metadata work.

### 2.6 IAM: one shared pipeline role, not five
All five pipeline Lambdas (and the two API Lambdas) share one IAM role scoped to
exactly what the pipeline needs (S3 get/put on the uploads bucket, DynamoDB item-level
access on the jobs table, SNS publish, SQS send, CloudWatch Logs). This is a **known,
deliberate simplification** — see [Honest Tradeoffs](#4-honest-tradeoffs) below for what
production would do differently and why.

---

## 3. How it actually works (the practical walkthrough)

1. **Sign up / sign in.** The browser calls Cognito's `SignUp` → user gets a
   confirmation email → `ConfirmSignUp` → `InitiateAuth` (`USER_PASSWORD_AUTH`) returns
   a JWT `IdToken`, stored in `localStorage`.
2. **Request an upload URL.** Browser calls `POST /upload-url` on API Gateway (HTTP
   API), `Authorization: <idToken>`. API Gateway's **JWT authorizer** validates the
   token against the Cognito User Pool's issuer/audience *before* Lambda ever runs —
   an unauthenticated or expired request never reaches application code. The
   `get-upload-url` Lambda reads `sub` (user id) from the verified JWT claims,
   generates a `job_id`, and returns a presigned PUT URL for
   `incoming/{user_id}/{job_id}/{filename}`.
3. **Upload.** Browser `PUT`s the file directly to S3 using that URL.
4. **Trigger.** S3 emits an "Object Created" event → EventBridge rule (filtered to the
   `incoming/` prefix) → an `input_transformer` reshapes the event into
   `{"bucket": {...}, "object": {...}}` → `StartExecution` on the state machine.
5. **Validate.** Checks file extension/shape, writes `status: RUNNING, stage: validate`
   to DynamoDB. Malformed input raises `ValidationError` → caught → `HandleFailure`.
6. **Transform.** Converts XML (ElementTree walk → nested dict), CSV
   (`csv.DictReader` → records list), or JSON (passthrough) into a canonical JSON
   document, written to `results/{user_id}/{job_id}/transformed.json`.
7. **Apply rules.** Type-specific sanity checks (CSV must have rows, XML must have
   content, JSON must not be empty). Violations raise `RulesError` → caught →
   `HandleFailure`.
8. **Store & notify.** Marks the job `COMPLETE` in DynamoDB and publishes a success
   message to SNS.
9. **On any failure, anywhere:** the state machine's `Catch` routes to
   `HandleFailure`, which marks the job `FAILED` with a truncated error message,
   publishes an SNS alert, and drops a record on the SQS dead-letter queue so a human
   (or a future re-driver Lambda) can inspect and replay it.
10. **Dashboard.** The browser polls `GET /jobs` every 4 seconds, rendering a 4-stage
    pipeline visual and a job history table from the same DynamoDB data the pipeline
    itself wrote.

---

## 4. Honest tradeoffs

Built for a learning project on a personal AWS account with a hard "don't spend money"
constraint. If this were going into a real production environment, here's what would
change, in priority order:

1. ~~Remote Terraform state.~~ **Closed.** State now lives in a versioned, encrypted
   S3 bucket with a DynamoDB lock table (`docs/ci-cd-setup.md`), so CloudShell and
   GitHub Actions CI runs share one source of truth and can never race each other.
2. **Per-function IAM roles.** One shared `pipeline_lambda` role is simpler to build
   but violates least-privilege — the `validate` function, for instance, doesn't need
   SNS `Publish` permissions. Production would give each of the 7 Lambdas its own
   narrowly-scoped role.
3. **A non-root operating identity.** Console/CloudShell work for this build was done
   as the AWS account root user rather than the IAM user (`terraform-deploy-admin`)
   created for it. Root should never be used for day-to-day operations; this is flagged
   here deliberately rather than glossed over.
4. **Native push instead of polling.** The dashboard polls `GET /jobs` every 4 seconds.
   A `ws_connections` DynamoDB table exists in Terraform for a planned API Gateway
   WebSocket API that would push status updates instantly instead — it was scoped,
   partially designed, and then deliberately dropped in favor of shipping a complete,
   working polling version rather than a half-finished WebSocket one. The table is
   harmless (empty, PAY_PER_REQUEST) but currently unused; removing it or finishing the
   WebSocket API are both reasonable next steps.
5. ~~Structured observability.~~ **Closed.** A CloudWatch dashboard (`dashboard_url`
   output) now covers invocations, errors, p50/p99 duration, Step Functions execution
   counts, DynamoDB capacity, DLQ depth, and API traffic in one view. Four CloudWatch
   alarms (pipeline failure, Step Functions failure, non-empty DLQ, API 5xx) fire into
   the existing SNS topic. X-Ray active tracing is enabled end-to-end (API Gateway →
   Lambda → Step Functions → Lambda ×5), so a single request is traceable as one
   service map instead of stitched together from seven separate log groups by hand.
   What's still missing versus a production setup: custom EMF metric filters for
   business-level KPIs (jobs processed per user, per file type) and composite alarms
   that reduce alert noise during a correlated multi-service failure.

Being able to name these clearly — not just build the happy path — is itself the
Solutions-Architect skill this project exists to demonstrate.

### 4.1 Governance additions (also closed)

Two items weren't on the original tradeoffs list but are worth calling out explicitly,
since "can you show me governance/security thinking, not just app features" is exactly
the kind of question a platform or security-adjacent interviewer asks:

- **CloudTrail.** A dedicated multi-region trail (`cloudtrail_bucket` output) logs
  every management-plane API call across the account — the same audit primitive a
  bank's compliance team would require before sign-off on a real workload. Management
  event logging itself is free; only the (tiny) S3 storage of the JSON logs costs
  anything, and a 90-day lifecycle rule keeps that bounded.
- **API Gateway throttling + access logs.** The API now has a sane default throttle
  (10 req/s steady-state, 20-burst) so one misbehaving client or bug can't exhaust
  Lambda concurrency or run up cost, plus structured JSON access logs (request id,
  source IP, route, status, latency) shipped to their own CloudWatch Log Group for
  after-the-fact investigation.

---

## 5. Services used and why

| Service | Role | Why this one |
|---|---|---|
| S3 | File landing zone + static frontend hosting | Durable, cheap, native EventBridge integration |
| EventBridge | Event-driven trigger | Decouples trigger from actor; filterable, extensible |
| Step Functions (Standard) | Pipeline orchestration | Declarative retries/catch, free execution history |
| Lambda (Python 3.12) | Validate / transform / apply-rules / store-notify / handle-failure / 2 API handlers | Pay-per-invocation, zero idle cost |
| DynamoDB | Job status/history | Single-digit-ms reads, PAY_PER_REQUEST = $0 idle |
| Cognito | Auth (sign-up/in, JWT) | Managed user pool, no password storage of our own |
| API Gateway (HTTP API) | REST surface, Cognito JWT authorizer | Cheaper & simpler than REST API type for this use case |
| SNS | Success/failure notifications | Decoupled fan-out, one line of code to add subscribers |
| SQS | Dead-letter queue for failed jobs | Nothing is ever silently lost |
| CloudFront + OAC | HTTPS CDN over a fully-private S3 bucket | No public S3 bucket, free HTTPS cert, edge caching |
| CloudWatch Logs | Per-Lambda + Step Functions execution logs, API access logs | Default AWS observability, zero setup |
| CloudWatch Dashboard | Single-pane-of-glass ops view | One dashboard instead of seven console tabs |
| CloudWatch Alarms | 4 alarms → SNS (pipeline failure, SFN failure, DLQ depth, API 5xx) | Failures surface the same way successes do |
| X-Ray | Distributed tracing across the whole request path | One service map instead of stitching logs together manually |
| CloudTrail | Multi-region management-event audit trail | Who-did-what-when across the account; compliance-grade default |
| AWS Budgets | Cost safety net | Hard $10/month tracked cap with 80%/100% alerts |
| Terraform | 100% of the above | Reproducible, destroyable, version-controlled infra |
| GitHub Actions (OIDC) | CI/CD | No long-lived AWS keys stored anywhere |

See [`cost-and-teardown.md`](./cost-and-teardown.md) for what this costs and how to
tear it all down cleanly.
