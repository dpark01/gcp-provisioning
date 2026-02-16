"""Cloud Function to send billing alert email notifications.

Triggered daily by Cloud Scheduler at 0945 UTC.
Queries billing_alerts_log for unsent alerts, groups by recipient,
renders HTML email via Jinja2, sends via SendGrid, and marks as sent.
"""

import os
from collections import defaultdict

import functions_framework
from google.cloud import bigquery
from google.cloud import secretmanager
from jinja2 import Environment, FileSystemLoader
from sendgrid import SendGridAPIClient
from sendgrid.helpers.mail import Mail, Content

PROJECT_ID = os.environ.get("GCP_PROJECT", "gcid-data-core")
DATASET = "custom_sada_billing_views"
TABLE = "billing_alerts_log"
SECRET_NAME = f"projects/{PROJECT_ID}/secrets/sendgrid-api-key/versions/latest"
FROM_EMAIL = os.environ.get("FROM_EMAIL", "gcid-billing-alerts@broadinstitute.org")

# Jinja2 template setup
template_dir = os.path.join(os.path.dirname(__file__), "templates")
jinja_env = Environment(loader=FileSystemLoader(template_dir), autoescape=True)


def get_sendgrid_api_key():
    """Retrieve SendGrid API key from Secret Manager."""
    client = secretmanager.SecretManagerServiceClient()
    response = client.access_secret_version(name=SECRET_NAME)
    return response.payload.data.decode("utf-8")


def get_unsent_alerts(bq_client):
    """Query billing_alerts_log for unsent alert notifications."""
    query = f"""
        SELECT
            alert_log_id,
            alert_id,
            alert_name,
            alert_type,
            fired_at,
            scope_description,
            rolling_7d_cost,
            threshold_value,
            weekly_mean,
            weekly_stddev,
            num_weekly_datapoints,
            notify_emails
        FROM `{PROJECT_ID}.{DATASET}.{TABLE}`
        WHERE notification_sent = FALSE
        ORDER BY fired_at DESC
    """
    return list(bq_client.query(query).result())


def mark_alerts_sent(bq_client, alert_log_ids):
    """Update notification_sent = TRUE for processed alerts."""
    if not alert_log_ids:
        return
    ids_str = ", ".join(f"'{aid}'" for aid in alert_log_ids)
    query = f"""
        UPDATE `{PROJECT_ID}.{DATASET}.{TABLE}`
        SET notification_sent = TRUE
        WHERE alert_log_id IN ({ids_str})
    """
    bq_client.query(query).result()


def group_alerts_by_recipient(alerts):
    """Group alert rows by recipient email address."""
    grouped = defaultdict(list)
    for alert in alerts:
        emails = alert.notify_emails or ""
        for email in emails.split(","):
            email = email.strip()
            if email:
                grouped[email].append(alert)
    return grouped


def render_email(alerts):
    """Render alert email HTML from Jinja2 template."""
    template = jinja_env.get_template("alert_email.html")
    return template.render(alerts=alerts)


def send_email(sg_client, to_email, subject, html_content):
    """Send an email via SendGrid."""
    message = Mail(
        from_email=FROM_EMAIL,
        to_emails=to_email,
        subject=subject,
        html_content=Content("text/html", html_content),
    )
    response = sg_client.send(message)
    return response.status_code


@functions_framework.http
def send_alert_notifications(request):
    """Main Cloud Function entry point.

    Queries for unsent alerts, groups by recipient, sends emails,
    and marks alerts as sent. Returns immediately if no alerts pending.
    """
    bq_client = bigquery.Client(project=PROJECT_ID)

    # Check for unsent alerts
    unsent_alerts = get_unsent_alerts(bq_client)
    if not unsent_alerts:
        return {"status": "ok", "message": "No unsent alerts"}, 200

    # Group by recipient
    alerts_by_recipient = group_alerts_by_recipient(unsent_alerts)

    # Initialize SendGrid
    api_key = get_sendgrid_api_key()
    sg_client = SendGridAPIClient(api_key)

    # Send emails
    sent_log_ids = set()
    errors = []

    for email, alerts in alerts_by_recipient.items():
        try:
            n = len(alerts)
            subject = f"GCP Billing Alert: {n} alert{'s' if n > 1 else ''} fired"
            html_content = render_email(alerts)
            status = send_email(sg_client, email, subject, html_content)

            if 200 <= status < 300:
                for alert in alerts:
                    sent_log_ids.add(alert.alert_log_id)
            else:
                errors.append(f"SendGrid returned {status} for {email}")
        except Exception as e:
            errors.append(f"Failed to send to {email}: {str(e)}")

    # Mark sent alerts
    mark_alerts_sent(bq_client, list(sent_log_ids))

    result = {
        "status": "ok" if not errors else "partial",
        "alerts_processed": len(unsent_alerts),
        "emails_sent": len(alerts_by_recipient) - len(errors),
        "alerts_marked_sent": len(sent_log_ids),
    }
    if errors:
        result["errors"] = errors

    return result, 200 if not errors else 207
