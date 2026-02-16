#!/usr/bin/env bash
set -euo pipefail

# Billing Cost Alerting System - Deployment Script
#
# Prerequisites:
#   - gcloud CLI authenticated with sufficient permissions
#   - SendGrid API key ready to store in Secret Manager
#   - billing_data table and its scheduled refresh already running
#
# Usage:
#   ./deploy.sh                    # Run all steps
#   ./deploy.sh --step tables      # Run a specific step
#   ./deploy.sh --step function
#   ./deploy.sh --step scheduler
#   ./deploy.sh --step scheduled-query

PROJECT="gcid-data-core"
REGION="us-central1"
DATASET="custom_sada_billing_views"
SA_NAME="billing-alert-notifier"
SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
FUNCTION_NAME="billing-alert-notifier"
SCHEDULER_JOB="billing-alert-trigger"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

step="${1:-all}"
if [[ "$step" == "--step" ]]; then
  step="${2:?Usage: $0 --step <tables|seed|secret|function|scheduler|scheduled-query>}"
fi

run_step() {
  [[ "$step" == "all" || "$step" == "$1" ]]
}

# --- Step 1: Create BQ tables ---
if run_step "tables"; then
  echo "==> Creating BigQuery tables..."
  bq query --project_id="$PROJECT" --use_legacy_sql=false \
    "CREATE TABLE IF NOT EXISTS \`${PROJECT}.${DATASET}.billing_alert_config\` (
      alert_id STRING NOT NULL,
      alert_name STRING NOT NULL,
      enabled BOOL NOT NULL,
      scope_billing_account_id STRING,
      scope_project_id STRING,
      scope_project_category STRING,
      scope_team STRING,
      scope_service_category STRING,
      rolling_window_days INT64 NOT NULL,
      alert_type STRING NOT NULL,
      threshold_amount FLOAT64,
      stddev_multiplier FLOAT64,
      pct_of_average FLOAT64,
      min_weekly_datapoints INT64 NOT NULL,
      cooldown_days INT64 NOT NULL,
      notify_emails STRING NOT NULL
    )"
  bq query --project_id="$PROJECT" --use_legacy_sql=false \
    "CREATE TABLE IF NOT EXISTS \`${PROJECT}.${DATASET}.billing_alerts_log\` (
      alert_log_id STRING NOT NULL,
      alert_id STRING NOT NULL,
      alert_name STRING NOT NULL,
      alert_type STRING NOT NULL,
      fired_at TIMESTAMP NOT NULL,
      scope_description STRING,
      rolling_7d_cost FLOAT64,
      threshold_value FLOAT64,
      weekly_mean FLOAT64,
      weekly_stddev FLOAT64,
      num_weekly_datapoints INT64,
      notify_emails STRING,
      notification_sent BOOL NOT NULL,
      fired_date DATE NOT NULL
    )
    PARTITION BY fired_date
    OPTIONS (partition_expiration_days = 365)"
  echo "    Done."
fi

# --- Step 2: Seed alert configs ---
if run_step "seed"; then
  echo "==> Seeding alert configurations..."
  bq query --project_id="$PROJECT" --use_legacy_sql=false < "$SCRIPT_DIR/seed-alert-config.sql"
  echo "    Done."
fi

# --- Step 3: Create service account ---
if run_step "sa"; then
  echo "==> Creating service account..."
  gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT" 2>/dev/null || \
    gcloud iam service-accounts create "$SA_NAME" \
      --project="$PROJECT" \
      --display-name="Billing Alert Notifier"

  # BQ data editor (read alerts_log, update notification_sent)
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/bigquery.dataEditor" \
    --condition=None \
    --quiet

  # BQ job user (run queries)
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/bigquery.jobUser" \
    --condition=None \
    --quiet

  # Secret Manager accessor
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/secretmanager.secretAccessor" \
    --condition=None \
    --quiet

  echo "    Done."
fi

# --- Step 4: Store SendGrid API key in Secret Manager ---
if run_step "secret"; then
  echo "==> Storing SendGrid API key in Secret Manager..."
  if gcloud secrets describe sendgrid-api-key --project="$PROJECT" 2>/dev/null; then
    echo "    Secret already exists. To update, run:"
    echo "    echo -n 'YOUR_KEY' | gcloud secrets versions add sendgrid-api-key --data-file=- --project=$PROJECT"
  else
    echo "    Creating secret. Paste your SendGrid API key and press Ctrl-D:"
    gcloud secrets create sendgrid-api-key \
      --project="$PROJECT" \
      --replication-policy="automatic" \
      --data-file=-
  fi
  echo "    Done."
fi

# --- Step 5: Deploy Cloud Function ---
if run_step "function"; then
  echo "==> Deploying Cloud Function..."
  gcloud functions deploy "$FUNCTION_NAME" \
    --gen2 \
    --project="$PROJECT" \
    --region="$REGION" \
    --runtime=python312 \
    --source="$SCRIPT_DIR/cloud-function" \
    --entry-point=send_alert_notifications \
    --trigger-http \
    --no-allow-unauthenticated \
    --service-account="$SA_EMAIL" \
    --set-env-vars="GCP_PROJECT=${PROJECT}" \
    --memory=256Mi \
    --timeout=120s \
    --max-instances=1
  echo "    Done."
fi

# --- Step 6: Create Cloud Scheduler job ---
if run_step "scheduler"; then
  echo "==> Creating Cloud Scheduler job..."
  FUNCTION_URL=$(gcloud functions describe "$FUNCTION_NAME" \
    --gen2 --project="$PROJECT" --region="$REGION" \
    --format='value(serviceConfig.uri)')

  # Delete existing job if present (idempotent)
  gcloud scheduler jobs delete "$SCHEDULER_JOB" \
    --project="$PROJECT" --location="$REGION" --quiet 2>/dev/null || true

  gcloud scheduler jobs create http "$SCHEDULER_JOB" \
    --project="$PROJECT" \
    --location="$REGION" \
    --schedule="45 9 * * *" \
    --time-zone="UTC" \
    --uri="$FUNCTION_URL" \
    --http-method=POST \
    --oidc-service-account-email="$SA_EMAIL" \
    --oidc-token-audience="$FUNCTION_URL"
  echo "    Done."
fi

# --- Step 7: Create BQ Scheduled Query ---
if run_step "scheduled-query"; then
  echo "==> Creating BQ scheduled query for alert evaluation..."
  QUERY=$(cat "$SCRIPT_DIR/evaluate-alerts.sql")

  bq mk --transfer_config \
    --project_id="$PROJECT" \
    --data_source=scheduled_query \
    --target_dataset="$DATASET" \
    --display_name="billing-alert-evaluation" \
    --schedule="every day 09:30" \
    --params="{\"query\":$(echo "$QUERY" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}"
  echo "    Done."
fi

echo ""
echo "=== Deployment complete ==="
echo ""
echo "Verification steps:"
echo "  1. Check config: bq query --project_id=$PROJECT 'SELECT * FROM $DATASET.billing_alert_config'"
echo "  2. Dry run evaluation SQL in BQ console"
echo "  3. Test Cloud Function: gcloud scheduler jobs run $SCHEDULER_JOB --project=$PROJECT --location=$REGION"
echo "  4. Check logs: gcloud functions logs read $FUNCTION_NAME --gen2 --project=$PROJECT --region=$REGION"
