# ── Pre-sign-up Lambda (enforces @sabanciuniv.edu) ────────────────────────────
data "archive_file" "presignup_zip" {
  type        = "zip"
  output_path = "${path.module}/presignup.zip"
  source {
    filename = "index.py"
    content  = <<-PYTHON
      def handler(event, context):
          email = event.get("request", {}).get("userAttributes", {}).get("email", "")
          if not email.lower().endswith("@sabanciuniv.edu"):
              raise Exception("Only @sabanciuniv.edu email addresses are allowed.")
          event["response"]["autoConfirmUser"] = False
          event["response"]["autoVerifyEmail"] = False
          return event
    PYTHON
  }
}

resource "aws_iam_role" "presignup_lambda" {
  name = "${var.project}-presignup-lambda"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "presignup_lambda_logs" {
  role       = aws_iam_role.presignup_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "presignup" {
  function_name    = "${var.project}-presignup"
  role             = aws_iam_role.presignup_lambda.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.presignup_zip.output_path
  source_code_hash = data.archive_file.presignup_zip.output_base64sha256
  timeout          = 5

  tags = { Name = "${var.project}-presignup-lambda" }
}

# Allow Cognito to invoke the Lambda
resource "aws_lambda_permission" "cognito_presignup" {
  statement_id  = "AllowCognitoInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.presignup.function_name
  principal     = "cognito-idp.amazonaws.com"
}

# ── Cognito User Pool ──────────────────────────────────────────────────────────
resource "aws_cognito_user_pool" "main" {
  name = "${var.project}-users"

  # Username = email
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  # Password policy
  password_policy {
    minimum_length                   = 10
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
  }

  # MFA — optional (TOTP)
  mfa_configuration = "OPTIONAL"
  software_token_mfa_configuration {
    enabled = true
  }

  # Account recovery via email
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # Email configuration — use Cognito default sender for now;
  # switch to SES after SES production access is granted (Phase 3 manual step)
  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  # Pre-sign-up trigger: enforce @sabanciuniv.edu
  lambda_config {
    pre_sign_up = aws_lambda_function.presignup.arn
  }

  # User attribute schema
  schema {
    name                     = "email"
    attribute_data_type      = "String"
    required                 = true
    mutable                  = true
    string_attribute_constraints {
      min_length = 5
      max_length = 100
    }
  }

  # Token validity
  user_pool_add_ons {
    advanced_security_mode = "AUDIT"
  }

  tags = { Name = "${var.project}-user-pool" }
}

# ── Cognito App Client ─────────────────────────────────────────────────────────
resource "aws_cognito_user_pool_client" "api" {
  name         = "${var.project}-api-client"
  user_pool_id = aws_cognito_user_pool.main.id

  # No client secret — SPA / mobile uses PKCE flow
  generate_secret = false

  # Auth flows: SRP for web, USER_PASSWORD for API testing
  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  # Token validity
  access_token_validity  = 60   # minutes
  id_token_validity      = 60   # minutes
  refresh_token_validity = 7    # days

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  # No OAuth / hosted UI needed (custom auth flow)
  supported_identity_providers = ["COGNITO"]

  prevent_user_existence_errors = "ENABLED"
}

# ── Update SSM params with real Cognito IDs ────────────────────────────────────
resource "aws_ssm_parameter" "cognito_user_pool_id_real" {
  name      = "/dersforumu/cognito/user_pool_id"
  type      = "String"
  value     = aws_cognito_user_pool.main.id
  overwrite = true
}

resource "aws_ssm_parameter" "cognito_client_id_real" {
  name      = "/dersforumu/cognito/client_id"
  type      = "String"
  value     = aws_cognito_user_pool_client.api.id
  overwrite = true
}

# Update Secrets Manager cognito/client with real client ID
resource "aws_secretsmanager_secret_version" "cognito_real" {
  secret_id = aws_secretsmanager_secret.cognito.id
  secret_string = jsonencode({
    user_pool_id = aws_cognito_user_pool.main.id
    client_id    = aws_cognito_user_pool_client.api.id
  })
}

# ── SES Email Identity ─────────────────────────────────────────────────────────
# Verify the sender email address for OTP sending.
# Using a single email address (not a domain) since we have no custom domain.
# On a paid account with a domain, use aws_ses_domain_identity instead.
resource "aws_ses_email_identity" "otp_sender" {
  email = var.alert_email   # alpnuhoglu2@gmail.com — must click verification link
}

# ── IAM: allow ECS task role to send SES email ────────────────────────────────
# (Referenced by ecsTaskRole-dersforumu-api in Phase 6)
resource "aws_iam_policy" "ses_send" {
  name        = "${var.project}-ses-send"
  description = "Allow sending email via SES from the verified identity"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ses:SendEmail", "ses:SendRawEmail"]
      Resource = "*"
      Condition = {
        StringLike = {
          "ses:FromAddress" = var.alert_email
        }
      }
    }]
  })
}

# ── CloudWatch Log Group for Lambda ───────────────────────────────────────────
resource "aws_cloudwatch_log_group" "presignup_lambda" {
  name              = "/aws/lambda/${var.project}-presignup"
  retention_in_days = 30
  # KMS encryption for CW log groups requires the CMK key policy to explicitly
  # grant logs.amazonaws.com GenerateDataKey permissions. Using default
  # CloudWatch managed encryption here; extend key policy in Phase 8 if needed.
}

# ── Outputs ────────────────────────────────────────────────────────────────────
output "cognito_user_pool_id"     { value = aws_cognito_user_pool.main.id }
output "cognito_user_pool_arn"    { value = aws_cognito_user_pool.main.arn }
output "cognito_client_id"        { value = aws_cognito_user_pool_client.api.id }
output "cognito_jwks_uri"         {
  value = "https://cognito-idp.eu-central-1.amazonaws.com/${aws_cognito_user_pool.main.id}/.well-known/jwks.json"
}
output "ses_send_policy_arn"      { value = aws_iam_policy.ses_send.arn }
