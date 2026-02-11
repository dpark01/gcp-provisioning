# Consolidated Per-User Claude Code Billing Dashboard

## Context

You have two usage patterns for tracking Claude Code (Vertex AI) costs:

1. **Original 4 users**: Each has a dedicated project (`coding-dpark`, `coding-carze`, `coding-lluebber`, `coding-pvarilly`). User = project, so billing data directly maps to users.

2. **Newer shared project**: Multiple users share `gcid-data-core` with audit log tracking for per-user attribution (already configured in `billing_export` dataset).

**Goal**: Create a unified Looker dashboard that shows per-user Claude Code costs across both patterns, supporting multiple billing accounts for future scalability.

## Existing Infrastructure

**Already in place:**
- SADA billing export → `custom_sada_billing_views.billing_data` (all 534 billing accounts, includes Vertex AI/Claude costs)
- Audit logs → `billing_export.cloudaudit_googleapis_com_data_access_*` (gcid-data-core only)
- Views → `billing_export.claude_usage_detailed`, `claude_cost_per_user`

**Current limitation:**
The existing `claude_cost_per_user` view only reads from one billing export table (`gcp_billing_export_resource_v1_00864F_515C74_8B1641`). The consolidated solution will use the SADA `billing_data` table which already has all billing accounts.

## What We'll Build

1. **Project mapping table** — maps projects to users and identifies single-user vs shared
2. **Unified cost view** — combines single-user (direct) and shared (proportional) attribution
3. **Looker dashboard** — consolidated view across all users and funding sources

## Implementation Plan

### Step 1: Create Claude Code project mapping table

Create a mapping table in `gcid-data-core.custom_sada_billing_views`:

**File: `vertex-ai/create-project-mapping.sql`**

```sql
-- claude_code_projects: Maps projects to users and funding sources
CREATE TABLE IF NOT EXISTS `gcid-data-core.custom_sada_billing_views.claude_code_projects` (
  project_id STRING,           -- GCP project ID
  project_type STRING,         -- 'single_user' or 'shared'
  user_email STRING,           -- For single_user projects (NULL for shared)
  billing_account_id STRING,   -- For grouping by funding source
  funding_source STRING,       -- Human-readable funding source name
  enabled_date DATE            -- When user started using Claude Code
);

-- Populate with current projects (actual billing account IDs from SADA data)
INSERT INTO `gcid-data-core.custom_sada_billing_views.claude_code_projects` VALUES
  ('coding-dpark', 'single_user', 'dpark@broadinstitute.org', '011F41-0941F7-749F4B', 'GCID 5008388', NULL),
  ('coding-carze', 'single_user', 'carze@broadinstitute.org', '011F41-0941F7-749F4B', 'GCID 5008388', NULL),
  ('coding-lluebber', 'single_user', 'lluebber@broadinstitute.org', '011F41-0941F7-749F4B', 'GCID 5008388', NULL),
  ('coding-pvarilly', 'single_user', 'pvarilly@broadinstitute.org', '0193CA-41033B-3FF267', 'GCID 5008157', NULL),
  ('gcid-data-core', 'shared', NULL, '00864F-515C74-8B1641', 'GCID 5008152', NULL);
```

### Step 2: Audit log sink setup (for shared projects)

**gcid-data-core**: Already configured. Audit logs flow to `billing_export.cloudaudit_googleapis_com_data_access_*`.

**Future shared projects**: See "Adding New Users/Projects" section below.

### Step 3: Create unified audit log view

This view already exists as `billing_export.claude_usage_detailed`. We'll create a wrapper that adds project_id for multi-project support.

**File: `vertex-ai/create-audit-views.sql`**

