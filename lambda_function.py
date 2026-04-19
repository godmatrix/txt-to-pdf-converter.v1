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