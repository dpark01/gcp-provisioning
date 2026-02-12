-- claude_code_projects: Maps GCP projects used for Claude Code to users and funding sources.
--
-- project_type determines cost attribution method:
--   'single_user' -> all Vertex AI costs attributed directly to user_email
--   'shared'      -> costs attributed proportionally via audit logs
--
-- Usage:
--   bq query --nouse_legacy_sql --project_id=gcid-data-core < vertex-ai/create-project-mapping.sql

CREATE TABLE IF NOT EXISTS
  `gcid-data-core.custom_sada_billing_views.claude_code_projects`
(
  project_id STRING NOT NULL,       -- GCP project ID (e.g., 'coding-dpark', 'gcid-data-core')
  project_type STRING NOT NULL,     -- 'single_user' or 'shared'
  user_email STRING,                -- For single_user projects; NULL for shared
  billing_account_id STRING,        -- Billing account that pays for this project
  funding_source STRING,            -- Human-readable funding source label
  enabled_date DATE                 -- When Claude Code usage started (informational)
);

-- Initial data load
-- Billing account IDs verified from billing_data:
--   011F41-0941F7-749F4B = Broad Institute - 5008388 (SADA)
--   0193CA-41033B-3FF267 = Broad Institute - 5008157
--   00864F-515C74-8B1641 = Broad Institute - 5008152
--   01EABF-8D854B-B4B3D0 = Broad Institute - 6005589 (SADA)
INSERT INTO `gcid-data-core.custom_sada_billing_views.claude_code_projects`
  (project_id, project_type, user_email, billing_account_id, funding_source, enabled_date)
VALUES
  ('coding-dpark',    'single_user', 'dpark@broadinstitute.org',    '011F41-0941F7-749F4B', 'GCID 5008388', NULL),
  ('coding-carze',    'single_user', 'carze@broadinstitute.org',    '011F41-0941F7-749F4B', 'GCID 5008388', NULL),
  ('coding-lluebber', 'single_user', 'lluebber@broadinstitute.org', '011F41-0941F7-749F4B', 'GCID 5008388', NULL),
  ('coding-pvarilly', 'single_user', 'pvarilly@broadinstitute.org', '0193CA-41033B-3FF267', 'GCID 5008157', NULL),
  ('gcid-data-core',  'shared',      NULL,                          '00864F-515C74-8B1641', 'GCID 5008152', NULL),
  ('sabeti-ai',       'shared',      NULL,                          '01EABF-8D854B-B4B3D0', 'Sabeti 6005589', NULL);
