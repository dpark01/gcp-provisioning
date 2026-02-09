#!/usr/bin/env bash
# Refreshes the billing_account_names mapping table in BigQuery.
# Pulls display names from gcloud billing accounts list and loads into BQ.
# Run a couple times a year or when accounts are added/renamed.
#
# NOTE: `gcloud billing accounts list` only returns accounts the caller has
# access to. SADA-owned billing accounts may not appear. If accounts are
# missing, you can manually append rows to the JSONL before loading, or
# adjust which billing account(s) gcloud is querying.

set -euo pipefail

DATASET="gcid-data-core.custom_sada_billing_views"
TABLE="${DATASET}.billing_account_names"
TMPFILE=$(mktemp /tmp/billing_accounts.XXXXXX.jsonl)
trap 'rm -f "$TMPFILE"' EXIT

echo "Fetching billing accounts from gcloud..."
gcloud billing accounts list --format='json' \
  | jq -c '.[] | {
      billing_account_id: .name | sub("billingAccounts/"; ""),
      display_name: .displayName,
      refreshed_at: (now | strftime("%Y-%m-%d %H:%M:%S UTC"))
    }' > "$TMPFILE"

ROW_COUNT=$(wc -l < "$TMPFILE" | tr -d ' ')
echo "Found ${ROW_COUNT} billing accounts."

echo "Creating dataset ${DATASET} (if not exists)..."
bq --project_id=gcid-data-core mk --dataset --force \
  --description="Custom views on SADA billing export" \
  custom_sada_billing_views

echo "Loading into ${TABLE} (full replace)..."
bq load \
  --project_id=gcid-data-core \
  --replace \
  --source_format=NEWLINE_DELIMITED_JSON \
  "custom_sada_billing_views.billing_account_names" \
  "$TMPFILE" \
  billing_account_id:STRING,display_name:STRING,refreshed_at:TIMESTAMP

echo "Verifying..."
bq query --nouse_legacy_sql \
  "SELECT COUNT(*) AS row_count FROM \`${TABLE}\`"

echo "Done. ${ROW_COUNT} billing accounts loaded into ${TABLE}."
