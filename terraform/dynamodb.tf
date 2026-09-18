# -----------------------------------------------------------------------------
# Jobs table: one item per uploaded file's pipeline run. Tracks status as it
# moves through Step Functions (RECEIVED -> VALIDATING -> TRANSFORMING ->
# APPLYING_RULES -> COMPLETE / FAILED). Pay-per-request so idle cost is $0.
# -----------------------------------------------------------------------------
resource "aws_dynamodb_table" "jobs" {
  name         = "${local.name_prefix}-jobs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "user_id"
  range_key    = "job_id"

  attribute {
    name = "user_id"
    type = "S"
  }

  attribute {
    name = "job_id"
    type = "S"
  }

  attribute {
    name = "status"
    type = "S"
  }

  # Lets the dashboard query "all currently RUNNING jobs across users" for
  # the operator view, without a full table scan.
  global_secondary_index {
    name            = "status-index"
    hash_key        = "status"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }
}

# -----------------------------------------------------------------------------
# WebSocket connections table: maps open WebSocket connection IDs to user_id,
# so the notify Lambda knows which open sockets to push a status update to.
# -----------------------------------------------------------------------------
resource "aws_dynamodb_table" "ws_connections" {
  name         = "${local.name_prefix}-ws-connections"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "connection_id"

  attribute {
    name = "connection_id"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }
}