```sql
-- claude_code_audit_logs: Unified view of all audit logs from shared projects
-- Extends existing claude_usage_detailed to include project_id for multi-project support
CREATE OR REPLACE VIEW `gcid-data-core.custom_sada_billing_views.claude_code_audit_logs` AS
SELECT
  protopayload_auditlog.authenticationInfo.principalEmail AS user_email,
  resource.labels.project_id AS project_id,
  REGEXP_EXTRACT(protopayload_auditlog.resourceName, r'/models/(claude-[a-z0-9.-]+?)(?:@|$)') AS model_name,
  DATE(timestamp) AS usage_date,
  timestamp
FROM `gcid-data-core.billing_export.cloudaudit_googleapis_com_data_access_*`
WHERE protopayload_auditlog.serviceName = 'aiplatform.googleapis.com'
  AND protopayload_auditlog.resourceName LIKE '%anthropic%';

-- claude_code_daily_usage: API call counts by user/day/project for proportional attribution
CREATE OR REPLACE VIEW `gcid-data-core.custom_sada_billing_views.claude_code_daily_usage` AS
SELECT
  usage_date,
  project_id,
  user_email,
  model_name,
  COUNT(*) AS request_count
FROM `gcid-data-core.custom_sada_billing_views.claude_code_audit_logs`
GROUP BY 1, 2, 3, 4;
```

### Step 4: Create unified per-user cost view

This is the main view that joins billing data with user attribution. **Uses the materialized `billing_data` table (not SADA view) to avoid quota issues.**

**File: `vertex-ai/create-user-costs-view.sql`**

```sql
-- claude_code_user_costs: Per-user costs across all Claude Code projects
-- Uses billing_data (materialized daily) - NOT the SADA view directly
CREATE OR REPLACE VIEW `gcid-data-core.custom_sada_billing_views.claude_code_user_costs` AS

-- Single-user projects: user = project owner, direct cost attribution
WITH single_user_costs AS (
  SELECT
    b.usage_date,
    p.user_email,
    b.project_id,
    p.funding_source,
    b.billing_account_id,
    b.service_category,
    b.sku_description,
    b.net_cost AS cost,
    'direct' AS attribution_method
  FROM `gcid-data-core.custom_sada_billing_views.billing_data` b
  JOIN `gcid-data-core.custom_sada_billing_views.claude_code_projects` p
    ON b.project_id = p.project_id
  WHERE p.project_type = 'single_user'
    AND b.service_category = 'Vertex AI'  -- matches service_category in billing_data
),

-- Shared projects: proportional attribution by API call share
shared_project_daily_totals AS (
  SELECT
    usage_date,
    project_id,
    SUM(request_count) AS total_requests
  FROM `gcid-data-core.custom_sada_billing_views.claude_code_daily_usage`
  GROUP BY 1, 2
),

shared_user_costs AS (
  SELECT
    b.usage_date,
    u.user_email,
    b.project_id,
    p.funding_source,
    b.billing_account_id,
    b.service_category,
    b.sku_description,
    b.net_cost * SAFE_DIVIDE(u.request_count, t.total_requests) AS cost,
    'proportional' AS attribution_method
  FROM `gcid-data-core.custom_sada_billing_views.billing_data` b
  JOIN `gcid-data-core.custom_sada_billing_views.claude_code_projects` p
    ON b.project_id = p.project_id
  JOIN `gcid-data-core.custom_sada_billing_views.claude_code_daily_usage` u
    ON b.project_id = u.project_id AND b.usage_date = u.usage_date
  JOIN shared_project_daily_totals t
    ON u.project_id = t.project_id AND u.usage_date = t.usage_date
  WHERE p.project_type = 'shared'
    AND b.service_category = 'Vertex AI'
    AND t.total_requests > 0
)

SELECT * FROM single_user_costs
UNION ALL
SELECT * FROM shared_user_costs;
```

### Step 5: Looker Studio Dashboard

Create a new Looker Studio dashboard with data source `claude_code_user_costs`:

**Filters:**
- Date range (usage_date)
- User (user_email)
- Project (project_id)
- Funding Source (funding_source)

**Charts:**
| Chart | Type | Dimension | Metric |
|-------|------|-----------|--------|
| Total Cost | Scorecard | - | SUM(cost) |
| Cost by User | Bar chart | user_email | SUM(cost) |
| Daily Trend | Stacked bar | usage_date | SUM(cost), breakdown by user_email |
| Cost by Funding Source | Pie chart | funding_source | SUM(cost) |
| User Details | Table | user_email, project_id, sku_description | SUM(cost) |

## Adding New Users/Projects

### New single-user projects (one user = one project)

