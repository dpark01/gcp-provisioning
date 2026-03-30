-- claude_vertex_ai_billing: Unified Vertex AI billing view across direct exports.
--
-- Reads from direct GCP billing exports (one per billing account) and unions
-- them into a single view filtered to Claude model services. Direct exports have
-- ~6 hour latency and are partitioned for efficient scanning.
--
-- NOTE: In the raw detailed billing export, Claude models appear as their own
-- top-level service descriptions (e.g., "Claude Opus 4.6", "Claude Sonnet 4.5")
-- rather than under "Vertex AI". The filter uses service.description LIKE 'Claude%'
-- to capture these, plus 'Vertex AI' for any native Vertex AI charges.
--
-- Export table naming convention:
--   gcp_billing_export_resource_v1_<BILLING_ACCOUNT_ID_WITH_UNDERSCORES>
--
-- Billing accounts (Broad Institute):
--   00864F-515C74-8B1641 → gcid-data-core.billing_export
--   011F41-0941F7-749F4B → broad-hvp-dasc.billing_export
--   0193CA-41033B-3FF267 → gcid-viral-seq.billing_export
--   01EA4B-6607E9-C37280 → gcid-viral-seq.billing_export
--   01EABF-8D854B-B4B3D0 → sabeti-ai.billing_export
--   013A53-04CB08-63E4C8 → dsi-resources.billing_export
--
-- Billing accounts (HHMI):
--   01EC6B-15AAB1-294340 → sabeti-mgmt.billing_export
--
-- Usage:
--   bq query --nouse_legacy_sql --project_id=gcid-data-core < vertex-ai/create-billing-union-view.sql

CREATE OR REPLACE VIEW
  `gcid-data-core.custom_sada_billing_views.claude_vertex_ai_billing`
AS

-- ============================================================================
-- Raw UNION ALL of direct billing exports, filtered to Claude/Vertex AI
-- ============================================================================
WITH raw_exports AS (
  -- Broad: gcid-data-core (00864F-515C74-8B1641)
  SELECT * FROM `gcid-data-core.billing_export.gcp_billing_export_resource_v1_00864F_515C74_8B1641`
  WHERE service.description LIKE 'Claude%' OR service.description = 'Vertex AI'
  UNION ALL
  -- Broad: broad-hvp-dasc (011F41-0941F7-749F4B)
  SELECT * FROM `broad-hvp-dasc.billing_export.gcp_billing_export_resource_v1_011F41_0941F7_749F4B`
  WHERE service.description LIKE 'Claude%' OR service.description = 'Vertex AI'
  UNION ALL
  -- Broad: gcid-viral-seq (0193CA-41033B-3FF267)
  SELECT * FROM `gcid-viral-seq.billing_export.gcp_billing_export_resource_v1_0193CA_41033B_3FF267`
  WHERE service.description LIKE 'Claude%' OR service.description = 'Vertex AI'
  UNION ALL
  -- Broad: gcid-viral-seq (01EA4B-6607E9-C37280)
  SELECT * FROM `gcid-viral-seq.billing_export.gcp_billing_export_resource_v1_01EA4B_6607E9_C37280`
  WHERE service.description LIKE 'Claude%' OR service.description = 'Vertex AI'
  UNION ALL
  -- Broad: sabeti-ai (01EABF-8D854B-B4B3D0)
  SELECT * FROM `sabeti-ai.billing_export.gcp_billing_export_resource_v1_01EABF_8D854B_B4B3D0`
  WHERE service.description LIKE 'Claude%' OR service.description = 'Vertex AI'
  UNION ALL
  -- Broad: dsi-resources (013A53-04CB08-63E4C8)
  SELECT * FROM `dsi-resources.billing_export.gcp_billing_export_resource_v1_013A53_04CB08_63E4C8`
  WHERE service.description LIKE 'Claude%' OR service.description = 'Vertex AI'
  UNION ALL
  -- HHMI: sabeti-mgmt (01EC6B-15AAB1-294340)
  SELECT * FROM `sabeti-mgmt.billing_export.gcp_billing_export_resource_v1_01EC6B_15AAB1_294340`
  WHERE service.description LIKE 'Claude%' OR service.description = 'Vertex AI'
)

-- ============================================================================
-- Transform to standard schema with account name lookup
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
FROM raw_exports
LEFT JOIN `gcid-data-core.custom_sada_billing_views.billing_account_names` n
  USING (billing_account_id);
