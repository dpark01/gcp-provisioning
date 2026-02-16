-- Seed initial alert configurations
-- Run after creating the billing_alert_config table.

-- Clear existing seed data (idempotent)
DELETE FROM `gcid-data-core.custom_sada_billing_views.billing_alert_config`
WHERE alert_id IN (
  'gcid-data-core-fixed',
  'broad-hvp-dasc-fixed',
  'gcid-viral-seq-fixed',
  'sabeti-ai-fixed',
  'dsi-resources-fixed',
  'gcid-data-core-stddev',
  'broad-hvp-dasc-stddev',
  'gcid-viral-seq-stddev',
  'sabeti-ai-stddev',
  'dsi-resources-stddev',
  'vertex-ai-weekly-500'
);

INSERT INTO `gcid-data-core.custom_sada_billing_views.billing_alert_config`
  (alert_id, alert_name, enabled,
   scope_billing_account_id, scope_project_id, scope_project_category,
   scope_team, scope_service_category,
   rolling_window_days, alert_type, threshold_amount, stddev_multiplier,
   pct_of_average, min_weekly_datapoints, cooldown_days, notify_emails)
VALUES
  -- Fixed threshold alerts per billing account (7-day spend)
  ('gcid-data-core-fixed',
   'gcid-data-core weekly spend > $2,000', TRUE,
   '00864F-515C74-8B1641', NULL, NULL, NULL, NULL,
   7, 'fixed', 2000.0, NULL, NULL, 4, 7,
   'dpark@broadinstitute.org'),

  ('broad-hvp-dasc-fixed',
   'broad-hvp-dasc weekly spend > $2,000', TRUE,
   '011F41-0941F7-749F4B', NULL, NULL, NULL, NULL,
   7, 'fixed', 2000.0, NULL, NULL, 4, 7,
   'dpark@broadinstitute.org'),

  ('gcid-viral-seq-fixed',
   'gcid-viral-seq weekly spend > $2,000', TRUE,
   '0193CA-41033B-3FF267', NULL, NULL, NULL, NULL,
   7, 'fixed', 2000.0, NULL, NULL, 4, 7,
   'dpark@broadinstitute.org'),

  ('sabeti-ai-fixed',
   'sabeti-ai weekly spend > $2,000', TRUE,
   '01EABF-8D854B-B4B3D0', NULL, NULL, NULL, NULL,
   7, 'fixed', 2000.0, NULL, NULL, 4, 7,
   'dpark@broadinstitute.org'),

  ('dsi-resources-fixed',
   'dsi-resources weekly spend > $2,000', TRUE,
   '013A53-04CB08-63E4C8', NULL, NULL, NULL, NULL,
   7, 'fixed', 2000.0, NULL, NULL, 4, 7,
   'dpark@broadinstitute.org'),

  -- Statistical deviation alerts per billing account (2 stddev above mean)
  ('gcid-data-core-stddev',
   'gcid-data-core weekly spend 2σ above average', TRUE,
   '00864F-515C74-8B1641', NULL, NULL, NULL, NULL,
   7, 'stddev', NULL, 2.0, NULL, 4, 7,
   'dpark@broadinstitute.org'),

  ('broad-hvp-dasc-stddev',
   'broad-hvp-dasc weekly spend 2σ above average', TRUE,
   '011F41-0941F7-749F4B', NULL, NULL, NULL, NULL,
   7, 'stddev', NULL, 2.0, NULL, 4, 7,
   'dpark@broadinstitute.org'),

  ('gcid-viral-seq-stddev',
   'gcid-viral-seq weekly spend 2σ above average', TRUE,
   '0193CA-41033B-3FF267', NULL, NULL, NULL, NULL,
   7, 'stddev', NULL, 2.0, NULL, 4, 7,
   'dpark@broadinstitute.org'),

  ('sabeti-ai-stddev',
   'sabeti-ai weekly spend 2σ above average', TRUE,
   '01EABF-8D854B-B4B3D0', NULL, NULL, NULL, NULL,
   7, 'stddev', NULL, 2.0, NULL, 4, 7,
   'dpark@broadinstitute.org'),

  ('dsi-resources-stddev',
   'dsi-resources weekly spend 2σ above average', TRUE,
   '013A53-04CB08-63E4C8', NULL, NULL, NULL, NULL,
   7, 'stddev', NULL, 2.0, NULL, 4, 7,
   'dpark@broadinstitute.org'),

  -- Vertex AI service category alert across all accounts
  ('vertex-ai-weekly-500',
   'Vertex AI weekly spend > $500 (all accounts)', TRUE,
   NULL, NULL, NULL, NULL, 'Vertex AI',
   7, 'fixed', 500.0, NULL, NULL, 4, 7,
   'dpark@broadinstitute.org');
