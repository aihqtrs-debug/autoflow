# AutoFlow — Cost & Teardown

## What this actually costs

This account is on the AWS **Free Plan**: new accounts get up to **$100 in credits**
over a **6-month** window, and — critically — the account does **not** get charged for
usage past normal free-tier limits during that window unless someone explicitly opts
in to upgrade to a paid plan. At hobby-project traffic (a handful of file uploads a
day, a handful of users), every service used here also falls within AWS's *ordinary*
Always-Free or 12-month-free tiers on top of that:

| Service | Free tier headroom at this scale |
|---|---|
| Lambda | 1M requests + 400,000 GB-seconds/month free, forever |
| DynamoDB | 25 GB storage + 25 WCU/RCU free, forever (this table uses PAY_PER_REQUEST, billed per request — negligible at this volume) |
| S3 | 5 GB + 20,000 GET / 2,000 PUT per month free (12 months) |
| API Gateway (HTTP API) | 1M requests/month free (12 months) |
| Step Functions | 4,000 state transitions/month free, forever |
| CloudFront | 1 TB data transfer + 10M requests/month free (12 months) |
| Cognito | 10,000 MAUs free, forever |
| SNS / SQS | 1M requests each free, forever |
| CloudWatch Logs | 5 GB ingestion free, forever (now includes API Gateway access logs alongside Lambda/Step Functions logs) |
| CloudWatch Dashboards | 3 dashboards free/month, forever (this project uses 1) |
| CloudWatch Alarms | 10 alarms free/month, forever (this project uses 4) |
| X-Ray | 100,000 traces recorded + 1,000,000 traces scanned/month free, forever — a portfolio demo's traffic won't come close |
| CloudTrail | Management-event logging is free, unlimited, forever. Only cost is S3 storage of the log files (a handful of KB per API call), which auto-expires after 90 days via the bucket's lifecycle rule |

**Bottom line:** at the traffic this app will see as a portfolio piece (you, plus
anyone testing it during an interview), the realistic monthly cost is **$0.00**, and
even under sustained heavier use it would take a lot of activity to meaningfully dent
the $100 credit, let alone trigger an actual charge.

The observability/governance layer added on top (X-Ray, CloudWatch dashboard + alarms,
CloudTrail, API throttling/access logs) was deliberately designed to stay inside the
same free-tier boundaries above — it adds visibility and audit trail, not cost. The
only genuinely metered piece is the handful of KB/month of CloudTrail log storage in
S3, which is effectively $0.00 at this scale and auto-expires after 90 days regardless.

## The safety net that's actually deployed

`terraform/budget.tf` created a real, live **AWS Budget** (`autoflow-dev-monthly-cap`)
with a **$10/month** tracked cap. If a notification email is set (via the
`notification_email` Terraform variable), it emails at 80% and 100% of that cap. Even
with no email configured, the budget is visible any time in
**Billing and Cost Management → Budgets** in the console, so spend is never invisible.

To turn on email alerts:

```
cd terraform
terraform apply -var="notification_email=you@example.com"
```

## Tearing it all down

Every piece of this project is Terraform-managed, so removal is one command from the
`terraform/` directory (run in AWS CloudShell, or anywhere with the same AWS
credentials configured):

```
cd terraform
terraform destroy
```

Review the plan it prints before confirming. This removes, in dependency order:
CloudFront distribution + OAC, S3 bucket policy, both S3 buckets (uploads and
frontend — **note:** Terraform will refuse to delete non-empty buckets; empty them
first with `aws s3 rm s3://<bucket> --recursive` if you've uploaded test files),
API Gateway + Cognito authorizer, Cognito User Pool + client, Step Functions state
machine, EventBridge rule, all 7 Lambda functions + their CloudWatch Log Groups, SNS
topic, SQS queue, both DynamoDB tables, the AWS Budget, the CloudWatch dashboard and
4 alarms, and the CloudTrail trail + its S3 bucket (**note:** like the app buckets,
Terraform will refuse to delete a non-empty CloudTrail bucket — empty it first with
`aws s3 rm s3://<cloudtrail-bucket> --recursive`).

A full teardown reliably brings ongoing cost back to exactly $0.

## What's *not* torn down automatically

- **IAM user `terraform-deploy-admin`** and its access keys were created manually in
  the console (not by Terraform) and must be deleted manually if no longer needed:
  IAM → Users → `terraform-deploy-admin` → Delete.
- **CloudWatch Logs Insights queries or dashboards**, if you add any later, live
  outside this Terraform state.

## If you want to keep it running but watch spend closely

- Check **Billing and Cost Management → Cost Explorer** monthly.
- The Free Plan's credit balance and days remaining are always visible under the
  account menu in the top-right of the AWS Console.
- The $10 budget alert (once an email is configured) is the earliest automatic signal
  that something is behaving unexpectedly.
