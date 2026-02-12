-- claude_code_user_costs: Unified per-user Claude Code cost view.
--
-- Combines two attribution methods:
--   1. Direct (single_user projects): user = project owner from mapping table
--   2. Proportional (shared projects): user's share based on API call counts per model
--
-- Proportional attribution joins billing and audit data at (project, date, model_family)
-- to ensure users of expensive models are attributed correctly.
--
-- Reads from:
--   - billing_data (materialized table, refreshed daily)
--   - claude_code_projects (mapping table)
--   - claude_code_daily_usage (audit log aggregation view)
--
-- Usage:
--   bq query --nouse_legacy_sql --project_id=gcid-data-core < vertex-ai/create-user-costs-view.sql

CREATE OR REPLACE VIEW
  `gcid-data-core.custom_sada_billing_views.claude_code_user_costs`
AS

-- ============================================================================
-- Helper: Extract model_family from billing SKU descriptions
-- ============================================================================
WITH billing_with_model AS (
  SELECT
    b.*,
    CASE
      -- 3.x models
      WHEN LOWER(b.sku_description) LIKE '%3.5 sonnet%'
        OR LOWER(b.sku_description) LIKE '%3-5 sonnet%'
        OR LOWER(b.sku_description) LIKE '%3_5 sonnet%'      THEN 'sonnet-3.5'
      WHEN LOWER(b.sku_description) LIKE '%3.5 haiku%'
        OR LOWER(b.sku_description) LIKE '%3-5 haiku%'
        OR LOWER(b.sku_description) LIKE '%3_5 haiku%'        THEN 'haiku-3.5'
      WHEN LOWER(b.sku_description) LIKE '%opus 3%'
        OR LOWER(b.sku_description) LIKE '%3 opus%'            THEN 'opus-3'
      -- 4.x models: sub-versions BEFORE base version (first match wins)
      -- Google uses both dots (4.1, 4.5) and spaces (4 5, 4 6) inconsistently
      WHEN LOWER(b.sku_description) LIKE '%sonnet 4.5%'
        OR LOWER(b.sku_description) LIKE '%sonnet 4 5%'       THEN 'sonnet-4.5'
      WHEN LOWER(b.sku_description) LIKE '%sonnet 4%'
        OR LOWER(b.sku_description) LIKE '%sonnet-4%'          THEN 'sonnet-4'
      WHEN LOWER(b.sku_description) LIKE '%opus 4.6%'
        OR LOWER(b.sku_description) LIKE '%opus 4 6%'          THEN 'opus-4.6'
      WHEN LOWER(b.sku_description) LIKE '%opus 4.5%'
        OR LOWER(b.sku_description) LIKE '%opus 4 5%'          THEN 'opus-4.5'
      WHEN LOWER(b.sku_description) LIKE '%opus 4.1%'
        OR LOWER(b.sku_description) LIKE '%opus 4 1%'          THEN 'opus-4.1'
      WHEN LOWER(b.sku_description) LIKE '%opus 4%'            THEN 'opus-4'
      WHEN LOWER(b.sku_description) LIKE '%haiku 4.5%'
        OR LOWER(b.sku_description) LIKE '%haiku 4 5%'         THEN 'haiku-4.5'
      WHEN LOWER(b.sku_description) LIKE '%haiku 4%'
        OR LOWER(b.sku_description) LIKE '%haiku-4%'            THEN 'haiku-4'
      -- Graceful fallback: raw SKU description instead of generic 'other'
      ELSE LOWER(b.sku_description)
    END AS model_family
  FROM `gcid-data-core.custom_sada_billing_views.billing_data` b
  WHERE b.service_category = 'Vertex AI'
),

-- ============================================================================
-- Branch 1: Single-user projects (direct attribution)
-- ============================================================================
single_user_costs AS (
  SELECT
    b.usage_date,
    p.user_email,
    b.project_id,
    b.billing_account_id,
    b.billing_account_name,
    b.sku_description,
    b.model_family,
    b.net_cost AS cost,
    b.usage_amount,
    b.usage_unit,
    'direct' AS attribution_method
  FROM billing_with_model b
  JOIN `gcid-data-core.custom_sada_billing_views.claude_code_projects` p
    ON b.project_id = p.project_id
  WHERE p.project_type = 'single_user'
),

-- ============================================================================
-- Branch 2: Shared projects (proportional attribution by model)
-- ============================================================================

-- Step 2a: Total requests per (project, date, model_family)
shared_model_totals AS (
  SELECT
    usage_date,
    project_id,
    model_family,
    SUM(request_count) AS total_requests
  FROM `gcid-data-core.custom_sada_billing_views.claude_code_daily_usage`
  GROUP BY 1, 2, 3
),

-- Step 2b: Join billing rows with audit data at (project, date, model_family)
-- LEFT JOIN ensures billing rows without audit matches become 'unattributed'
shared_user_costs AS (
  SELECT
    b.usage_date,
    COALESCE(u.user_email, 'unattributed') AS user_email,
    b.project_id,
    b.billing_account_id,
    b.billing_account_name,
    b.sku_description,
    b.model_family,
    -- When audit logs exist: split proportionally
    -- When no audit logs: entire cost goes to 'unattributed'
    CASE
      WHEN t.total_requests > 0 AND t.total_requests IS NOT NULL
        THEN b.net_cost * SAFE_DIVIDE(u.request_count, t.total_requests)
      ELSE b.net_cost
    END AS cost,
    CASE
      WHEN t.total_requests > 0 AND t.total_requests IS NOT NULL
        THEN b.usage_amount * SAFE_DIVIDE(u.request_count, t.total_requests)
      ELSE b.usage_amount
    END AS usage_amount,
    b.usage_unit,
    CASE
      WHEN t.total_requests > 0 AND t.total_requests IS NOT NULL
        THEN 'proportional'
      ELSE 'unattributed'
    END AS attribution_method
  FROM billing_with_model b
  JOIN `gcid-data-core.custom_sada_billing_views.claude_code_projects` p
    ON b.project_id = p.project_id
  LEFT JOIN `gcid-data-core.custom_sada_billing_views.claude_code_daily_usage` u
    ON b.project_id = u.project_id
    AND b.usage_date = u.usage_date
    AND b.model_family = u.model_family
  LEFT JOIN shared_model_totals t
    ON b.project_id = t.project_id
    AND b.usage_date = t.usage_date
    AND b.model_family = t.model_family
  WHERE p.project_type = 'shared'
)

-- ============================================================================
-- Union both branches
-- ============================================================================
SELECT * FROM single_user_costs
UNION ALL
SELECT * FROM shared_user_costs;
