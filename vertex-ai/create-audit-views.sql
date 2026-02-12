-- Audit log views for Claude Code usage attribution in shared projects.
--
-- Two views:
--   1. claude_code_audit_logs   - Raw audit log entries with model extraction
--   2. claude_code_daily_usage  - Daily aggregation by user/project/model for proportional splits
--
-- These views read from the audit log wildcard table in billing_export.
-- For each new shared project, a log sink must route audit logs to this dataset
-- (see setup-audit-sink.sh).
--
-- Usage:
--   bq query --nouse_legacy_sql --project_id=gcid-data-core < vertex-ai/create-audit-views.sql

-- ============================================================================
-- View 1: Raw audit log entries with model extraction
-- ============================================================================
CREATE OR REPLACE VIEW
  `gcid-data-core.custom_sada_billing_views.claude_code_audit_logs`
AS
WITH raw_logs AS (
  SELECT
    protopayload_auditlog.authenticationInfo.principalEmail AS user_email,
    resource.labels.project_id AS project_id,
    REGEXP_EXTRACT(
      protopayload_auditlog.resourceName,
      r'/models/(claude-[a-z0-9.-]+?)(?:@|$)'
    ) AS model_name,
    DATE(timestamp) AS usage_date,
    timestamp
  FROM `gcid-data-core.billing_export.cloudaudit_googleapis_com_data_access_*`
  WHERE protopayload_auditlog.serviceName = 'aiplatform.googleapis.com'
    AND protopayload_auditlog.resourceName LIKE '%anthropic%'
)
SELECT
  user_email,
  project_id,
  model_name,
  -- Normalize to model family for joining with billing SKUs.
  -- Billing SKUs group by model family (e.g., "Claude 3.5 Sonnet"), not by snapshot.
  -- Update this CASE when Anthropic releases a new model family.
  CASE
    WHEN model_name LIKE 'claude-3-5-sonnet%'
      OR model_name LIKE 'claude-3.5-sonnet%'   THEN 'sonnet-3.5'
    WHEN model_name LIKE 'claude-sonnet-4%'      THEN 'sonnet-4'
    WHEN model_name LIKE 'claude-3-5-haiku%'
      OR model_name LIKE 'claude-3.5-haiku%'     THEN 'haiku-3.5'
    WHEN model_name LIKE 'claude-haiku-4%'       THEN 'haiku-4'
    WHEN model_name LIKE 'claude-3-opus%'
      OR model_name LIKE 'claude-3.0-opus%'      THEN 'opus-3'
    WHEN model_name LIKE 'claude-opus-4%'        THEN 'opus-4'
    -- Preemptive future models
    WHEN model_name LIKE 'claude-sonnet-5%'      THEN 'sonnet-5'
    WHEN model_name LIKE 'claude-opus-5%'        THEN 'opus-5'
    WHEN model_name LIKE 'claude-haiku-5%'       THEN 'haiku-5'
    -- Graceful fallback: raw model name instead of generic 'other'
    ELSE COALESCE(model_name, 'unknown')
  END AS model_family,
  usage_date,
  timestamp
FROM raw_logs;


-- ============================================================================
-- View 2: Daily usage counts by user/project/model_family
-- Used for proportional cost attribution in shared projects.
-- ============================================================================
CREATE OR REPLACE VIEW
  `gcid-data-core.custom_sada_billing_views.claude_code_daily_usage`
AS
SELECT
  usage_date,
  project_id,
  user_email,
  model_family,
  COUNT(*) AS request_count
FROM `gcid-data-core.custom_sada_billing_views.claude_code_audit_logs`
GROUP BY 1, 2, 3, 4;
