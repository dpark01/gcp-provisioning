-- Creates the materialized billing_data table, partitioned by usage_date.
-- This table stores a 90-day rolling window of billing data from the SADA export.
-- The table is date-partitioned to enable efficient filtering in downstream queries.
--
-- IMPORTANT: This creates an EMPTY table. Use refresh-materialized-billing.sh to populate it.
--
-- Usage:
--   bq query --nouse_legacy_sql --project_id=gcid-data-core < create-materialized-billing-table.sql

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
