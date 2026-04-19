terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source = "hashicorp/archive"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# ──────────────────────────────────────────────
# Source Bucket (drop .txt files here)
# ──────────────────────────────────────────────
resource "aws_s3_bucket" "source" {
  bucket = "txt-to-pdf-source-bucket"   # Change if name taken
}

# ──────────────────────────────────────────────
# Destination Bucket (PDFs go here in /processed/)
# ──────────────────────────────────────────────
resource "aws_s3_bucket" "destination" {
  bucket = "txt-to-pdf-destination-bucket"   # Change if name taken
}

# ──────────────────────────────────────────────
# IAM Role for Lambda
# ──────────────────────────────────────────────
resource "aws_iam_role" "lambda_role" {
  name = "txt-to-pdf-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  inline_policy {
    name = "s3_access"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
          Effect   = "Allow"
          Resource = [
            "${aws_s3_bucket.source.arn}/*",
            "${aws_s3_bucket.destination.arn}/*"
          ]
        }
      ]
    })
  }
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Add SES send permission
resource "aws_iam_role_policy" "ses_send" {
  name = "ses_send_email"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action   = "ses:SendEmail"
      Effect   = "Allow"
      Resource = "*"
    }]
  })
}

# ──────────────────────────────────────────────
# Zip Lambda code
# ──────────────────────────────────────────────
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda_function.py"
  output_path = "${path.module}/function.zip"
}

# ──────────────────────────────────────────────
# Lambda Layer with fpdf2
# ──────────────────────────────────────────────
resource "aws_lambda_layer_version" "fpdf_layer" {
  filename            = "${path.module}/layer.zip"
  layer_name          = "fpdf2-layer"
  compatible_runtimes = ["python3.11"]
}

# ──────────────────────────────────────────────
# Lambda Function
# ──────────────────────────────────────────────
resource "aws_lambda_function" "converter" {
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  function_name    = "txt-to-pdf-converter"
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.11"
  layers           = [aws_lambda_layer_version.fpdf_layer.arn]
  timeout          = 30
}

# ──────────────────────────────────────────────
# S3 → Lambda Trigger (on .txt upload to source)
# ──────────────────────────────────────────────
resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.converter.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.source.arn
}

resource "aws_s3_bucket_notification" "source_notification" {
  bucket = aws_s3_bucket.source.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.converter.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".txt"
  }

  depends_on = [aws_lambda_permission.allow_s3]
}