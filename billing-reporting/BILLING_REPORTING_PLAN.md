# GCP Billing Account Cost Reporting

## Context

We want generalized cost reporting for any GCP Billing Account at the Broad. Starting with three accounts as concrete examples, then generalizing.

**Key discovery:** All Broad billing data already exists in the SADA master billing export (`broad-gcp-billing.gcp_billing_export_views.sada_billing_export_resource_v1_001AC2_2B914D_822931`), readable by all `@broadinstitute.org` users. 100+ billing accounts, millions of rows, dating back to April 2025. No new BQ exports needed.

**Target billing accounts:**
| Account ID | Display Name | 14d Spend | Notes |
|---|---|---|---|
| `011F41-0941F7-749F4B` | Broad Institute - 5008388 (SADA) | $12,859 | 11 projects, viral surveillance |
| `0193CA-41033B-3FF267` | Broad Institute - 5008157 | $6,082 | ~80 projects, gcid-viral-seq heavy |
| `00864F-515C74-8B1641` | Broad Institute - 5008152 | $1,519 | ~65 projects, malaria/bacterial/fungal |

**What works well for grouping:**
- **Terra vs Non-Terra:** `project.id LIKE 'terra-%'` is clean and reliable
- **Terra Billing Project:** `workspacenamespace` project label (e.g., `gcid-viral-y6`, `broad-fungal-firecloud`)
- **Terra Workspace:** `workspacename` project label
- **Service categories:** Compute, Storage, Vertex AI (includes Claude models), Networking, Support, Other
- **Team labels on non-Terra projects:** Using `team` label key (experiment: label `gcid-malaria` with `team=malaria`)

**Labels in billing export are retroactive** — they reflect current project label state across all historical rows, so adding a `team` label now will group historical data correctly.

## Plan

### Step 1: Create BQ dataset and billing account name mapping table

Create dataset `gcid-data-core.custom_sada_billing_views` and a mapping table `billing_account_names`.

**Refresh script:** `refresh-billing-account-names.sh`
- Pulls display names via `gcloud billing accounts list`
- Loads into BQ mapping table (full replace)
- Run a couple times a year or when accounts are added/renamed

**Table schema (`billing_account_names`):**
- `billing_account_id` STRING
- `display_name` STRING
- `refreshed_at` TIMESTAMP

### Step 2: Label `gcid-malaria` with `team=malaria`

```bash
gcloud projects update gcid-malaria --update-labels team=malaria
```

Then query the billing export to verify the label appears retroactively on historical rows.

### Step 3: Create summary view (no billing account restriction)

Create `gcid-data-core.custom_sada_billing_views.billing_account_summary` — covers ALL billing accounts in the SADA export. Filter to specific accounts at query time.

No storage cost for keeping the view unrestricted (it's a VIEW, not a table). Query-time filtering on `billing_account_id` is just as efficient.

```sql
CREATE OR REPLACE VIEW
  `gcid-data-core.custom_sada_billing_views.billing_account_summary` AS
SELECT
  b.billing_account_id,
  n.display_name AS billing_account_name,
  DATE(b.usage_start_time) AS usage_date,
  b.project.id AS project_id,
  b.project.name AS project_name,
  CASE
    WHEN b.project.id LIKE 'terra-%' THEN 'Terra'
    WHEN b.project.id IS NULL THEN 'Account-level'
    ELSE 'Non-Terra'
  END AS project_category,
  (SELECT value FROM UNNEST(b.project.labels) WHERE key = 'workspacenamespace')
    AS terra_billing_project,
  (SELECT value FROM UNNEST(b.project.labels) WHERE key = 'workspacename')
    AS terra_workspace_name,
  (SELECT value FROM UNNEST(b.project.labels) WHERE key = 'team')
    AS team,
  b.service.description AS service_name,
  CASE
    WHEN b.service.description = 'Compute Engine' THEN 'Compute'
    WHEN b.service.description = 'Cloud Storage' THEN 'Storage'
    WHEN b.service.description = 'Vertex AI'
         OR LOWER(b.service.description) LIKE '%claude%'
         OR LOWER(b.service.description) LIKE '%opus%'
         OR LOWER(b.service.description) LIKE '%sonnet%'
         OR LOWER(b.service.description) LIKE '%haiku%'
      THEN 'Vertex AI'
    WHEN b.service.description = 'Networking' THEN 'Networking'
    WHEN b.service.description = 'Support' THEN 'Support'
    ELSE 'Other'
  END AS service_category,
  b.sku.description AS sku_description,
  b.location.region AS region,
  b.cost,
  b.cost + IFNULL((SELECT SUM(c.amount) FROM UNNEST(b.credits) c), 0) AS net_cost,
  b.usage.amount AS usage_amount,
  b.usage.unit AS usage_unit
FROM `broad-gcp-billing.gcp_billing_export_views.sada_billing_export_resource_v1_001AC2_2B914D_822931` b
LEFT JOIN `gcid-data-core.custom_sada_billing_views.billing_account_names` n
  ON b.billing_account_id = n.billing_account_id
```

### Step 4: Run exploratory queries and display results

Using the view, run and display:

- **a)** Daily cost by billing account (past 14 days, filtering to our 3 accounts)
- **b)** Daily cost by project_category (Terra vs Non-Terra) per account
- **c)** Daily cost by service_category (Compute vs Storage vs Vertex AI vs Other)
- **d)** Terra billing project cost breakdown per account
- **e)** Top non-Terra projects by cost, showing `team` label where set
- **f)** Verify `team=malaria` label appears retroactively on `gcid-malaria` historical rows

