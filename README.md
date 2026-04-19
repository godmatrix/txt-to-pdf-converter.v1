Here’s the updated, simplified Terraform setup that matches your new requirements exactly:

* **Two buckets**: source-bucket (where you drop test.txt) and destination-bucket (where PDFs go into a processed/ folder)  
* Lambda converts .txt → .pdf and **moves** it: uploads PDF to destination-bucket/processed/, then **deletes** original .txt from source  
* Notification: sends an email via **AWS SES** to lucaspro.tech@gmail.com when conversion succeeds  
* Uses modern fpdf2 library

### **Important Prerequisites (Do These Manually First)**

1. **Verify your email in AWS SES** (critical – SES won't send emails otherwise):  
   * Go to AWS Console → SES → Verified identities  
   * Click "Create identity" → Email address → enter lucaspro.tech@gmail.com  
   * Check your inbox (and spam) for a verification email from AWS → click the link to verify  
   * Wait until status shows "Verified" (usually instant after clicking)  
2. If your SES account is in **sandbox mode** (most new accounts are), you can only send to **verified** addresses. Verify lucaspro.tech@gmail.com as both sender and recipient.  
3. **Move out of SES sandbox** (optional but recommended for production):  
   * Submit a request in SES console to increase limits and exit sandbox.

### **Updated Terraform (main.tf)**

hcl  
terraform {  
  required\_providers {  
    aws \= {  
      source  \= "hashicorp/aws"  
      version \= "\~\> 5.0"  
    }  
    archive \= {  
      source \= "hashicorp/archive"  
    }  
  }  
}

provider "aws" {  
  region \= "us-east-1"  
}

*\# ──────────────────────────────────────────────*  
*\# Source Bucket (drop .txt files here)*  
*\# ──────────────────────────────────────────────*  
resource "aws\_s3\_bucket" "source" {  
  bucket \= "txt-to-pdf-source-bucket"   *\# Change if name taken*  
}

*\# ──────────────────────────────────────────────*  
*\# Destination Bucket (PDFs go here in /processed/)*  
*\# ──────────────────────────────────────────────*  
resource "aws\_s3\_bucket" "destination" {  
  bucket \= "txt-to-pdf-destination-bucket"   *\# Change if name taken*  
}

*\# ──────────────────────────────────────────────*  
*\# IAM Role for Lambda*  
*\# ──────────────────────────────────────────────*  
resource "aws\_iam\_role" "lambda\_role" {  
  name \= "txt-to-pdf-lambda-role"

  assume\_role\_policy \= jsonencode({  
    Version \= "2012-10-17"  
    Statement \= \[{  
      Action    \= "sts:AssumeRole"  
      Effect    \= "Allow"  
      Principal \= { Service \= "lambda.amazonaws.com" }  
    }\]  
  })

  inline\_policy {  
    name \= "s3\_access"  
    policy \= jsonencode({  
      Version \= "2012-10-17"  
      Statement \= \[  
        {  
          Action   \= \["s3:GetObject", "s3:PutObject", "s3:DeleteObject"\]  
          Effect   \= "Allow"  
          Resource \= \[  
            "${aws\_s3\_bucket.source.arn}/\*",  
            "${aws\_s3\_bucket.destination.arn}/\*"  
          \]  
        }  
      \]  
    })  
  }  
}

resource "aws\_iam\_role\_policy\_attachment" "lambda\_basic" {  
  role       \= aws\_iam\_role.lambda\_role.name  
  policy\_arn \= "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"  
}

*\# Add SES send permission*  
resource "aws\_iam\_role\_policy" "ses\_send" {  
  name \= "ses\_send\_email"  
  role \= aws\_iam\_role.lambda\_role.id

  policy \= jsonencode({  
    Version \= "2012-10-17"  
    Statement \= \[{  
      Action   \= "ses:SendEmail"  
      Effect   \= "Allow"  
      Resource \= "\*"  
    }\]  
  })  
}

*\# ──────────────────────────────────────────────*  
*\# Zip Lambda code*  
*\# ──────────────────────────────────────────────*  
data "archive\_file" "lambda\_zip" {  
  type        \= "zip"  
  source\_file \= "${path.module}/lambda\_function.py"  
  output\_path \= "${path.module}/function.zip"  
}

*\# ──────────────────────────────────────────────*  
*\# Lambda Layer with fpdf2*  
*\# ──────────────────────────────────────────────*  
resource "aws\_lambda\_layer\_version" "fpdf\_layer" {  
  filename            \= "${path.module}/layer.zip"  
  layer\_name          \= "fpdf2-layer"  
  compatible\_runtimes \= \["python3.11"\]  
}

*\# ──────────────────────────────────────────────*  
*\# Lambda Function*  
*\# ──────────────────────────────────────────────*  
resource "aws\_lambda\_function" "converter" {  
  filename         \= data.archive\_file.lambda\_zip.output\_path  
  source\_code\_hash \= data.archive\_file.lambda\_zip.output\_base64sha256  
  function\_name    \= "txt-to-pdf-converter"  
  role             \= aws\_iam\_role.lambda\_role.arn  
  handler          \= "lambda\_function.lambda\_handler"  
  runtime          \= "python3.11"  
  layers           \= \[aws\_lambda\_layer\_version.fpdf\_layer.arn\]  
  timeout          \= 30  
}

*\# ──────────────────────────────────────────────*  
*\# S3 → Lambda Trigger (on .txt upload to source)*  
*\# ──────────────────────────────────────────────*  
resource "aws\_lambda\_permission" "allow\_s3" {  
  statement\_id  \= "AllowS3Invoke"  
  action        \= "lambda:InvokeFunction"  
  function\_name \= aws\_lambda\_function.converter.function\_name  
  principal     \= "s3.amazonaws.com"  
  source\_arn    \= aws\_s3\_bucket.source.arn  
}

resource "aws\_s3\_bucket\_notification" "source\_notification" {  
  bucket \= aws\_s3\_bucket.source.id

  lambda\_function {  
    lambda\_function\_arn \= aws\_lambda\_function.converter.arn  
    events              \= \["s3:ObjectCreated:\*"\]  
    filter\_suffix       \= ".txt"  
  }

  depends\_on \= \[aws\_lambda\_permission.allow\_s3\]  
}

### **Updated Lambda Code (lambda\_function.py)**

Place this file in the same folder as main.tf

Python  
import json  
import boto3  
from fpdf import FPDF  
from urllib.parse import unquote\_plus  
import os

s3 \= boto3.client('s3')  
ses \= boto3.client('ses')

EMAIL\_RECIPIENT \= "lucaspro.tech@gmail.com"  
EMAIL\_SENDER    \= "lucaspro.tech@gmail.com"  *\# Must be verified in SES*

def lambda\_handler(event, context):  
    for record in event.get('Records', \[\]):  
        bucket \= record\['s3'\]\['bucket'\]\['name'\]  
        key    \= unquote\_plus(record\['s3'\]\['object'\]\['key'\])

        if not key.lower().endswith('.txt'):  
            continue

        *\# Read TXT file*  
        obj \= s3.get\_object(Bucket\=bucket, Key\=key)  
        text \= obj\['Body'\].read().decode('utf-8')

        *\# Create PDF*  
        pdf \= FPDF()  
        pdf.add\_page()  
        pdf.set\_font("Arial", size\=12)  
        for line in text.split('\\n'):  
            pdf.cell(200, 10, txt\=line, ln\=True)

        pdf\_path \= '/tmp/output.pdf'  
        pdf.output(pdf\_path)

        *\# Upload PDF to destination/processed/*  
        pdf\_key \= f"processed/{os.path.splitext(key)\[0\]}.pdf"  
        s3.upload\_file(pdf\_path, 'txt-to-pdf-destination-bucket', pdf\_key)

        *\# Delete original TXT from source*  
        s3.delete\_object(Bucket\=bucket, Key\=key)

        *\# Send email notification*  
        ses.send\_email(  
            Source\=EMAIL\_SENDER,  
            Destination\={'ToAddresses': \[EMAIL\_RECIPIENT\]},  
            Message\={  
                'Subject': {'Data': 'New PDF Created'},  
                'Body': {  
                    'Text': {  
                        'Data': f"Converted {key} to PDF.\\n\\nPDF location: s3://txt-to-pdf-destination-bucket/{pdf\_key}"  
                    }  
                }  
            }  
        )

    return {  
        'statusCode': 200,  
        'body': json.dumps('Processed successfully')  
    }

### **Layer Creation (fpdf2)**

Run these commands in your project folder:

Bash  
mkdir python  
pip3 install fpdf2 \-t python/  
zip \-r layer.zip python  
rm \-rf python  *\# optional cleanup*

### **Deploy Steps**

1. Save main.tf and lambda\_function.py  
2. Create layer.zip as above  
3. Verify email in SES (very important\!)  
4. Run:  
   Bash

terraform init

5. terraform apply  
6. Test:  
   * Upload test.txt to source bucket  
   * Wait \~10–30 seconds  
   * Check: PDF in destination bucket under processed/  
   * Original .txt should be gone from source  
   * Email arrives at lucaspro.tech@gmail.com

If email doesn't arrive → check SES console for sending statistics / suppression list, and CloudWatch Logs for Lambda errors.

