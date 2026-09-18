resource "aws_cognito_user_pool" "users" {
  name = "${local.name_prefix}-users"

  password_policy {
    minimum_length    = 8
    require_lowercase  = true
    require_uppercase  = true
    require_numbers    = true
    require_symbols    = false
  }

  auto_verified_attributes = ["email"]

  username_attributes = ["email"]

  admin_create_user_config {
    allow_admin_create_user_only = false
  }
}

resource "aws_cognito_user_pool_client" "web" {
  name                                 = "${local.name_prefix}-web-client"
  user_pool_id                         = aws_cognito_user_pool.users.id
  explicit_auth_flows                  = ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH", "ALLOW_USER_SRP_AUTH"]
  generate_secret                      = false
  access_token_validity                = 1
  id_token_validity                    = 1
  refresh_token_validity               = 30
  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }
}
