-- Alert Evaluation Scheduled Query
-- Runs daily at 0930 UTC, after billing_data refresh at 0900 UTC.
-- Evaluates all enabled alerts and INSERTs fired alerts into billing_alerts_log.
--
-- Data freshness: excludes most recent 1 day (SADA export lag).
-- A 7-day window evaluated on Feb 16 covers Feb 8-14.

DECLARE eval_date DATE DEFAULT CURRENT_DATE() - 1;
DECLARE lookback_start DATE DEFAULT eval_date - 60;

-- Step 1: Compute rolling N-day cost per alert config per scope slice
-- Step 2: Compute historical weekly stats for stddev/percent alerts
-- Step 3: Check cooldown and fire alerts

INSERT INTO `gcid-data-core.custom_sada_billing_views.billing_alerts_log`
  (alert_log_id, alert_id, alert_name, alert_type, fired_at,
   scope_description, rolling_7d_cost, threshold_value,
   weekly_mean, weekly_stddev, num_weekly_datapoints,
   notify_emails, notification_sent, fired_date)

WITH

-- Active alert configs
active_alerts AS (
  SELECT *
  FROM `gcid-data-core.custom_sada_billing_views.billing_alert_config`
  WHERE enabled = TRUE
),

-- Recent billing data within the full lookback window (60 days + rolling window)
billing_window AS (
  SELECT
    billing_account_id,
    project_id,
    project_category,
    team,
    service_category,
    usage_date,
    net_cost
  FROM `gcid-data-core.custom_sada_billing_views.billing_data`
  WHERE usage_date BETWEEN lookback_start AND eval_date
),

-- Cross join alerts with matching billing data (scope filtering)
alert_billing AS (
  SELECT
    a.alert_id,
    a.alert_name,
    a.alert_type,
    a.rolling_window_days,
    a.threshold_amount,
    a.stddev_multiplier,
    a.pct_of_average,
    a.min_weekly_datapoints,
    a.cooldown_days,
    a.notify_emails,
    -- Build scope description from non-NULL scope columns
    CONCAT_WS(', ',
      IF(a.scope_billing_account_id IS NOT NULL,
         CONCAT('billing_account=', a.scope_billing_account_id), NULL),
      IF(a.scope_project_id IS NOT NULL,
         CONCAT('project=', a.scope_project_id), NULL),
      IF(a.scope_project_category IS NOT NULL,
         CONCAT('category=', a.scope_project_category), NULL),
      IF(a.scope_team IS NOT NULL,
         CONCAT('team=', a.scope_team), NULL),
      IF(a.scope_service_category IS NOT NULL,
         CONCAT('service=', a.scope_service_category), NULL)
    ) AS scope_description,
    b.usage_date,
    b.net_cost
  FROM active_alerts a
  CROSS JOIN billing_window b
  WHERE
    (a.scope_billing_account_id IS NULL OR b.billing_account_id = a.scope_billing_account_id)
    AND (a.scope_project_id IS NULL OR b.project_id = a.scope_project_id)
    AND (a.scope_project_category IS NULL OR b.project_category = a.scope_project_category)
    AND (a.scope_team IS NULL OR b.team = a.scope_team)
    AND (a.scope_service_category IS NULL OR b.service_category = a.scope_service_category)
),

-- Rolling N-day cost per alert (current window)
rolling_cost AS (
  SELECT
    alert_id,
    alert_name,
    alert_type,
    rolling_window_days,
    threshold_amount,
    stddev_multiplier,
    pct_of_average,
    min_weekly_datapoints,
    cooldown_days,
    notify_emails,
    scope_description,
    SUM(net_cost) AS rolling_nd_cost
  FROM alert_billing
  WHERE usage_date > eval_date - rolling_window_days
  GROUP BY
    alert_id, alert_name, alert_type, rolling_window_days,
    threshold_amount, stddev_multiplier, pct_of_average,
    min_weekly_datapoints, cooldown_days, notify_emails, scope_description
),