## Files to Create

| File | Description |
|---|---|
| `refresh-billing-account-names.sh` | Script to populate/refresh the BQ mapping table from `gcloud billing accounts list` |

## BQ Objects to Create

| Object | Type | Dataset |
|---|---|---|
| `billing_account_names` | TABLE | `gcid-data-core.custom_sada_billing_views` |
| `billing_account_summary` | VIEW | `gcid-data-core.custom_sada_billing_views` |

## Verification

1. Mapping table: `SELECT * FROM billing_account_names` shows human-readable names
2. Label experiment: query `gcid-malaria` rows — `team` column shows `malaria` on all historical rows
3. Summary view: `SELECT billing_account_name, usage_date, SUM(net_cost) ... GROUP BY 1, 2` shows daily costs with readable names
4. Cross-check: per-account totals match direct queries against the SADA export

## Step 5: Looker Studio Dashboard Setup

### 5a. Create Data Source

1. Go to [Looker Studio](https://lookerstudio.google.com)
2. Click **Create** > **Data source**
3. Select **BigQuery** connector
4. Navigate to: `gcid-data-core` > `custom_sada_billing_views` > `billing_account_summary`
5. Click **Connect**
6. Review field types — ensure:
   - `usage_date` is set to **Date**
   - `cost` and `net_cost` are set to **Currency (USD)**
   - `billing_account_name`, `project_category`, `service_category`, `team` are **Text**
7. Click **Create Report** (or **Add to Report** if adding to an existing one)

### 5b. Add Controls (Filters)

At the top of the report, add these filter controls:

| Control | Type | Field | Default |
|---|---|---|---|
| Date range | Date range control | `usage_date` | Last 14 days |
| Billing account | Drop-down list | `billing_account_name` | All |
| Project category | Drop-down list | `project_category` | All |
| Service category | Drop-down list | `service_category` | All |

### 5c. Recommended Dashboard Layout

```
┌──────────────────────────────────────────────────────────────────────────┐
│ GCP Billing Dashboard    [Date Range] [Account ▾] [Category ▾] [Svc ▾] │
├──────────────┬──────────────┬──────────────┬─────────────────────────────┤
│  Total Cost  │  Daily Avg   │  # Accounts  │  # Projects                │
│  [Scorecard] │  [Scorecard] │  [Scorecard]  │  [Scorecard]              │
├──────────────┴──────────────┴──────────────┴─────────────────────────────┤
│                                                                          │
│  Daily Cost Trend [Stacked bar — breakdown by service_category]          │
│  x: usage_date, y: SUM(net_cost), color: service_category               │
│                                                                          │
├──────────────────────────────────┬───────────────────────────────────────┤
│  Cost by Account [Bar chart]     │  Terra vs Non-Terra [Stacked bar]    │
│  Dim: billing_account_name       │  x: usage_date                      │
│  Metric: SUM(net_cost)           │  color: project_category             │
│                                  │  y: SUM(net_cost)                    │
├──────────────────────────────────┼───────────────────────────────────────┤
│  Top Projects [Table]            │  Terra Billing Projects [Table]      │
│  Dims: project_id, team,         │  Dims: terra_billing_project,       │
│        service_category          │        service_category              │
│  Metric: SUM(net_cost)           │  Metric: SUM(net_cost)              │
│  Sort: net_cost DESC             │  Sort: net_cost DESC                │
└──────────────────────────────────┴───────────────────────────────────────┘
```

### 5d. Chart Configuration

| Chart | Type | Dimension(s) | Metric | Notes |
|---|---|---|---|---|
| Total Cost | Scorecard | — | SUM(net_cost) | Format as USD |
| Daily Avg | Scorecard | — | SUM(net_cost) / (DATE_DIFF(MAX(usage_date), MIN(usage_date)) + 1) | Calculated field |
| Daily by Service | Stacked Bar | usage_date | SUM(net_cost) | Breakdown: service_category |
| Daily Terra vs Non-Terra | Stacked Bar | usage_date | SUM(net_cost) | Breakdown: project_category |
| Cost by Account | Bar | billing_account_name | SUM(net_cost) | Horizontal bar, sorted |
| Top Projects | Table | project_id, team, service_category | SUM(net_cost) | Sort descending, show top 20 |
| Terra Billing Projects | Table | terra_billing_project, service_category | SUM(net_cost) | Filter: project_category = "Terra" |

### 5e. Calculated Fields to Add in Looker

| Field Name | Formula | Purpose |
|---|---|---|
| Date Range Days | `DATE_DIFF(MAX(usage_date), MIN(usage_date)) + 1` | Length of selected date range |
| Daily Average Cost | `SUM(net_cost) / Date Range Days` | Average cost per day |
| Project Display | `CASE WHEN project_category = "Terra" THEN terra_workspace_name ELSE project_id END` | Human-readable project name |

### 5f. Optional: Daily Email Alert

Looker Studio supports scheduled email delivery:
1. Click **Share** > **Schedule email delivery**
2. Set frequency to **Daily**
3. Choose recipients
4. Set delivery time (e.g., 9am)
5. The report will be sent as a PDF snapshot with current filter state

For more sophisticated alerting (e.g., "alert if daily cost exceeds $X"), consider:
- A BigQuery scheduled query that checks yesterday's cost and sends an email via Cloud Functions
- Or a simple cron script using `bq query` + email
