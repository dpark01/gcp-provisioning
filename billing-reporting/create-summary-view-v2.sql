-- Creates the billing_account_summary_v2 view over the MATERIALIZED billing_data table.
-- This view is essentially a passthrough for compatibility with existing queries,
-- but benefits from the partitioned, pre-computed data in billing_data.
--
-- Key differences from v1:
-- - Points to materialized table (billing_data) instead of SADA export
-- - Queries only scan the relevant date partitions (~1 GB per 14 days vs ~98 GB)
-- - Data is refreshed daily by refresh-materialized-billing.sh
--
-- Usage:
--   bq query --nouse_legacy_sql --project_id=gcid-data-core < create-summary-view-v2.sql

CREATE OR REPLACE VIEW
  `gcid-data-core.custom_sada_billing_views.billing_account_summary_v2` AS
SELECT
  billing_account_id,
  billing_account_name,
  usage_date,
  project_id,
  project_name,
  project_category,
  terra_billing_project,
  terra_workspace_name,
  team,
  service_name,
  service_category,
  sku_description,
  region,
  cost,
  net_cost,
  usage_amount,
  usage_unit
FROM `gcid-data-core.custom_sada_billing_views.billing_data`;
