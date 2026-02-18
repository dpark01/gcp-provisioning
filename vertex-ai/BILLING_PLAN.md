# Consolidated Per-User Claude Code Billing Dashboard

## Context

Two usage patterns for tracking Claude Code (Vertex AI) costs:

1. **Single-user projects**: Each user has a dedicated project (`coding-dpark`, `coding-carze`, `coding-lluebber`, `coding-pvarilly`). User = project, so billing data directly maps to users. No audit logs needed.

2. **Shared projects**: Multiple users share a project (currently `gcid-data-core`, extensible to future projects). Audit logs provide per-user attribution via proportional cost splitting.

**Goal**: Create a unified Looker dashboard showing per-user Claude Code costs across both patterns, with per-model granularity, supporting multiple billing accounts.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                    BILLING DATA SOURCES                              │
├─────────────────────────────────────────────────────────────────────┤
│  Direct GCP Billing Exports (~6h latency, partitioned)              │
│                                                                     │
│  gcid-data-core.billing_export   (00864F-515C74-8B1641)            │
│  broad-hvp-dasc.billing_export   (011F41-0941F7-749F4B)            │
│  gcid-viral-seq.billing_export   (0193CA-41033B-3FF267)            │
│  sabeti-ai.billing_export        (01EABF-8D854B-B4B3D0)            │
│  dsi-resources.billing_export    (013A53-04CB08-63E4C8)            │
│                                                                     │
│  + SADA billing_data for historical dates before cutoff             │
└────────────────────────┬────────────────────────────────────────────┘
                         │
                         ▼
        ┌────────────────────────────────────────────┐
        │    claude_vertex_ai_billing                 │
        │    (UNION ALL view, Vertex AI only)         │
        │    Normalizes schema across exports         │
        │    Joins billing_account_names              │
        │    Historical cutoff: SADA before / direct  │
        │    exports on+after transition date         │
        └────────────────────┬───────────────────────┘
                             │
┌────────────────────────────┼────────────────────────────────────────┐
│  AUDIT LOG SOURCES         │  (only for shared projects)            │
│                            │                                        │
│  gcid-data-core ──sink──┐  │                                        │
│  sabeti-ai      ──sink──┤  │                                        │
│  future-proj    ──sink──┘  │                                        │
│       │                    │                                        │
│       ▼                    │                                        │
│  billing_export.           │                                        │
│    cloudaudit_*            │                                        │
│       │                    │                                        │
│       ▼                    │                                        │
│  claude_code_audit_logs    │                                        │
│  claude_code_daily_usage   │                                        │
└────────────┬───────────────┘                                        │
             │                                                        │
             ▼                                                        │
        ┌────────────────────────────────────────────┐                │
        │        claude_code_projects                 │                │
        │        (mapping table)                      │                │
        │  ┌──────────────┬─────────────────────┐    │                │
        │  │ single_user  │ shared              │    │                │
        │  │ coding-dpark │ gcid-data-core      │    │                │
        │  │ coding-carze │ sabeti-ai           │    │                │
        │  │ ...          │ (future-proj)       │    │                │
        │  └──────────────┴─────────────────────┘    │                │
        └────────────────────┬───────────────────────┘                │
                             │                                        │
                             ▼                                        │
        ┌────────────────────────────────────────────┐                │
        │      claude_code_user_costs                 │◄───────────────┘
        │                                             │
        │  Reads from claude_vertex_ai_billing        │
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
                    billing account, date
