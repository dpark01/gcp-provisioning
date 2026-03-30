#!/usr/bin/env bash
# Refreshes the materialized billing_data table with a 90-day rolling window.
# Uses direct billing exports (partitioned, ~15 GB scan) instead of the
# unpartitioned SADA master export (~5.7 TB scan).
#
# Schedule: Daily at 6 AM PT (captures overnight exports)
# Optional: Run manually for immediate refresh during active investigations.
#
# Usage:
#   ./refresh-materialized-billing.sh

set -euo pipefail

PROJECT="gcid-data-core"
DATASET="custom_sada_billing_views"
TABLE="${DATASET}.billing_data"
NAMES_TABLE="${DATASET}.billing_account_names"

echo "=== Billing Data Materialization ==="
echo "Target: ${PROJECT}.${TABLE}"
echo "Source: Direct billing exports (9 accounts)"
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
  description = 'Materialized 90-day rolling window from direct billing exports. Refreshed daily by refresh-materialized-billing.sh.',
  partition_expiration_days = 95
);
EOF
echo "Table ready."
echo ""

# Step 2: Full refresh using DELETE + INSERT
echo "Step 2: Refreshing data (DELETE + INSERT)..."
echo "  Deleting existing data..."
bq query --nouse_legacy_sql --project_id="${PROJECT}" --format=none \
  "DELETE FROM \`${PROJECT}.${TABLE}\` WHERE TRUE"

echo "  Inserting 90-day rolling window from direct billing exports..."
bq query --nouse_legacy_sql --project_id="${PROJECT}" --format=none <<'EOF'
INSERT INTO `gcid-data-core.custom_sada_billing_views.billing_data`

WITH raw_exports AS (
  -- Broad: gcid-data-core (00864F-515C74-8B1641)
  SELECT * FROM `gcid-data-core.billing_export.gcp_billing_export_resource_v1_00864F_515C74_8B1641`
  WHERE usage_start_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
  UNION ALL
  -- Broad: broad-hvp-dasc (011F41-0941F7-749F4B)
  SELECT * FROM `broad-hvp-dasc.billing_export.gcp_billing_export_resource_v1_011F41_0941F7_749F4B`
  WHERE usage_start_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
  UNION ALL
  -- Broad: gcid-viral-seq (0193CA-41033B-3FF267)
  SELECT * FROM `gcid-viral-seq.billing_export.gcp_billing_export_resource_v1_0193CA_41033B_3FF267`
  WHERE usage_start_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
  UNION ALL
  -- Broad: gcid-viral-seq (01EA4B-6607E9-C37280)
  SELECT * FROM `gcid-viral-seq.billing_export.gcp_billing_export_resource_v1_01EA4B_6607E9_C37280`
  WHERE usage_start_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
  UNION ALL
  -- Broad: sabeti-ai (01EABF-8D854B-B4B3D0)
  SELECT * FROM `sabeti-ai.billing_export.gcp_billing_export_resource_v1_01EABF_8D854B_B4B3D0`
  WHERE usage_start_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
  UNION ALL
  -- Broad: dsi-resources (013A53-04CB08-63E4C8)
  SELECT * FROM `dsi-resources.billing_export.gcp_billing_export_resource_v1_013A53_04CB08_63E4C8`
  WHERE usage_start_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
  UNION ALL
  -- Broad: sabeti-txnomics (016D12-30A760-F5696D)
  SELECT * FROM `sabeti-txnomics.billing_export.gcp_billing_export_resource_v1_016D12_30A760_F5696D`
  WHERE usage_start_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
  UNION ALL
  -- Broad: sabeti-dph-elc (01E00D-6EA2B5-865FA0)
  SELECT * FROM `sabeti-dph-elc.billing_export.gcp_billing_export_resource_v1_01E00D_6EA2B5_865FA0`
  WHERE usage_start_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
  UNION ALL
  -- HHMI: sabeti-mgmt (01EC6B-15AAB1-294340)
  SELECT * FROM `sabeti-mgmt.billing_export.gcp_billing_export_resource_v1_01EC6B_15AAB1_294340`
  WHERE usage_start_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
)

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
  t.team AS team,
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
FROM raw_exports b
INNER JOIN `gcid-data-core.custom_sada_billing_views.billing_account_names` n
  ON b.billing_account_id = n.billing_account_id
LEFT JOIN `gcid-data-core.custom_sada_billing_views.project_team_mapping` t
  ON b.project.id = t.project_id
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
