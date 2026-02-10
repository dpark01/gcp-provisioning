#!/usr/bin/env bash
# Refreshes the materialized billing_data table with a 90-day rolling window.
# This reduces query costs from ~98 GB per query to a simple table scan.
#
# Schedule: Daily at 6 AM PT (captures overnight exports, yesterday ~90% complete)
# Optional: Run manually for immediate refresh during active investigations.
#
# Usage:
#   ./refresh-materialized-billing.sh
#
# The script uses MERGE to efficiently update the table:
# - Deletes rows older than 90 days
# - Inserts/updates rows from the last 90 days

set -euo pipefail

PROJECT="gcid-data-core"
DATASET="custom_sada_billing_views"
TABLE="${DATASET}.billing_data"
SADA_EXPORT="broad-gcp-billing.gcp_billing_export_views.sada_billing_export_resource_v1_001AC2_2B914D_822931"
NAMES_TABLE="${DATASET}.billing_account_names"

echo "=== Billing Data Materialization ==="
echo "Target: ${PROJECT}.${TABLE}"
echo "Source: ${SADA_EXPORT}"
echo "Window: 90 days"
echo ""

# Step 1: Ensure the table exists
echo "Step 1: Ensuring table exists..."
bq query --nouse_legacy_sql --project_id="${PROJECT}" --format=none <<'EOF'
CREATE TABLE IF NOT EXISTS
  `gcid-data-core.custom_sada_billing_views.billing_data`
(
  billing_account_id STRING,
  billing_account_name STRING,
  usage_date DATE,
  project_id STRING,
  project_name STRING,
  project_category STRING,
  terra_billing_project STRING,
  terra_workspace_name STRING,
  team STRING,
  service_name STRING,
  service_category STRING,
  sku_description STRING,
  region STRING,
  cost FLOAT64,
  net_cost FLOAT64,
  usage_amount FLOAT64,
  usage_unit STRING
)
PARTITION BY usage_date
OPTIONS (
  description = 'Materialized 90-day rolling window of SADA billing export. Refreshed daily by refresh-materialized-billing.sh.',
  partition_expiration_days = 95
);
EOF
echo "Table ready."
echo ""

# Step 2: Full refresh using DELETE + INSERT
# We use this approach because:
# - MERGE would require a unique key (we don't have one at this granularity)
# - The SADA export updates historical data retroactively (labels, corrections)
# - 90-day refresh is ~98 GB regardless of approach
echo "Step 2: Refreshing data (DELETE + INSERT)..."
echo "  Deleting existing data..."
bq query --nouse_legacy_sql --project_id="${PROJECT}" --format=none \
  "DELETE FROM \`${PROJECT}.${TABLE}\` WHERE TRUE"

echo "  Inserting 90-day rolling window from SADA export..."
bq query --nouse_legacy_sql --project_id="${PROJECT}" --format=none <<EOF
INSERT INTO \`${PROJECT}.${TABLE}\`
SELECT
  b.billing_account_id,
  n.display_name AS billing_account_name,
  DATE(b.usage_start_time) AS usage_date,
  b.project.id AS project_id,
  b.project.name AS project_name,
  CASE
    WHEN b.project.id LIKE 'terra-%' THEN 'Terra'
    WHEN b.project.id IS NULL THEN 'Account-level'
    ELSE 'Non-Terra'
  END AS project_category,
  (SELECT value FROM UNNEST(b.project.labels) WHERE key = 'workspacenamespace')
    AS terra_billing_project,
  (SELECT value FROM UNNEST(b.project.labels) WHERE key = 'workspacename')
    AS terra_workspace_name,
  (SELECT value FROM UNNEST(b.project.labels) WHERE key = 'team')
    AS team,
  b.service.description AS service_name,
  CASE
    WHEN b.service.description = 'Compute Engine' THEN 'Compute'
    WHEN b.service.description = 'Cloud Storage' THEN 'Storage'
    WHEN b.service.description = 'Vertex AI'
         OR LOWER(b.service.description) LIKE '%claude%'
         OR LOWER(b.service.description) LIKE '%opus%'
         OR LOWER(b.service.description) LIKE '%sonnet%'
         OR LOWER(b.service.description) LIKE '%haiku%'
      THEN 'Vertex AI'
    WHEN b.service.description = 'Networking' THEN 'Networking'
    WHEN b.service.description = 'Support' THEN 'Support'
    ELSE 'Other'
  END AS service_category,
  b.sku.description AS sku_description,
  b.location.region AS region,
  b.cost,
  b.cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(b.credits) c), 0) AS net_cost,
  b.usage.amount AS usage_amount,
  b.usage.unit AS usage_unit
FROM \`${SADA_EXPORT}\` b
LEFT JOIN \`${PROJECT}.${NAMES_TABLE}\` n
  ON b.billing_account_id = n.billing_account_id
WHERE b.usage_start_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
EOF
echo "  Insert complete."
echo ""

# Step 3: Verify row count and date range
echo "Step 3: Verifying..."
bq query --nouse_legacy_sql --project_id="${PROJECT}" <<'EOF'
SELECT
  COUNT(*) AS total_rows,
  COUNT(DISTINCT billing_account_id) AS billing_accounts,
  COUNT(DISTINCT project_id) AS projects,
  MIN(usage_date) AS earliest_date,
  MAX(usage_date) AS latest_date,
  ROUND(SUM(net_cost), 2) AS total_net_cost
FROM `gcid-data-core.custom_sada_billing_views.billing_data`
EOF

echo ""
echo "=== Refresh Complete ==="
echo "The billing_data table now contains the last 90 days of billing data."
echo "Looker Studio data sources should be pointed at:"
echo "  gcid-data-core.custom_sada_billing_views.billing_data"
