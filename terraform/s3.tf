# -----------------------------------------------------------------------------
# Uploads bucket: where users' XML/CSV/JSON files land. This is the trigger
# point for the whole pipeline (S3 -> EventBridge/Lambda -> Step Functions).
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "uploads" {
  bucket = "${local.name_prefix}-uploads-${local.account_id}"
}

resource "aws_s3_bucket_versioning" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket                  = aws_s3_bucket.uploads.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Auto-expire raw uploads after 30 days to stay well inside free-tier storage
resource "aws_s3_bucket_lifecycle_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  rule {
    id     = "expire-old-uploads"
    status = "Enabled"
    filter {
      prefix = "incoming/"
    }
    expiration {
      days = 30
    }
  }
}

# CORS so the browser dashboard can upload directly via presigned URLs
resource "aws_s3_bucket_cors_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["PUT", "GET", "POST"]
    allowed_origins = ["*"] # tighten to the CloudFront domain once known
    max_age_seconds = 3000
  }
}

# -----------------------------------------------------------------------------
# Frontend hosting bucket (private; served only via CloudFront)
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "frontend" {
  bucket = "${local.name_prefix}-frontend-${local.account_id}"
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
