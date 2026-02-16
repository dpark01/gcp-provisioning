# Billing Cost Alerting System - Implementation Plan

## Checklist

- [x] 0. Create documentation files
- [x] 1. Create `billing_alert_config` table DDL
- [x] 2. Create `billing_alerts_log` table DDL
- [x] 3. Write alert evaluation SQL (BQ Scheduled Query #2)
- [x] 4. Deploy Cloud Function (Python, 2nd gen)
- [x] 5. Deploy Cloud Scheduler job (in deploy.sh)
- [x] 6. Seed initial alert configs
- [x] 7. Write deployment script

## Deployment Steps

1. Review all files in `billing-alerts/`
2. Run `deploy.sh` (or execute steps manually)
3. Verify tables created: `SELECT * FROM billing_alert_config`
4. Dry run: execute `evaluate-alerts.sql` manually in BQ console
5. Test Cloud Function: insert test row in `billing_alerts_log`, trigger function
6. Wait for next scheduled run, confirm end-to-end flow
7. Delete this file after verification complete
