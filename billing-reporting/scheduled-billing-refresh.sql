-- Scheduled query to refresh the billing_data table with a 90-day rolling window.
-- Runs daily at 0900 UTC via BQ Scheduled Queries.
--
-- This replaces the entire table contents each run. The table is date-partitioned
-- for efficient querying, with 95-day partition expiration as a safety buffer.
--
-- NOTE: Uses INNER JOIN to only include billing accounts with mapped names.
-- To add more accounts, update billing_account_names table and re-run.

CREATE OR REPLACE TABLE `gcid-data-core.custom_sada_billing_views.billing_data`
PARTITION BY usage_date
OPTIONS (
  description = 'Materialized 90-day rolling window of SADA billing export. Refreshed daily at 0900 UTC.',
  partition_expiration_days = 95
)
AS
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
FROM `broad-gcp-billing.gcp_billing_export_views.sada_billing_export_resource_v1_001AC2_2B914D_822931` b
INNER JOIN `gcid-data-core.custom_sada_billing_views.billing_account_names` n
  ON b.billing_account_id = n.billing_account_id
WHERE b.usage_start_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY);
