-- claude_code_projects: Maps GCP projects used for Claude Code to users.
--
-- project_type determines cost attribution method:
--   'single_user' -> all Vertex AI costs attributed directly to user_email
--   'shared'      -> costs attributed proportionally via audit logs
--
-- Billing account info is derived from billing_data at query time,
-- so this table only stores what can't be looked up elsewhere.
--
-- Usage:
--   bq query --nouse_legacy_sql --project_id=gcid-data-core < vertex-ai/create-project-mapping.sql

DROP TABLE IF EXISTS
  `gcid-data-core.custom_sada_billing_views.claude_code_projects`;

CREATE TABLE
  `gcid-data-core.custom_sada_billing_views.claude_code_projects`
(
  project_id STRING NOT NULL,       -- GCP project ID (e.g., 'coding-dpark', 'gcid-data-core')
  project_type STRING NOT NULL,     -- 'single_user' or 'shared'
  user_email STRING                 -- For single_user projects; NULL for shared
);

INSERT INTO `gcid-data-core.custom_sada_billing_views.claude_code_projects`
  (project_id, project_type, user_email)
VALUES
  ('coding-dpark',    'single_user', 'dpark@broadinstitute.org'),
  ('coding-carze',    'single_user', 'carze@broadinstitute.org'),
  ('coding-lluebber', 'single_user', 'lluebber@broadinstitute.org'),
  ('coding-pvarilly', 'single_user', 'pvarilly@broadinstitute.org'),
  ('gcid-data-core',  'shared',      NULL),
  ('sabeti-ai',       'shared',      NULL);
