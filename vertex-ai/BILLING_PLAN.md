# Consolidated Per-User Claude Code Billing Dashboard

## Context

Two usage patterns for tracking Claude Code (Vertex AI) costs:

1. **Single-user projects**: Each user has a dedicated project (`coding-dpark`, `coding-carze`, `coding-lluebber`, `coding-pvarilly`). User = project, so billing data directly maps to users. No audit logs needed.

2. **Shared projects**: Multiple users share a project (currently `gcid-data-core`, extensible to future projects). Audit logs provide per-user attribution via proportional cost splitting.

**Goal**: Create a unified Looker dashboard showing per-user Claude Code costs across both patterns, with per-model granularity, supporting multiple billing accounts and funding sources.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    DATA SOURCES                                  │
├──────────────────────────┬──────────────────────────────────────┤
│  SADA Billing Export     │  Audit Logs (per shared project)     │
│  (all 534 billing accts) │  (only needed for shared projects)   │
│                          │                                      │
│  sku_description has     │  Has user_email + model_name         │
│  per-model detail        │  per API call                        │
│                          │                                      │
│                          │  gcid-data-core ──sink──┐            │
│                          │  future-proj-X  ──sink──┤            │
│                          │  future-proj-Y  ──sink──┘            │
└────────────┬─────────────┴──────────────┬───────────────────────┘
             │                            │
             ▼                            ▼
┌────────────────────────┐  ┌─────────────────────────────────────┐
│ billing_data           │  │ billing_export.cloudaudit_*          │
│ (materialized, daily)  │  │ (single central dataset, wildcard)  │
│ 90-day rolling window  │  │ resource.labels.project_id          │
│ partitioned by date    │  │ distinguishes source project        │
└────────────┬───────────┘  └──────────────┬──────────────────────┘
             │                             │
             │                             ▼
             │               ┌──────────────────────────────┐
             │               │ claude_code_audit_logs        │
             │               │   (model_name + model_family) │
             │               │ claude_code_daily_usage        │
             │               │   (request counts per          │
             │               │    user/day/model_family)      │
             │               └──────────────┬───────────────┘
             │                              │
             ▼                              ▼
        ┌────────────────────────────────────────────┐
        │        claude_code_projects                 │
        │        (mapping table)                      │
        │  ┌──────────────┬─────────────────────┐    │
        │  │ single_user  │ shared              │    │
        │  │ coding-dpark │ gcid-data-core      │    │
        │  │ coding-carze │ (future-proj-X)     │    │
        │  │ ...          │ (future-proj-Y)     │    │
        │  └──────────────┴─────────────────────┘    │
        └────────────────────┬───────────────────────┘
                             │
                             ▼
        ┌────────────────────────────────────────────┐
        │      claude_code_user_costs                 │
        │                                             │
        │  single_user → direct attribution           │
        │    (user = project owner, full cost)         │
        │                                             │
        │  shared → proportional attribution          │
        │    (cost × user_requests / total_requests)  │
        │    joined at (project, date, model_family)  │
        └────────────────────┬───────────────────────┘
                             │
                             ▼
                    Looker Studio Dashboard
                    Filters: user, project, model,
                    billing account, funding source, date
