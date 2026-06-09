# Claude Fable 5 Rollout

Rollout date: 2026-06-09

## Overview

This document tracks the rollout of `claude-fable-5` to all GCP projects with Vertex AI enabled, following the process from `NEW_MODEL_RUNBOOK.md`.

## Step 1: Reporting (BigQuery views) ✅ COMPLETE

**Commit**: b33e83c "Add Claude Fable 5 support to Vertex AI billing tracking"

Modified files:
- `vertex-ai/create-audit-views.sql` — Added `claude-fable-5%` → `fable-5`
- `vertex-ai/create-user-costs-view.sql` — Added `%fable 5%` / `%fable-5%` → `fable-5`
- `billing-reporting/scheduled-billing-refresh.sql` — Added `%fable%` to service_category
- `billing-reporting/create-summary-view.sql` — Added `%fable%` to service_category
- `billing-reporting/refresh-materialized-billing.sh` — Added `%fable%` to service_category
- `vertex-ai/BILLING_PLAN.md` — Updated model family reference blocks

**Deployment**: ✅ DEPLOYED (2026-06-09)

```bash
bq query --nouse_legacy_sql --project_id=gcid-data-core < vertex-ai/create-audit-views.sql
bq query --nouse_legacy_sql --project_id=gcid-data-core < vertex-ai/create-user-costs-view.sql
```

Both views successfully replaced in `gcid-data-core.custom_sada_billing_views`.

## Step 2: Enablement (Model Garden)

**Source of truth**: Query the live BigQuery table for current projects:

```bash
bq query --nouse_legacy_sql --project_id=gcid-data-core \
'SELECT project_id, project_type, user_email
 FROM `gcid-data-core.custom_sada_billing_views.claude_code_projects`
 ORDER BY project_type, project_id'
```

**As of 2026-06-09** (from `create-project-mapping.sql`), the list is:

### Single-user projects (5)

| Project ID | User | Model Garden URL |
|------------|------|------------------|
| coding-carze | carze@broadinstitute.org | https://console.cloud.google.com/vertex-ai/publishers/anthropic/model-garden/claude-fable-5?project=coding-carze |
| coding-dpark | dpark@broadinstitute.org | https://console.cloud.google.com/vertex-ai/publishers/anthropic/model-garden/claude-fable-5?project=coding-dpark |
| coding-lluebber | lluebber@broadinstitute.org | https://console.cloud.google.com/vertex-ai/publishers/anthropic/model-garden/claude-fable-5?project=coding-lluebber |
| coding-pvarilly | pvarilly@broadinstitute.org | https://console.cloud.google.com/vertex-ai/publishers/anthropic/model-garden/claude-fable-5?project=coding-pvarilly |
| sabeti-librechat | sabeti-librechat@broadinstitute.org | https://console.cloud.google.com/vertex-ai/publishers/anthropic/model-garden/claude-fable-5?project=sabeti-librechat |

### Shared projects (6)

| Project ID | Model Garden URL |
|------------|------------------|
| cigass-ai | https://console.cloud.google.com/vertex-ai/publishers/anthropic/model-garden/claude-fable-5?project=cigass-ai |
| gcid-data-core | https://console.cloud.google.com/vertex-ai/publishers/anthropic/model-garden/claude-fable-5?project=gcid-data-core |
| sabeti-ai | https://console.cloud.google.com/vertex-ai/publishers/anthropic/model-garden/claude-fable-5?project=sabeti-ai |
| sabeti-encode | https://console.cloud.google.com/vertex-ai/publishers/anthropic/model-garden/claude-fable-5?project=sabeti-encode |
| sabeti-mgmt | https://console.cloud.google.com/vertex-ai/publishers/anthropic/model-garden/claude-fable-5?project=sabeti-mgmt |
| viral-seq-ai | https://console.cloud.google.com/vertex-ai/publishers/anthropic/model-garden/claude-fable-5?project=viral-seq-ai |

**Manual action**: Visit each URL and click **Enable** → accept terms.

## Step 3: IT Ticket (org policy)

**Action**: File a ticket to IT to add the following to the org policy constraint `constraints/vertexai.allowedPartnerModelFeatures`:

```
publishers/anthropic/models/claude-fable-5:web_search
```

**Template**:

> **Subject**: Add Claude Fable 5 to Vertex AI partner-feature allowlist
>
> **Request**: Please add the following value to the `is:` allowlist on the org policy constraint `constraints/vertexai.allowedPartnerModelFeatures` (set at the folder/org level that our GCP projects inherit from). **Preserve all existing entries** — this is an allowlist, not a replacement.
>
> - `publishers/anthropic/models/claude-fable-5:web_search`
>
> **Why**: We've enabled Claude Fable 5 in Vertex AI Model Garden across our projects. Model Garden enablement does not add the model to this partner-feature allowlist, so the Vertex `web_search` feature (used by Claude Code's WebSearch tool) is blocked for the new model until this entry is added. Existing models (Opus 4.8, 4.7, 4.6, Sonnet 4.6) are already on the allowlist.
>
> **Scope**: Applies to all projects inheriting the constraint.

## Step 4: Verify (6-24h after enablement)

**Audit log normalization**:
```sql
SELECT model_name, model_family, COUNT(*) AS requests, COUNT(DISTINCT user_email) AS users
FROM `gcid-data-core.custom_sada_billing_views.claude_code_audit_logs`
WHERE model_name LIKE 'claude-fable-5%'
  AND usage_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
GROUP BY 1, 2 ORDER BY 3 DESC;
-- Expect model_family = 'fable-5', NOT a raw model name.
```

**Billing/cost attribution**:
```sql
SELECT user_email, project_id, model_family,
       ROUND(SUM(cost), 2) AS total_cost, COUNT(DISTINCT usage_date) AS days_active
FROM `gcid-data-core.custom_sada_billing_views.claude_code_user_costs`
WHERE model_family = 'fable-5'
  AND usage_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
GROUP BY 1, 2, 3 ORDER BY 4 DESC;
```

**WebSearch** (after IT closes the Step 3 ticket): Test in Claude Code with the new model.

**Looker**: Confirm `fable-5` appears in the model filter dropdown.

## Checklist

- [x] Step 1: Add `model_family` clause to both SQL files
- [x] Step 1: Update `BILLING_PLAN.md` pattern blocks
- [x] Step 1: Add `%fable%` to general billing pipeline service_category
- [x] Step 1: Commit changes
- [x] Step 1: Deploy views to `gcid-data-core`
- [ ] Step 2: Enable model in Model Garden for all 11 projects
- [ ] Step 3: File IT ticket for org policy allowlist
- [ ] Step 4: Verify audit/cost normalization, WebSearch, Looker