```

## Billing Accounts

| Cost Object | Billing Account ID | Export Project | Dataset | Status |
|---|---|---|---|---|
| 5008152 | `00864F-515C74-8B1641` | gcid-data-core | billing_export | Live |
| 5008388 | `011F41-0941F7-749F4B` | broad-hvp-dasc | billing_export | Live |
| 5008157 | `0193CA-41033B-3FF267` | gcid-viral-seq | billing_export | Live |
| 6005589 | `01EABF-8D854B-B4B3D0` | sabeti-ai | billing_export | Live (no usage — new account) |
| 6005319 | `013A53-04CB08-63E4C8` | dsi-resources | billing_export | Live |
| 4500115 | `01B753-07D3AF-8A7587` | sabeti-encode | billing_export | Export configured, pending backfill |

Export table naming convention: `gcp_billing_export_resource_v1_<ACCT_ID_WITH_UNDERSCORES>`

**Note on sabeti-encode**: The `sabeti-encode` project's Vertex AI charges are ML training
workloads (Colab Enterprise, A100 GPU training), not Claude model usage. The billing export
is set up for completeness, but `sabeti-encode` is not in the `claude_code_projects` mapping
table and does not appear in the Claude Code dashboard.

## Data Freshness

- **Direct billing exports**: ~2-4 hour latency in practice (partitioned, ~2 MB per query)
- **SADA billing_data**: ~36 hour latency (used for historical data before transition cutoff only)
- **Audit logs**: Near real-time (~5 minutes)

The `claude_vertex_ai_billing` view uses a hardcoded date cutoff (`2026-02-15`) to split between SADA (historical) and direct exports (current). After 90+ days, the SADA portion naturally becomes empty as partitions expire.

## Service Description in Direct Exports

**Important**: In raw detailed billing exports, Claude models appear as their own top-level
service descriptions (e.g., `Claude Opus 4.6`, `Claude Sonnet 4.5`) rather than under
`Vertex AI`. SADA normalizes these to `service_category = 'Vertex AI'`, but the direct
export portions of `claude_vertex_ai_billing` filter on `service.description LIKE 'Claude%'`.

## Existing Infrastructure

**Already in place:**
- Direct billing exports → per-account tables in `billing_export` datasets (~2-4h latency)
- `claude_vertex_ai_billing` → UNION ALL view across direct exports, filtered to `Claude%` services
- SADA billing export → `custom_sada_billing_views.billing_data` (materialized, partitioned, 90-day rolling window, refreshed daily — used for historical data only)
- Audit logs → `billing_export.cloudaudit_googleapis_com_data_access_*` (gcid-data-core only, currently)
- Older views → `billing_export.claude_usage_detailed`, `claude_cost_per_user` (superseded)

## Key Design Decisions

### Per-model attribution for shared projects

Billing data and user identity live in different sources:

| Source | Has cost/model? | Has user? |
|--------|----------------|-----------|
| `claude_vertex_ai_billing` (direct exports) | Yes — per-SKU costs | No — project-level only |
| Audit logs | Model name per request | Yes — `principalEmail` |

We join at **(project, date, model_family)** so users of expensive models are attributed correctly. A `model_family` key (e.g., `sonnet-4`, `opus-4`) normalizes model names from both sources via CASE expressions.

### Model family normalization

Both audit logs and billing SKUs are normalized to a common `model_family` key:

**Audit log side** (from `protopayload_auditlog.resourceName`):
```
claude-3-5-sonnet%  → sonnet-3.5
claude-3-5-haiku%   → haiku-3.5
claude-3-opus%      → opus-3
claude-sonnet-4-5%  → sonnet-4.5      (before sonnet-4 — first match wins)
claude-sonnet-4%    → sonnet-4
claude-opus-4-6%    → opus-4.6        (before opus-4 — first match wins)
claude-opus-4-5%    → opus-4.5
claude-opus-4-1%    → opus-4.1
claude-opus-4%      → opus-4
claude-haiku-4-5%   → haiku-4.5       (before haiku-4 — first match wins)
claude-haiku-4%     → haiku-4
ELSE                → raw model_name (graceful fallback)
```

**Billing SKU side** (from `sku_description`):
```
%3.5 sonnet%  → sonnet-3.5
%3.5 haiku%   → haiku-3.5
%opus 3%      → opus-3
%sonnet 4.5%  → sonnet-4.5            (before sonnet 4 — first match wins)
%sonnet 4%    → sonnet-4
%opus 4.6%    → opus-4.6              (before opus 4 — first match wins)
%opus 4.5%    → opus-4.5              (Google uses both dots and spaces:
%opus 4.1%    → opus-4.1               "Opus 4.1" vs "Opus 4 5" vs "Opus 4 6")
%opus 4%      → opus-4
%haiku 4.5%   → haiku-4.5             (before haiku 4 — first match wins)
%haiku 4%     → haiku-4
ELSE          → LOWER(sku_description) (graceful fallback)
```

**Maintenance**: New snapshots within a sub-version (e.g., `claude-sonnet-4-5-20260601`) need zero updates — the wildcards catch them. A new sub-version (e.g., Opus 4.7) requires adding one WHEN clause to each of two SQL files, placed *before* the base version pattern. Until updated, unrecognized models fall through to the ELSE with the raw name visible in the dashboard.

**ELSE behavior for shared projects**: Raw names from the two sides won't match each other, so costs go to `user_email = 'unattributed'` with the raw SKU visible. This prevents false cross-attribution between different unknown models.

### Audit log sinks — no user permissions needed

Log sinks use GCP-managed service accounts. Users in shared projects need zero permissions on gcid-data-core. Only the admin who runs the setup script needs access.

### Unattributed costs

LEFT JOIN from billing to audit data ensures dollar conservation. Costs without matching audit logs go to `user_email = 'unattributed'` so nothing silently disappears.

## Implementation

### Step 1: Project mapping table

**File: `vertex-ai/create-project-mapping.sql`**

```sql
DROP TABLE IF EXISTS `gcid-data-core.custom_sada_billing_views.claude_code_projects`;

