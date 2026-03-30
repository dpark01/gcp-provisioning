-- Scheduled query to refresh the billing_data table with a 90-day rolling window.
-- Runs daily at 0900 UTC via BQ Scheduled Queries.
--
-- This replaces the entire table contents each run. The table is date-partitioned
-- for efficient querying, with 95-day partition expiration as a safety buffer.
--
-- Data sources: Direct GCP billing exports (partitioned, ~6h latency).
-- Each billing account has its own export table in a project we control.
-- This replaces the previous approach of reading from the unpartitioned SADA
-- master export view, which scanned ~5.7 TB per run.
--
-- Billing accounts:
--   Broad Institute:
--     00864F-515C74-8B1641 → gcid-data-core.billing_export
--     011F41-0941F7-749F4B → broad-hvp-dasc.billing_export
--     0193CA-41033B-3FF267 → gcid-viral-seq.billing_export
--     01EA4B-6607E9-C37280 → gcid-viral-seq.billing_export
--     01EABF-8D854B-B4B3D0 → sabeti-ai.billing_export
--     013A53-04CB08-63E4C8 → dsi-resources.billing_export
--     016D12-30A760-F5696D → sabeti-txnomics.billing_export
--     01E00D-6EA2B5-865FA0 → sabeti-dph-elc.billing_export
--   HHMI:
--     01EC6B-15AAB1-294340 → sabeti-mgmt.billing_export
--
-- To add a new billing account:
--   1. Set up direct export (setup-billing-export.sh)
--   2. Add a UNION ALL leg to the raw_exports CTE below
--   3. Ensure billing_account_names has the account (refresh-billing-account-names.sh)
--   4. Update the BQ scheduled query with this SQL
--
-- NOTE: Uses INNER JOIN on billing_account_names to filter to tracked accounts.

CREATE OR REPLACE TABLE `gcid-data-core.custom_sada_billing_views.billing_data`
PARTITION BY usage_date
OPTIONS (
  description = 'Materialized 90-day rolling window from direct billing exports. Refreshed daily at 0900 UTC.',
  partition_expiration_days = 95
)
AS

-- ============================================================================
-- Raw UNION ALL of direct billing exports (partitioned, cheap to scan)
-- ============================================================================
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

-- ============================================================================
-- Transform and materialize
-- ============================================================================
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
  ON b.project.id = t.project_id;