```

## Existing Infrastructure

**Already in place:**
- SADA billing export → `custom_sada_billing_views.billing_data` (materialized, partitioned, 90-day rolling window, refreshed daily at 0900 UTC)
- Audit logs → `billing_export.cloudaudit_googleapis_com_data_access_*` (gcid-data-core only, currently)
- Older views → `billing_export.claude_usage_detailed`, `claude_cost_per_user` (will be superseded)

## Key Design Decisions

### Per-model attribution for shared projects

Billing data and user identity live in different sources:

| Source | Has cost/model? | Has user? |
|--------|----------------|-----------|
| `billing_data` (SADA) | Yes — per-SKU costs | No — project-level only |
| Audit logs | Model name per request | Yes — `principalEmail` |

We join at **(project, date, model_family)** so users of expensive models are attributed correctly. A `model_family` key (e.g., `sonnet-4`, `opus-4`) normalizes model names from both sources via CASE expressions.

### Model family normalization

Both audit logs and billing SKUs are normalized to a common `model_family` key:

**Audit log side** (from `protopayload_auditlog.resourceName`):
```
claude-3-5-sonnet%  → sonnet-3.5       claude-sonnet-5%  → sonnet-5
claude-sonnet-4%    → sonnet-4         claude-opus-5%    → opus-5
claude-3-5-haiku%   → haiku-3.5        claude-haiku-5%   → haiku-5
claude-haiku-4%     → haiku-4
claude-3-opus%      → opus-3           ELSE → raw model_name (graceful fallback)
claude-opus-4%      → opus-4
```

**Billing SKU side** (from `sku_description`):
```
%3.5 sonnet%  → sonnet-3.5            %sonnet 5%  → sonnet-5
%sonnet 4%    → sonnet-4              %opus 5%    → opus-5
%3.5 haiku%   → haiku-3.5             %haiku 5%   → haiku-5
%haiku 4%     → haiku-4
%opus 3%      → opus-3                ELSE → LOWER(sku_description) (graceful fallback)
%opus 4%      → opus-4
```

**Maintenance**: New model versions within a family (e.g., `claude-sonnet-4-20260601`) need zero updates — the wildcards catch them. A new model family (e.g., Sonnet 6) requires adding one WHEN clause to each of two SQL files. Until updated, unrecognized models fall through to the ELSE with the raw name visible in the dashboard.

**ELSE behavior for shared projects**: Raw names from the two sides won't match each other, so costs go to `user_email = 'unattributed'` with the raw SKU visible. This prevents false cross-attribution between different unknown models.

### Audit log sinks — no user permissions needed

Log sinks use GCP-managed service accounts. Users in shared projects need zero permissions on gcid-data-core. Only the admin who runs the setup script needs access.

### Unattributed costs

LEFT JOIN from billing to audit data ensures dollar conservation. Costs without matching audit logs go to `user_email = 'unattributed'` so nothing silently disappears.

## Implementation

### Step 1: Project mapping table

**File: `vertex-ai/create-project-mapping.sql`**

```sql
CREATE TABLE IF NOT EXISTS `gcid-data-core.custom_sada_billing_views.claude_code_projects` (
  project_id STRING NOT NULL,
  project_type STRING NOT NULL,     -- 'single_user' or 'shared'
  user_email STRING,                -- For single_user projects; NULL for shared
  billing_account_id STRING,
  funding_source STRING,
  enabled_date DATE
);

INSERT INTO `gcid-data-core.custom_sada_billing_views.claude_code_projects`
  (project_id, project_type, user_email, billing_account_id, funding_source, enabled_date)
VALUES
  ('coding-dpark',    'single_user', 'dpark@broadinstitute.org',    '011F41-0941F7-749F4B', 'GCID 5008388', NULL),
  ('coding-carze',    'single_user', 'carze@broadinstitute.org',    '011F41-0941F7-749F4B', 'GCID 5008388', NULL),
  ('coding-lluebber', 'single_user', 'lluebber@broadinstitute.org', '011F41-0941F7-749F4B', 'GCID 5008388', NULL),
  ('coding-pvarilly', 'single_user', 'pvarilly@broadinstitute.org', '0193CA-41033B-3FF267', 'GCID 5008157', NULL),
  ('gcid-data-core',  'shared',      NULL,                          '00864F-515C74-8B1641', 'GCID 5008152', NULL);
```

### Step 2: Audit log views (for shared projects)

**File: `vertex-ai/create-audit-views.sql`**

Two views:

1. **`claude_code_audit_logs`** — CTE-based view extracting `user_email`, `project_id`, `model_name`, and derived `model_family` from audit log wildcard tables. Filters to `aiplatform.googleapis.com` + `anthropic` resources.

2. **`claude_code_daily_usage`** — Aggregation: `GROUP BY (usage_date, project_id, user_email, model_family)` producing `request_count`.

### Step 3: Unified per-user cost view

**File: `vertex-ai/create-user-costs-view.sql`**

Main view `claude_code_user_costs` with CTEs:

- **`billing_with_model`** — Adds `model_family` to `billing_data` rows (Vertex AI only) via CASE on `sku_description`
- **`single_user_costs`** — Direct attribution: JOIN billing to mapping table, `cost = net_cost`
- **`shared_model_totals`** — Total request counts per `(project, date, model_family)`
- **`shared_user_costs`** — LEFT JOIN billing to audit data on `(project, date, model_family)`. Proportional: `cost = net_cost * SAFE_DIVIDE(user_requests, total_requests)`. Unmatched → `'unattributed'`
- **UNION ALL** both branches

Output columns: `usage_date, user_email, project_id, funding_source, billing_account_id, sku_description, model_family, cost, usage_amount, usage_unit, attribution_method`

### Step 4: Audit sink setup script

**File: `vertex-ai/setup-audit-sink.sh`**

Script taking `<project-id>` as argument:
1. Verify project exists
2. Enable Data Access audit logs for `aiplatform.googleapis.com`
3. Create/update log sink routing to `gcid-data-core.billing_export`
4. Grant sink's service account `bigquery.dataEditor`
5. Print next steps (mapping table INSERT)

### Step 5: Looker Studio Dashboard

Data source: `claude_code_user_costs`

**Filters:** Date range, User, Project, Model, Funding Source, Billing Account

**Charts:**
| Chart | Type | Dimension | Metric |
|-------|------|-----------|--------|
| Total Cost | Scorecard | - | SUM(cost) |
| Cost by User | Bar chart | user_email | SUM(cost) |
| Daily Trend | Stacked bar | usage_date | SUM(cost), breakdown by user_email |
| Cost by Model | Bar chart | model_family | SUM(cost) |
| Cost by Funding Source | Pie chart | funding_source | SUM(cost) |
| User Details | Table | user_email, model_family, project_id, sku_description | SUM(cost) |

## Execution Order

1. `create-project-mapping.sql` (no dependencies)
2. `setup-audit-sink.sh gcid-data-core` (if not already configured)
3. `create-audit-views.sql` (depends on audit logs in billing_export)
4. `create-user-costs-view.sql` (depends on mapping table + audit views)

Each SQL file: `bq query --nouse_legacy_sql --project_id=gcid-data-core < vertex-ai/FILE.sql`

## Adding New Users/Projects

### New single-user project

One INSERT, no audit sink needed:
```sql
INSERT INTO `gcid-data-core.custom_sada_billing_views.claude_code_projects`
  (project_id, project_type, user_email, billing_account_id, funding_source, enabled_date)