-- Historical N-day window costs for stddev/percent calculation
-- Partition the 60-day lookback into non-overlapping N-day windows
historical_windows AS (
  SELECT
    ab.alert_id,
    ab.rolling_window_days,
    -- Assign each day to a window index (0 = most recent, going back)
    CAST(FLOOR(DATE_DIFF(eval_date, ab.usage_date, DAY) / ab.rolling_window_days) AS INT64) AS window_idx,
    ab.net_cost
  FROM alert_billing ab
  WHERE ab.alert_type IN ('stddev', 'percent')
    -- Exclude the current rolling window (window_idx = 0)
    AND ab.usage_date <= eval_date - ab.rolling_window_days
),

historical_window_totals AS (
  SELECT
    alert_id,
    rolling_window_days,
    window_idx,
    SUM(net_cost) AS window_cost
  FROM historical_windows
  GROUP BY alert_id, rolling_window_days, window_idx
),

historical_stats AS (
  SELECT
    alert_id,
    AVG(window_cost) AS weekly_mean,
    STDDEV_POP(window_cost) AS weekly_stddev,
    COUNT(*) AS num_datapoints
  FROM historical_window_totals
  GROUP BY alert_id
),

-- Last fired timestamp per alert for cooldown check
last_fired AS (
  SELECT
    alert_id,
    MAX(fired_at) AS last_fired_at
  FROM `gcid-data-core.custom_sada_billing_views.billing_alerts_log`
  GROUP BY alert_id
),

-- Combine rolling cost with historical stats and evaluate thresholds
evaluated AS (
  SELECT
    rc.alert_id,
    rc.alert_name,
    rc.alert_type,
    rc.rolling_nd_cost,
    rc.scope_description,
    rc.notify_emails,
    rc.cooldown_days,
    rc.threshold_amount,
    rc.min_weekly_datapoints,
    hs.weekly_mean,
    hs.weekly_stddev,
    hs.num_datapoints,
    lf.last_fired_at,
    -- Compute effective threshold
    CASE
      WHEN rc.alert_type = 'fixed' THEN rc.threshold_amount
      WHEN rc.alert_type = 'stddev' THEN hs.weekly_mean + rc.stddev_multiplier * hs.weekly_stddev
      WHEN rc.alert_type = 'percent' THEN hs.weekly_mean * (rc.pct_of_average / 100.0)
    END AS effective_threshold,
    -- Check if alert should fire
    CASE
      -- Cooldown check
      WHEN lf.last_fired_at IS NOT NULL
        AND TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), lf.last_fired_at, DAY) < rc.cooldown_days
        THEN FALSE
      -- Fixed threshold
      WHEN rc.alert_type = 'fixed'
        AND rc.rolling_nd_cost > rc.threshold_amount
        THEN TRUE
      -- Stddev threshold (with minimum datapoints)
      WHEN rc.alert_type = 'stddev'
        AND hs.num_datapoints >= rc.min_weekly_datapoints
        AND rc.rolling_nd_cost > hs.weekly_mean + rc.stddev_multiplier * hs.weekly_stddev
        THEN TRUE
      -- Percent threshold (with minimum datapoints)
      WHEN rc.alert_type = 'percent'
        AND hs.num_datapoints >= rc.min_weekly_datapoints
        AND rc.rolling_nd_cost > hs.weekly_mean * (rc.pct_of_average / 100.0)
        THEN TRUE
      ELSE FALSE
    END AS should_fire
  FROM rolling_cost rc
  LEFT JOIN historical_stats hs ON rc.alert_id = hs.alert_id
  LEFT JOIN last_fired lf ON rc.alert_id = lf.alert_id
)

-- Final: insert fired alerts
SELECT
  GENERATE_UUID() AS alert_log_id,
  alert_id,
  alert_name,
  alert_type,
  CURRENT_TIMESTAMP() AS fired_at,
  COALESCE(scope_description, 'all') AS scope_description,
  rolling_nd_cost AS rolling_7d_cost,
  effective_threshold AS threshold_value,
  weekly_mean,
  weekly_stddev,
  CAST(num_datapoints AS INT64) AS num_weekly_datapoints,
  notify_emails,
  FALSE AS notification_sent,
  CURRENT_DATE() AS fired_date
FROM evaluated
WHERE should_fire = TRUE;
