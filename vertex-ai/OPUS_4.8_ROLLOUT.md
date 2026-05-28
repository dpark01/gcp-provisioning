# Claude Opus 4.8 Rollout Checklist

**Date:** 2026-05-28  
**Model:** Claude Opus 4.8 (released today)

## Overview

Claude Opus 4.8 requires manual enablement on each GCP project that uses Vertex AI. This checklist tracks the rollout and ensures our billing/reporting infrastructure captures Opus 4.8 usage correctly.

---

## Part 1: Update Reporting Infrastructure

### BigQuery Views (Do this FIRST, before enabling the model)

- [x] Update `create-audit-views.sql` to recognize `claude-opus-4-8%` → `opus-4.8`
- [x] Update `create-user-costs-view.sql` to recognize SKUs with `%opus 4.8%` or `%opus 4 8%` → `opus-4.8`
- [x] Update `BILLING_PLAN.md` documentation with Opus 4.8 patterns
- [x] Create deployment script `deploy-opus-4.8-support.sh`
- [ ] **Run deployment script:**
  ```bash
  cd ~/dev/gcp-provisioning
  ./vertex-ai/deploy-opus-4.8-support.sh
  ```

**Why this order:** If you enable Opus 4.8 on projects before updating the views, usage will fall through to the ELSE clause and show up as raw model names instead of being normalized to `opus-4.8`. By updating views first, usage tracking is ready the moment you enable the model.

---

## Part 2: Enable Opus 4.8 on Vertex AI Projects

### Single-User Projects (5 projects)

Enable Opus 4.8 via Vertex AI Model Garden for each project:

- [ ] **coding-dpark** (dpark@broadinstitute.org)
  - Console: https://console.cloud.google.com/vertex-ai/publishers/anthropic/model-garden/claude-opus-4-8?project=coding-dpark
  - Click "Enable" → Accept terms → Wait for enablement

- [ ] **coding-carze** (carze@broadinstitute.org)
  - Console: https://console.cloud.google.com/vertex-ai/publishers/anthropic/model-garden/claude-opus-4-8?project=coding-carze

- [ ] **coding-lluebber** (lluebber@broadinstitute.org)
  - Console: https://console.cloud.google.com/vertex-ai/publishers/anthropic/model-garden/claude-opus-4-8?project=coding-lluebber

- [ ] **coding-pvarilly** (pvarilly@broadinstitute.org)
  - Console: https://console.cloud.google.com/vertex-ai/publishers/anthropic/model-garden/claude-opus-4-8?project=coding-pvarilly

- [ ] **sabeti-librechat** (LibreChat app)
  - Console: https://console.cloud.google.com/vertex-ai/publishers/anthropic/model-garden/claude-opus-4-8?project=sabeti-librechat

### Shared Projects (6 projects)

Enable Opus 4.8 via Vertex AI Model Garden for each project:

- [ ] **gcid-data-core** (primary shared project)
  - Console: https://console.cloud.google.com/vertex-ai/publishers/anthropic/model-garden/claude-opus-4-8?project=gcid-data-core

- [ ] **sabeti-ai**
  - Console: https://console.cloud.google.com/vertex-ai/publishers/anthropic/model-garden/claude-opus-4-8?project=sabeti-ai

- [ ] **sabeti-encode**
  - Console: https://console.cloud.google.com/vertex-ai/publishers/anthropic/model-garden/claude-opus-4-8?project=sabeti-encode

- [ ] **sabeti-mgmt**
  - Console: https://console.cloud.google.com/vertex-ai/publishers/anthropic/model-garden/claude-opus-4-8?project=sabeti-mgmt

- [ ] **viral-seq-ai**
  - Console: https://console.cloud.google.com/vertex-ai/publishers/anthropic/model-garden/claude-opus-4-8?project=viral-seq-ai

- [ ] **cigass-ai**
  - Console: https://console.cloud.google.com/vertex-ai/publishers/anthropic/model-garden/claude-opus-4-8?project=cigass-ai

---

## Part 3: Verification (After enabling on at least one project)

Wait 6-24 hours after someone uses Opus 4.8, then verify tracking:

### Check Audit Logs (Shared Projects)
```sql
-- Verify Opus 4.8 appears in audit logs with correct model_family
SELECT 
  model_name, 
  model_family, 
  COUNT(*) AS requests,
  COUNT(DISTINCT user_email) AS users
FROM `gcid-data-core.custom_sada_billing_views.claude_code_audit_logs`
WHERE model_name LIKE 'claude-opus-4-8%'
  AND usage_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
GROUP BY 1, 2
ORDER BY 3 DESC;
```

**Expected:** `model_family` should be `opus-4.8`, not the raw model name.

### Check Billing SKUs
```sql
-- Verify Opus 4.8 billing SKUs are being normalized correctly
SELECT 
  sku_description,
  model_family,
  SUM(net_cost) AS total_cost,
  COUNT(DISTINCT project_id) AS num_projects
FROM `gcid-data-core.custom_sada_billing_views.claude_code_user_costs`
WHERE sku_description LIKE '%Opus 4%8%'
  AND usage_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
GROUP BY 1, 2
ORDER BY 3 DESC;
```

**Expected:** `model_family` should be `opus-4.8`. If you see raw SKU descriptions in the model_family column, the view update didn't deploy correctly.

### Check User Costs
```sql
-- Verify per-user Opus 4.8 costs are being attributed
SELECT 
  user_email,
  project_id,
  model_family,
  ROUND(SUM(cost), 2) AS total_cost,
  COUNT(DISTINCT usage_date) AS days_active
FROM `gcid-data-core.custom_sada_billing_views.claude_code_user_costs`
WHERE model_family = 'opus-4.8'
  AND usage_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
GROUP BY 1, 2, 3
ORDER BY 4 DESC;
```

**Expected:** Costs attributed to actual users in single-user projects, proportionally split in shared projects.

### Looker Studio Dashboard
- Navigate to: [Claude Code Usage Dashboard](https://lookerstudio.google.com/reporting/your-dashboard-id)
- Verify `opus-4.8` appears in the model filter dropdown
- Verify costs are showing up for users who have used Opus 4.8

---

## Notes

- **Enablement is manual and per-project:** Google requires you to enable each model version individually in each project via the Cloud Console. There's no API or Terraform support for this.

- **Billing latency:** GCP billing exports have ~6 hour latency. Audit logs are near real-time (~5 minutes). You'll see audit log entries for Opus 4.8 usage almost immediately, but billing costs may take several hours to appear.

- **Model naming patterns:** Google uses inconsistent naming in billing SKUs (both `Opus 4.8` and `Opus 4 8` have been observed). Our SQL patterns handle both formats.

- **New snapshots:** When Anthropic releases a new snapshot within Opus 4.8 (e.g., `claude-opus-4-8-20260601`), the wildcard `%opus-4-8%` will automatically catch it. No SQL updates needed for same-version snapshots.

---

## Rollback

If you need to revert the BigQuery view changes:

```bash
cd ~/dev/gcp-provisioning
git log --oneline vertex-ai/create-audit-views.sql
git show <commit-before-opus-4.8>:vertex-ai/create-audit-views.sql | \
  bq query --nouse_legacy_sql --project_id=gcid-data-core

git show <commit-before-opus-4.8>:vertex-ai/create-user-costs-view.sql | \
  bq query --nouse_legacy_sql --project_id=gcid-data-core
```

Disabling Opus 4.8 on projects: Go to Vertex AI Model Garden in each project and click "Disable" on the Opus 4.8 model card. (Rarely needed since the model just becomes unavailable to users, it doesn't cause billing issues.)
