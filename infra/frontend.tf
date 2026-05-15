# ── S3 bucket for built frontend assets ───────────────────────────────────────
resource "aws_s3_bucket" "frontend" {
  bucket        = "${var.project}-frontend-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = { Name = "${var.project}-frontend" }
}

resource "aws_s3_bucket_versioning" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
    bucket_key_enabled = true
  }
}

# Block all public access — CloudFront accesses via OAC, not public URLs
resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── CloudFront Origin Access Control ─────────────────────────────────────────
resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${var.project}-frontend-oac"
  description                       = "OAC for dersforumu frontend S3 bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ── CloudFront distribution ───────────────────────────────────────────────────
resource "aws_cloudfront_distribution" "frontend" {
  provider = aws.us_east_1   # CloudFront is a global service; ACM certs must be us-east-1

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100"   # US/Europe/Israel only — cheapest

  # No custom domain: use CloudFront's auto-assigned *.cloudfront.net URL.
  # aliases block intentionally omitted.

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "S3-${aws_s3_bucket.frontend.id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "S3-${aws_s3_bucket.frontend.id}"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }

  # SPA routing: any 403/404 from S3 (missing path) → serve index.html
  # The React router handles client-side navigation from there.
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  # No custom domain → use CloudFront's default certificate
  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = { Name = "${var.project}-cf-frontend" }
}

# ── S3 bucket policy: allow CloudFront OAC to read objects ────────────────────
resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontOAC"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.frontend.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.frontend.arn
          }
        }
      },
      {
        Sid    = "AllowGHADeployerSync"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.github_deployer.arn
        }
        Action = [
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.frontend.arn,
          "${aws_s3_bucket.frontend.arn}/*"
        ]
      }
    ]
  })
}

# ── Outputs ────────────────────────────────────────────────────────────────────
output "cloudfront_domain"      { value = aws_cloudfront_distribution.frontend.domain_name }
output "cloudfront_dist_id"     { value = aws_cloudfront_distribution.frontend.id }
output "frontend_bucket_name"   { value = aws_s3_bucket.frontend.id }
output "frontend_bucket_arn"    { value = aws_s3_bucket.frontend.arn }