Just add to the mapping table - billing data will automatically appear via SADA export:
```sql
INSERT INTO `gcid-data-core.custom_sada_billing_views.claude_code_projects` VALUES
  ('coding-newuser', 'single_user', 'newuser@broadinstitute.org', 'NEW_BILLING_ACCT_ID', 'New Funding Source', CURRENT_DATE());
```

### New shared projects (multiple users sharing one project)

For a new shared project like `gcid-collab` on a different billing account:

**Step 1: Add to mapping table**
```sql
INSERT INTO `gcid-data-core.custom_sada_billing_views.claude_code_projects` VALUES
  ('gcid-collab', 'shared', NULL, 'NEW_BILLING_ACCT_ID', 'Collab Fund', CURRENT_DATE());
```

**Step 2: Enable audit logging on the new project**
```bash
# Enable Data Access audit logs for Vertex AI
gcloud logging settings update \
  --project=gcid-collab \
  --audit-log-filter='service=aiplatform.googleapis.com,method=*'
```

**Step 3: Create log sink to route audit logs to central BigQuery**
```bash
# Create sink from new project to central BQ dataset
gcloud logging sinks create vertex-ai-audit-logs \
  bigquery.googleapis.com/projects/gcid-data-core/datasets/billing_export \
  --project=gcid-collab \
  --log-filter='resource.type="audited_resource"
    protoPayload.serviceName="aiplatform.googleapis.com"
    protoPayload.methodName:"predict"'

# Get the sink's service account
SINK_SA=$(gcloud logging sinks describe vertex-ai-audit-logs \
  --project=gcid-collab --format='value(writerIdentity)')

# Grant BigQuery Data Editor to the sink's service account
bq add-iam-policy-binding \
  --member="${SINK_SA}" \
  --role="roles/bigquery.dataEditor" \
  gcid-data-core:billing_export
```

**Why this works:**
- **Billing data**: SADA export already includes ALL Broad billing accounts. Any new billing account automatically appears in `billing_data` - no additional setup needed.
- **Audit logs**: New projects need their sink configured once. All sinks write to the same `billing_export` dataset using wildcard tables (`cloudaudit_googleapis_com_data_access_*`).

## Files to Create

| File | Purpose |
|------|---------|
| `vertex-ai/create-project-mapping.sql` | DDL for project mapping table |
| `vertex-ai/create-audit-views.sql` | Audit log and usage views |
| `vertex-ai/create-user-costs-view.sql` | Main unified cost view |
| `vertex-ai/setup-audit-sink.sh` | Script to create audit log sink for a project |

## Verification

**1. Verify data appears for both project types:**
```sql
SELECT
  attribution_method,
  COUNT(DISTINCT user_email) AS users,
  COUNT(DISTINCT project_id) AS projects,
  ROUND(SUM(cost), 2) AS total_cost
FROM `gcid-data-core.custom_sada_billing_views.claude_code_user_costs`
WHERE usage_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 14 DAY)
GROUP BY 1;
```

**2. Verify proportional attribution sums match project totals:**
```sql
-- Compare user-attributed costs vs raw billing data for shared projects
WITH attributed AS (
  SELECT project_id, usage_date, SUM(cost) AS attributed_cost
  FROM `gcid-data-core.custom_sada_billing_views.claude_code_user_costs`
  WHERE attribution_method = 'proportional'
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
  a.project_id, a.usage_date,
  ROUND(a.attributed_cost, 2) AS attributed,
  ROUND(r.billing_cost, 2) AS actual,
  ROUND(ABS(a.attributed_cost - r.billing_cost), 4) AS diff
FROM attributed a
JOIN raw r ON a.project_id = r.project_id AND a.usage_date = r.usage_date
ORDER BY diff DESC
LIMIT 10;
```

**3. View per-user cost summary:**
```sql
SELECT
  user_email,
  funding_source,
  attribution_method,
  ROUND(SUM(cost), 2) AS total_cost,
  COUNT(DISTINCT usage_date) AS active_days
FROM `gcid-data-core.custom_sada_billing_views.claude_code_user_costs`
WHERE usage_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)
GROUP BY 1, 2, 3
ORDER BY total_cost DESC;
```
