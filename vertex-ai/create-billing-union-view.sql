-- claude_vertex_ai_billing: Unified Vertex AI billing view across direct exports.
--
-- Reads from direct GCP billing exports (one per billing account) and unions
-- them into a single view filtered to Claude model services. Direct exports have
-- ~6 hour latency vs ~36 hours from SADA.
--
-- NOTE: In the raw detailed billing export, Claude models appear as their own
-- top-level service descriptions (e.g., "Claude Opus 4.6", "Claude Sonnet 4.5")
-- rather than under "Vertex AI". SADA normalizes these to service_category =
-- 'Vertex AI', but direct exports require filtering on service.description LIKE 'Claude%'.
--
-- Historical transition: dates before the cutoff read from the SADA billing_data
-- table to preserve ~90 days of history. Dates on or after the cutoff read from
-- direct exports. After 90+ days the SADA partition expires and direct exports
-- carry all history. The cutoff date should be set to the date the direct
-- exports are first populated (i.e., when this view goes live).
--
-- Export table naming convention:
--   gcp_billing_export_resource_v1_<BILLING_ACCOUNT_ID_WITH_UNDERSCORES>
--
-- Billing accounts:
--   00864F-515C74-8B1641 → gcid-data-core.billing_export
--   011F41-0941F7-749F4B → broad-hvp-dasc.billing_export
--   0193CA-41033B-3FF267 → gcid-viral-seq.billing_export
--   01EABF-8D854B-B4B3D0 → sabeti-ai.billing_export
--   013A53-04CB08-63E4C8 → dsi-resources.billing_export
--
-- Usage:
--   bq query --nouse_legacy_sql --project_id=gcid-data-core < vertex-ai/create-billing-union-view.sql

CREATE OR REPLACE VIEW
  `gcid-data-core.custom_sada_billing_views.claude_vertex_ai_billing`
AS

-- ============================================================================
-- Cutoff date for SADA → direct export transition.
-- Dates BEFORE this: read from SADA billing_data (historical backfill).
-- Dates ON OR AFTER this: read from direct exports (~6h latency).
-- Set this to the date direct exports are first populated.
-- ============================================================================

-- ============================================================================
-- Historical data from SADA (before cutoff)
-- ============================================================================
SELECT
  billing_account_id,
  billing_account_name,
  usage_date,
  project_id,
  'Vertex AI' AS service_name,
  sku_description,
  region,
  cost,
  net_cost,
  usage_amount,
  usage_unit,
  CAST(NULL AS TIMESTAMP) AS export_time
FROM `gcid-data-core.custom_sada_billing_views.billing_data`
WHERE service_category = 'Vertex AI'
  AND usage_date < DATE '2026-02-15'

UNION ALL

-- ============================================================================
-- Direct export: gcid-data-core (billing account 00864F-515C74-8B1641)
-- ============================================================================
SELECT
  billing_account_id,
  n.display_name AS billing_account_name,
  DATE(usage_start_time) AS usage_date,
  project.id AS project_id,
  service.description AS service_name,
  sku.description AS sku_description,
  location.region AS region,
  cost,
  cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0) AS net_cost,
  usage.amount AS usage_amount,
  usage.unit AS usage_unit,
  export_time
FROM `gcid-data-core.billing_export.gcp_billing_export_resource_v1_00864F_515C74_8B1641`
LEFT JOIN `gcid-data-core.custom_sada_billing_views.billing_account_names` n
  USING (billing_account_id)
WHERE service.description LIKE 'Claude%'
  AND DATE(usage_start_time) >= DATE '2026-02-15'

UNION ALL

-- ============================================================================
-- Direct export: broad-hvp-dasc (billing account 011F41-0941F7-749F4B)
-- ============================================================================
SELECT
  billing_account_id,
  n.display_name AS billing_account_name,
  DATE(usage_start_time) AS usage_date,
  project.id AS project_id,
  service.description AS service_name,
  sku.description AS sku_description,
  location.region AS region,
  cost,
  cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0) AS net_cost,
  usage.amount AS usage_amount,
  usage.unit AS usage_unit,
  export_time
FROM `broad-hvp-dasc.billing_export.gcp_billing_export_resource_v1_011F41_0941F7_749F4B`
LEFT JOIN `gcid-data-core.custom_sada_billing_views.billing_account_names` n
  USING (billing_account_id)
WHERE service.description LIKE 'Claude%'
  AND DATE(usage_start_time) >= DATE '2026-02-15'

UNION ALL

-- ============================================================================
-- Direct export: gcid-viral-seq (billing account 0193CA-41033B-3FF267)
-- ============================================================================
SELECT
  billing_account_id,
  n.display_name AS billing_account_name,
  DATE(usage_start_time) AS usage_date,
  project.id AS project_id,
  service.description AS service_name,
  sku.description AS sku_description,
  location.region AS region,
  cost,
  cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0) AS net_cost,
  usage.amount AS usage_amount,
  usage.unit AS usage_unit,
  export_time
FROM `gcid-viral-seq.billing_export.gcp_billing_export_resource_v1_0193CA_41033B_3FF267`
LEFT JOIN `gcid-data-core.custom_sada_billing_views.billing_account_names` n
  USING (billing_account_id)
WHERE service.description LIKE 'Claude%'
  AND DATE(usage_start_time) >= DATE '2026-02-15'

UNION ALL

-- ============================================================================
-- Direct export: sabeti-ai (billing account 01EABF-8D854B-B4B3D0)
-- ============================================================================
SELECT
  billing_account_id,
  n.display_name AS billing_account_name,
  DATE(usage_start_time) AS usage_date,
  project.id AS project_id,
  service.description AS service_name,
  sku.description AS sku_description,
  location.region AS region,
  cost,
  cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0) AS net_cost,
  usage.amount AS usage_amount,
  usage.unit AS usage_unit,
  export_time
FROM `sabeti-ai.billing_export.gcp_billing_export_resource_v1_01EABF_8D854B_B4B3D0`
LEFT JOIN `gcid-data-core.custom_sada_billing_views.billing_account_names` n
  USING (billing_account_id)
WHERE service.description LIKE 'Claude%'
  AND DATE(usage_start_time) >= DATE '2026-02-15'

UNION ALL

-- ============================================================================
-- Direct export: dsi-resources (billing account 013A53-04CB08-63E4C8)
-- ============================================================================
SELECT
  billing_account_id,
  n.display_name AS billing_account_name,
  DATE(usage_start_time) AS usage_date,
  project.id AS project_id,
  service.description AS service_name,
  sku.description AS sku_description,
  location.region AS region,
  cost,
  cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0) AS net_cost,
  usage.amount AS usage_amount,
  usage.unit AS usage_unit,
  export_time
FROM `dsi-resources.billing_export.gcp_billing_export_resource_v1_013A53_04CB08_63E4C8`
LEFT JOIN `gcid-data-core.custom_sada_billing_views.billing_account_names` n
  USING (billing_account_id)
WHERE service.description LIKE 'Claude%'
  AND DATE(usage_start_time) >= DATE '2026-02-15';
