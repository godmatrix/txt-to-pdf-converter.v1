Here’s the updated, simplified Terraform setup that matches your new requirements exactly:
Two buckets: source-bucket (where you drop test.txt) and destination-bucket (where PDFs go into a processed/ folder)
Lambda converts .txt → .pdf and moves it: uploads PDF to destination-bucket/processed/, then deletes original .txt from source
Notification: sends an email via AWS SES to lucaspro.tech@gmail.com when conversion succeeds
Uses modern fpdf2 library
Important Prerequisites (Do These Manually First)
Verify your email in AWS SES (critical – SES won't send emails otherwise):
Go to AWS Console → SES → Verified identities
Click "Create identity" → Email address → enter lucaspro.tech@gmail.com
Check your inbox (and spam) for a verification email from AWS → click the link to verify
Wait until status shows "Verified" (usually instant after clicking)
If your SES account is in sandbox mode (most new accounts are), you can only send to verified addresses. Verify lucaspro.tech@gmail.com as both sender and recipient.
Move out of SES sandbox (optional but recommended for production):
Submit a request in SES console to increase limits and exit sandbox.
Updated Terraform (main.tf)
hcl
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
Updated Lambda Code (lambda_function.py)
Place this file in the same folder as main.tf
Python
import json
import boto3
from fpdf import FPDF
from urllib.parse import unquote_plus
import os

s3 = boto3.client('s3')
ses = boto3.client('ses')

EMAIL_RECIPIENT = "lucaspro.tech@gmail.com"
EMAIL_SENDER    = "lucaspro.tech@gmail.com"  # Must be verified in SES

def lambda_handler(event, context):
    for record in event.get('Records', []):
        bucket = record['s3']['bucket']['name']
        key    = unquote_plus(record['s3']['object']['key'])

        if not key.lower().endswith('.txt'):
            continue

        # Read TXT file
        obj = s3.get_object(Bucket=bucket, Key=key)
        text = obj['Body'].read().decode('utf-8')

        # Create PDF
        pdf = FPDF()
        pdf.add_page()
        pdf.set_font("Arial", size=12)
        for line in text.split('\n'):
            pdf.cell(200, 10, txt=line, ln=True)

        pdf_path = '/tmp/output.pdf'
        pdf.output(pdf_path)

        # Upload PDF to destination/processed/
        pdf_key = f"processed/{os.path.splitext(key)[0]}.pdf"
        s3.upload_file(pdf_path, 'txt-to-pdf-destination-bucket', pdf_key)

        # Delete original TXT from source
        s3.delete_object(Bucket=bucket, Key=key)

        # Send email notification
        ses.send_email(
            Source=EMAIL_SENDER,
            Destination={'ToAddresses': [EMAIL_RECIPIENT]},
            Message={
                'Subject': {'Data': 'New PDF Created'},
                'Body': {
                    'Text': {
                        'Data': f"Converted {key} to PDF.\n\nPDF location: s3://txt-to-pdf-destination-bucket/{pdf_key}"
                    }
                }
            }
        )

    return {
        'statusCode': 200,
        'body': json.dumps('Processed successfully')
    }
Layer Creation (fpdf2)
Run these commands in your project folder:
Bash
mkdir python
pip3 install fpdf2 -t python/
zip -r layer.zip python
rm -rf python  # optional cleanup
Deploy Steps
Save main.tf and lambda_function.py
Create layer.zip as above
Verify email in SES (very important!)
Run:
Bash
terraform init
terraform apply
Test:
Upload test.txt to source bucket
Wait ~10–30 seconds
Check: PDF in destination bucket under processed/
Original .txt should be gone from source
Email arrives at lucaspro.tech@gmail.com
If email doesn't arrive → check SES console for sending statistics / suppression list, and CloudWatch Logs for Lambda errors.