CREATE TABLE `gcid-data-core.custom_sada_billing_views.claude_code_projects` (
  project_id STRING NOT NULL,
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
```

Billing account info (`billing_account_id`, `billing_account_name`) is derived from `claude_vertex_ai_billing` at query time, so the mapping table only stores what can't be looked up elsewhere.

### Step 2: Audit log views (for shared projects)

**File: `vertex-ai/create-audit-views.sql`**

Two views:

1. **`claude_code_audit_logs`** — CTE-based view extracting `user_email`, `project_id`, `model_name`, and derived `model_family` from audit log wildcard tables. Filters to `aiplatform.googleapis.com` + `anthropic` resources.

2. **`claude_code_daily_usage`** — Aggregation: `GROUP BY (usage_date, project_id, user_email, model_family)` producing `request_count`.

### Step 2.5: Unified Vertex AI billing view

**File: `vertex-ai/create-billing-union-view.sql`**

View `claude_vertex_ai_billing` that UNION ALLs direct billing exports across all 5 billing accounts, filtered to Vertex AI. Includes a historical cutoff date: dates before the cutoff read from SADA `billing_data`, dates on or after read from direct exports. Joins `billing_account_names` for display names. Includes `export_time` for freshness monitoring.

### Step 3: Unified per-user cost view

**File: `vertex-ai/create-user-costs-view.sql`**

Main view `claude_code_user_costs` with CTEs:

- **`billing_with_model`** — Adds `model_family` to `claude_vertex_ai_billing` rows via CASE on `sku_description` (Vertex AI filtering already applied in the union view)
- **`single_user_costs`** — Direct attribution: JOIN billing to mapping table, `cost = net_cost`
- **`shared_model_totals`** — Total request counts per `(project, date, model_family)`
- **`shared_user_costs`** — LEFT JOIN billing to audit data on `(project, date, model_family)`. Proportional: `cost = net_cost * SAFE_DIVIDE(user_requests, total_requests)`. Unmatched → `'unattributed'`
- **UNION ALL** both branches

Output columns: `usage_date, user_email, project_id, billing_account_id, billing_account_name, sku_description, model_family, cost, usage_amount, usage_unit, attribution_method`

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

**Calculated fields** (add to the BigQuery data source in Looker Studio):

| Field | Formula |
|-------|---------|
| `cost_object` | `IFNULL(REGEXP_EXTRACT(billing_account_name, "- (\\d+)"), billing_account_name)` |
| `user_name` | `IFNULL(REGEXP_EXTRACT(user_email, "^([^@]+)"), user_email)` |

`cost_object` extracts the numeric cost object ID from `billing_account_name` (e.g., `"Broad Institute - 5008388 (SADA)"` → `"5008388"`). Works whether or not the `(SADA)` suffix is present.

`user_name` extracts the local part of the email address (e.g., `"dpark@broadinstitute.org"` → `"dpark"`).

**Filters:** Date range, User, Project, Model, Billing Account

**Charts:**
| Chart | Type | Dimension | Metric |
|-------|------|-----------|--------|
| Total Cost | Scorecard | - | SUM(cost) |
| Cost by User | Bar chart | user_name | SUM(cost) |
| Daily Trend | Stacked bar | usage_date | SUM(cost), breakdown by user_name |
| Cost by Model | Bar chart | model_family | SUM(cost) |
| Cost by Billing Account | Pie chart | cost_object | SUM(cost) |
| User Details | Table | user_name, model_family, project_id, sku_description | SUM(cost) |

## Execution Order

1. `setup-billing-export.sh <project>` for each project needing a billing_export dataset
2. **Manual**: Configure billing exports in Cloud Console for each billing account
3. **Wait**: ~24 hours for initial data backfill into export tables
4. `create-project-mapping.sql` (no dependencies)
5. `setup-audit-sink.sh gcid-data-core` (if not already configured)
6. `create-audit-views.sql` (depends on audit logs in billing_export)
7. `create-billing-union-view.sql` (depends on export tables being populated)
8. `create-user-costs-view.sql` (depends on mapping table + audit views + union view)

Each SQL file: `bq query --nouse_legacy_sql --project_id=gcid-data-core < vertex-ai/FILE.sql`

## Adding New Users/Projects

### New single-user project

One INSERT, no audit sink needed:
```sql
INSERT INTO `gcid-data-core.custom_sada_billing_views.claude_code_projects`
  (project_id, project_type, user_email)
VALUES ('coding-newuser', 'single_user', 'newuser@broadinstitute.org');
```

### New shared project

Two steps:
1. Run `./vertex-ai/setup-audit-sink.sh <project-id>` (configures audit log routing)
2. Insert mapping row:
```sql
INSERT INTO `gcid-data-core.custom_sada_billing_views.claude_code_projects`
  (project_id, project_type, user_email)
VALUES ('new-shared-project', 'shared', NULL);
```

If the project uses a billing account not yet in the union view, also add it:
1. Run `./vertex-ai/setup-billing-export.sh <project>` to create the dataset
2. Configure the billing export in Cloud Console
3. Wait for backfill, then add the table to `create-billing-union-view.sql` and re-run

Audit logs route via the sink to the central wildcard table.

## Verification

After creating all objects:

**1. Check data freshness per billing account:**
```sql
SELECT billing_account_name, MAX(usage_date) AS latest_date, MAX(export_time) AS latest_export
FROM `gcid-data-core.custom_sada_billing_views.claude_vertex_ai_billing`
GROUP BY 1;
```

**2. Check model_family distribution in audit logs:**
```sql
SELECT model_family, COUNT(*) AS requests, COUNT(DISTINCT user_email) AS users
FROM `gcid-data-core.custom_sada_billing_views.claude_code_daily_usage`
GROUP BY 1 ORDER BY 2 DESC;
```

**3. Verify dollar conservation for shared projects:**
```sql
WITH attributed AS (
  SELECT project_id, usage_date, SUM(cost) AS attributed_cost
  FROM `gcid-data-core.custom_sada_billing_views.claude_code_user_costs`
  WHERE project_id IN (SELECT project_id FROM `gcid-data-core.custom_sada_billing_views.claude_code_projects` WHERE project_type = 'shared')
  GROUP BY 1, 2
),
raw AS (
  SELECT project_id, usage_date, SUM(net_cost) AS billing_cost
  FROM `gcid-data-core.custom_sada_billing_views.claude_vertex_ai_billing`
  WHERE project_id IN (SELECT project_id FROM `gcid-data-core.custom_sada_billing_views.claude_code_projects` WHERE project_type = 'shared')
  GROUP BY 1, 2
)
SELECT
  ROUND(SUM(a.attributed_cost), 2) AS total_attributed,
  ROUND(SUM(r.billing_cost), 2) AS total_billing,
  ROUND(ABS(SUM(a.attributed_cost) - SUM(r.billing_cost)), 4) AS discrepancy
FROM attributed a
FULL OUTER JOIN raw r USING (project_id, usage_date);
```

**4. Per-user cost summary:**
```sql
SELECT
  user_email, model_family, billing_account_name, attribution_method,
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
| `vertex-ai/create-billing-union-view.sql` | UNION ALL view across direct billing exports, filtered to Vertex AI |
| `vertex-ai/create-user-costs-view.sql` | Main unified per-user cost view (reads from union view) |
| `vertex-ai/setup-audit-sink.sh` | Script to configure audit log sink for shared projects |
| `vertex-ai/setup-billing-export.sh` | Creates BQ dataset + prints Cloud Console instructions for billing export |
