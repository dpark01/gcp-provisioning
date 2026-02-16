-- billing_alert_config: stores alert definitions
CREATE TABLE IF NOT EXISTS `gcid-data-core.custom_sada_billing_views.billing_alert_config` (
  alert_id STRING NOT NULL,
  alert_name STRING NOT NULL,
  enabled BOOL NOT NULL,

  -- Scope filters (NULL = wildcard, matches all)
  scope_billing_account_id STRING,
  scope_project_id STRING,
  scope_project_category STRING,
  scope_team STRING,
  scope_service_category STRING,

  -- Rolling window size
  rolling_window_days INT64 NOT NULL,

  -- Alert type and thresholds
  alert_type STRING NOT NULL,  -- 'fixed', 'stddev', or 'percent'
  threshold_amount FLOAT64,     -- For 'fixed': dollar amount
  stddev_multiplier FLOAT64,    -- For 'stddev': e.g. 2.0
  pct_of_average FLOAT64,       -- For 'percent': e.g. 150.0 = alert if >150% of avg
  min_weekly_datapoints INT64 NOT NULL,

  -- Notification settings
  cooldown_days INT64 NOT NULL,
  notify_emails STRING NOT NULL
);

-- billing_alerts_log: stores fired alerts
-- Partitioned by fired_date with 365-day expiration
CREATE TABLE IF NOT EXISTS `gcid-data-core.custom_sada_billing_views.billing_alerts_log` (
  alert_log_id STRING NOT NULL,
  alert_id STRING NOT NULL,
  alert_name STRING NOT NULL,
  alert_type STRING NOT NULL,
  fired_at TIMESTAMP NOT NULL,
  scope_description STRING,
  rolling_7d_cost FLOAT64,
  threshold_value FLOAT64,
  weekly_mean FLOAT64,
  weekly_stddev FLOAT64,
  num_weekly_datapoints INT64,
  notify_emails STRING,
  notification_sent BOOL NOT NULL,
  fired_date DATE NOT NULL
)
PARTITION BY fired_date
OPTIONS (
  partition_expiration_days = 365
);
