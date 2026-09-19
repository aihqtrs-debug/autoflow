# AutoFlow — CI/CD Setup (GitHub Actions + OIDC)

This is the one-time setup that connects a real GitHub repo to this AWS account so
`.github/workflows/deploy.yml` can run `terraform plan`/`apply` on every push to `main`,
with **no long-lived AWS access keys stored anywhere** — GitHub Actions authenticates
via OpenID Connect (OIDC) federation and assumes a scoped IAM role for the duration of
the workflow run only.

Two things have to exist before this works, and both are already written — they just
need to be applied and wired up:

1. **A remote Terraform state backend** (`terraform/github_oidc.tf` doesn't create this
   — it's bootstrapped by hand once, for the reason explained below).
2. **An OIDC-federated IAM role** scoped to this exact GitHub repo + branch
   (`terraform/github_oidc.tf` — already written, currently inert with a placeholder
   repo that matches nothing real).

---

## 1. Why remote state is required for CI (not just "nice to have")

Terraform state today lives locally, in the AWS CloudShell home directory. That's fine
for manual `terraform apply` from CloudShell, but a GitHub Actions runner is a fresh,
empty machine on every run — it has no access to that file. Without a shared backend,
a CI run would start from zero state, see "no resources exist yet," and try to
**recreate everything from scratch** — which would immediately collide with the
already-live S3 buckets, Lambda functions, etc. and fail (or worse, partially succeed
into a broken, duplicated mix).

The fix is a **remote backend**: an S3 bucket to hold `terraform.tfstate` plus a
DynamoDB table for state locking (so two applies — say, a manual one and a CI one —
can never race each other). This is also exactly the fix for "Honest Tradeoff #1" in
`architecture.md` (local state).

The backend bucket/table can't be created *by* the same Terraform config that then
*uses* them as its own backend (a chicken-and-egg problem — the `backend` block is
read before any resource in the config exists). So they're bootstrapped once via the
AWS CLI, outside Terraform, exactly like this:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-southeast-2
BUCKET="autoflow-dev-terraform-state-${ACCOUNT_ID}"
TABLE="autoflow-dev-terraform-locks"

aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"

aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws dynamodb create-table --table-name "$TABLE" \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

Then add this to `terraform/main.tf` (backend blocks can't use variables, so the
values are literal) and run `terraform init -migrate-state` to copy the existing local
state up to S3 in place:

```hcl
terraform {
  backend "s3" {
    bucket         = "autoflow-dev-terraform-state-486758670110"
    key            = "autoflow/terraform.tfstate"
    region         = "ap-southeast-2"
    dynamodb_table = "autoflow-dev-terraform-locks"
    encrypt        = true
  }
  # ...existing required_providers block stays as-is
}
```

Both CloudShell (manual applies) and GitHub Actions (CI applies) then read/write the
exact same state, so they never disagree about what's actually deployed.

## 2. The OIDC deploy role (`terraform/github_oidc.tf`)

Already written and — once `terraform apply` runs with the real repo — deploys:

- An `aws_iam_openid_connect_provider` trusting `token.actions.githubusercontent.com`.
- An `aws_iam_role` (`autoflow-dev-github-actions-deploy`) whose trust policy only
  allows `sts:AssumeRoleWithWebIdentity` from workflow runs where the GitHub OIDC
  token's `sub` claim matches `repo:<var.github_repo>:ref:refs/heads/main` — i.e.
  only a push (or manual dispatch) from that exact repo's `main` branch can assume it.
- An attached policy scoped by resource-name-prefix (`autoflow-dev-*`) everywhere the
  IAM ARN format allows it, with a short list of documented exceptions (CloudFront,
  Cognito, API Gateway HTTP APIs) where AWS's IAM implementation doesn't support
  resource-level scoping for the actions Terraform needs — those are scoped to
  service/region/account instead of a blanket `"*"`.

`var.github_repo` defaults to `"CHANGEME/CHANGEME"`, which matches no real GitHub
repository — so until it's set to the real value, this role can never actually be
assumed by anyone. That's deliberate: safe to leave applied while waiting on the repo.

## 3. What actually has to happen, in order

1. Bootstrap the state bucket + lock table (section 1's CLI commands).
2. Add the `backend "s3"` block to `main.tf`, run `terraform init -migrate-state`.
3. `terraform apply` (creates the OIDC provider + inert deploy role).
4. You create the GitHub repo and push this code (see main `README.md`).
5. Tell me the repo as `org-or-username/repo-name`.
6. `terraform apply -var="github_repo=<that value>"` — flips the trust policy live.
   Takes seconds; nothing else about the stack changes.
7. `terraform output github_actions_role_arn` — that value goes into a GitHub repo
   secret named exactly `AWS_DEPLOY_ROLE_ARN`
   (Settings → Secrets and variables → Actions → New repository secret).
8. Push to `main` (or re-run the workflow manually) — `.github/workflows/deploy.yml`
   now runs end-to-end with zero AWS keys stored in GitHub.

## Teardown note

If you ever `terraform destroy` the whole stack, the state bucket and lock table are
**not** part of that (they were bootstrapped outside Terraform on purpose, so state
can be destroyed last, deliberately, not as a side effect). Delete them by hand at the
very end: empty the bucket (`aws s3 rm s3://<bucket> --recursive`, mind the object
versions if versioning was ever exercised), then `aws s3api delete-bucket` and
`aws dynamodb delete-table`.
