# Billing Cost Alerting System - Architecture

## Overview

Automated daily alerting when GCP billing costs exceed configured thresholds. Built on BigQuery scheduled queries and Cloud Functions with SendGrid email delivery.

## Data Flow

```
0900 UTC: BQ Scheduled Query #1 (existing - refreshes billing_data)
    |
0930 UTC: BQ Scheduled Query #2 (evaluate-alerts.sql - evaluates alerts, INSERTs into billing_alerts_log)
    |
0945 UTC: Cloud Scheduler -> Cloud Function (reads unsent alerts, emails via SendGrid)
```

Zero cost on quiet days: the Cloud Function exits immediately if no alerts fired.

## Alert Types

| Type | Trigger Condition |
|---|---|
| `fixed` | Rolling N-day `net_cost` exceeds a dollar amount |
| `stddev` | Rolling N-day `net_cost` exceeds N standard deviations above the mean of weekly totals over the prior 60 days |
| `percent` | Rolling N-day `net_cost` exceeds a percentage of the 60-day weekly average (e.g., 150 = alert if 50% above average) |

## Tables

### `billing_alert_config`

Dataset: `gcid-data-core.custom_sada_billing_views`

Stores alert definitions. Each row is one alert rule. Multiple scope columns can be set (ANDed together); NULL = wildcard (matches all).

Key columns:
- `alert_id` (STRING): Unique identifier
- `enabled` (BOOL): Toggle without deleting
- `scope_*` columns: Filter to billing account, project, team, project category, service category
- `rolling_window_days` (INT64): Size of rolling cost window (default 7)
- `alert_type` (STRING): `fixed`, `stddev`, or `percent`
- `threshold_amount` (FLOAT64): Dollar threshold for `fixed` alerts
- `stddev_multiplier` (FLOAT64): Standard deviation multiplier for `stddev` alerts
- `pct_of_average` (FLOAT64): Percentage threshold for `percent` alerts (e.g., 150.0)
- `cooldown_days` (INT64): Suppress re-firing for N days (default 7)
- `notify_emails` (STRING): Comma-separated recipient list

### `billing_alerts_log`

Dataset: `gcid-data-core.custom_sada_billing_views`

Stores fired alerts. Partitioned by `fired_date` with 365-day expiration.

Key columns:
- `notification_sent` (BOOL): Set TRUE by Cloud Function after email sent
- `rolling_7d_cost`, `threshold_value`, `weekly_mean`, `weekly_stddev`: Diagnostic values

## Data Freshness

The SADA billing export lags ~24h. The evaluation SQL excludes the most recent 1 day to avoid incomplete data. A 7-day window evaluated on Feb 16 covers Feb 8-14.

## Scope Filtering

Alerts are scoped by any combination of:
- `billing_account_id`
- `project_id`
- `team`
- `project_category` (Terra / Non-Terra / Account-level)
- `service_category` (Compute / Storage / Vertex AI / Networking / Support / Other)

NULL scope columns act as wildcards. Multiple non-NULL columns are ANDed.

## Cooldown

Each alert has a `cooldown_days` setting (default 7). After firing, the same `alert_id` won't fire again until the cooldown period expires. This prevents daily spam for persistent cost spikes.

## Operations

### Adding a new alert

Insert a row into `billing_alert_config`:

```sql
INSERT INTO `gcid-data-core.custom_sada_billing_views.billing_alert_config`
(alert_id, alert_name, enabled, alert_type, threshold_amount, notify_emails)
VALUES ('my-alert', 'My Alert', TRUE, 'fixed', 1000.0, 'team@example.com');
```

### Disabling an alert

```sql
UPDATE `gcid-data-core.custom_sada_billing_views.billing_alert_config`
SET enabled = FALSE WHERE alert_id = 'my-alert';
```

### Checking alert history

```sql
SELECT * FROM `gcid-data-core.custom_sada_billing_views.billing_alerts_log`
WHERE alert_id = 'my-alert' ORDER BY fired_at DESC;
```

### Re-sending a failed notification

```sql
UPDATE `gcid-data-core.custom_sada_billing_views.billing_alerts_log`
SET notification_sent = FALSE WHERE alert_log_id = '<uuid>';
```

Then trigger the Cloud Function manually or wait for the next scheduled run.

### Updating email template

Edit `cloud-function/templates/alert_email.html` and redeploy:

```bash
cd billing-alerts
gcloud functions deploy billing-alert-notifier \
  --gen2 --region=us-central1 --runtime=python312 \
  --source=cloud-function --entry-point=send_alert_notifications \
  --trigger-http --no-allow-unauthenticated
```

## Infrastructure

- **Cloud Function**: `billing-alert-notifier` (2nd gen, Python 3.12, us-central1)
- **Cloud Scheduler**: `billing-alert-trigger` (0945 UTC daily)
- **Service Account**: `billing-alert-notifier@gcid-data-core.iam.gserviceaccount.com`
- **Secret**: `projects/gcid-data-core/secrets/sendgrid-api-key`
- **BQ Scheduled Query**: `billing-alert-evaluation` (0930 UTC daily)