VALUES ('coding-newuser', 'single_user', 'newuser@broadinstitute.org', 'BILLING_ACCT_ID', 'Source Name', CURRENT_DATE());
```

### New shared project

Two steps:
1. Run `./vertex-ai/setup-audit-sink.sh <project-id>` (configures audit log routing)
2. Insert mapping row:
```sql
INSERT INTO `gcid-data-core.custom_sada_billing_views.claude_code_projects`
  (project_id, project_type, user_email, billing_account_id, funding_source, enabled_date)
VALUES ('new-shared-project', 'shared', NULL, 'BILLING_ACCT_ID', 'Source Name', CURRENT_DATE());
```

No view changes needed — views handle multiple projects via JOINs. Billing data appears automatically via SADA export. Audit logs route via the sink to the central wildcard table.

## Verification

After creating all objects:

**1. Check model_family distribution in audit logs:**
```sql
SELECT model_family, COUNT(*) AS requests, COUNT(DISTINCT user_email) AS users
FROM `gcid-data-core.custom_sada_billing_views.claude_code_daily_usage`
GROUP BY 1 ORDER BY 2 DESC;
```

**2. Verify dollar conservation for shared projects:**
```sql
WITH attributed AS (
  SELECT project_id, usage_date, SUM(cost) AS attributed_cost
  FROM `gcid-data-core.custom_sada_billing_views.claude_code_user_costs`
  WHERE project_id IN (SELECT project_id FROM `gcid-data-core.custom_sada_billing_views.claude_code_projects` WHERE project_type = 'shared')
  GROUP BY 1, 2
),
raw AS (
  SELECT project_id, usage_date, SUM(net_cost) AS billing_cost
  FROM `gcid-data-core.custom_sada_billing_views.billing_data`
  WHERE service_category = 'Vertex AI'
    AND project_id IN (SELECT project_id FROM `gcid-data-core.custom_sada_billing_views.claude_code_projects` WHERE project_type = 'shared')
  GROUP BY 1, 2
)
SELECT
  ROUND(SUM(a.attributed_cost), 2) AS total_attributed,
  ROUND(SUM(r.billing_cost), 2) AS total_billing,
  ROUND(ABS(SUM(a.attributed_cost) - SUM(r.billing_cost)), 4) AS discrepancy
FROM attributed a
FULL OUTER JOIN raw r USING (project_id, usage_date);
```

**3. Per-user cost summary:**
```sql
SELECT
  user_email, model_family, funding_source, attribution_method,
  ROUND(SUM(cost), 2) AS total_cost,
  COUNT(DISTINCT usage_date) AS active_days
FROM `gcid-data-core.custom_sada_billing_views.claude_code_user_costs`
WHERE usage_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
GROUP BY 1, 2, 3, 4
ORDER BY total_cost DESC;
```

## Files Summary

| File | Purpose |
|------|---------|
| `vertex-ai/create-project-mapping.sql` | DDL + initial data for project mapping table |
| `vertex-ai/create-audit-views.sql` | Audit log views with model_family extraction |
| `vertex-ai/create-user-costs-view.sql` | Main unified per-user cost view |
| `vertex-ai/setup-audit-sink.sh` | Script to configure audit log sink for shared projects |
