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

## Completed (2026-02-09)

### Step 1: BQ dataset + mapping table -- DONE
- Created dataset `gcid-data-core.custom_sada_billing_views`
- Created and ran `billing-reporting/refresh-billing-account-names.sh` — loaded 20 billing accounts
- `gcloud billing accounts list` returns 20 accounts vs 534 in the SADA export; LEFT JOIN handles missing names (NULL)
- Script uses `--force` flag for idempotent dataset creation
- Note: `gcloud projects update --update-labels` does NOT work in the base SDK; must use Cloud Resource Manager REST API for project labels

### Step 2: Label `gcid-malaria` -- DONE (pending export refresh)
- Applied `team=malaria` via Cloud Resource Manager REST API (confirmed on project)
- Billing export still shows `team=NULL` as of 2026-02-09 — awaiting export refresh

### Step 3: Summary view -- DONE (needs revision, see TODO #1)
- Created `billing_account_summary` view (SQL in `billing-reporting/create-summary-view.sql`)
- Covers ALL 534 billing accounts; no time scoping currently

### Step 4: Exploratory queries -- DONE
- All 6 queries (a-f) ran successfully. Key findings:
  - 5008388 (SADA): $12.7K/14d, Feb 1 spike to $4K. Top: `broad-hvp-dasc` ($8.3K)
  - 5008157: $6K/14d. Top: `gcid-viral-seq` ($4.9K)
  - 5008152: $1.5K/14d. Top: `gcid-malaria` ($762)
  - Non-Terra dominates spend; Compute ($12.6K) and Storage ($5.1K) are top service categories
  - `team=malaria` label not yet visible in export

### Quota issue discovered
- Hit `QueryUsagePerDay` custom quota on `gcid-data-core` after many queries against the full SADA export (534 accounts, millions of rows)
- This is also what caused Looker Studio "cannot connect to your data set" errors (not a filter/join issue)
- **Must fix before Looker dashboard is usable** — every chart fires its own query, and filter changes re-query all charts

## Files Created

| File | Description |
|---|---|
| `billing-reporting/refresh-billing-account-names.sh` | Refresh BQ mapping table from `gcloud billing accounts list` |
| `billing-reporting/create-summary-view.sql` | SQL definition of the billing_account_summary view |

## BQ Objects Created

| Object | Type | Dataset |
|---|---|---|
| `billing_account_names` | TABLE (20 rows) | `gcid-data-core.custom_sada_billing_views` |
| `billing_account_summary` | VIEW | `gcid-data-core.custom_sada_billing_views` |

## TODO: Next Session

### 1. Solve the query cost / quota problem (BLOCKING)

The current view scans the entire SADA export on every query. Need to determine whether we can scope it cheaply or must materialize.

**First: check if the SADA export is date-partitioned:**
```sql
SELECT column_name, is_partitioning_column, clustering_ordinal_position
FROM `broad-gcp-billing.gcp_billing_export_views.INFORMATION_SCHEMA.COLUMNS`
WHERE table_name = 'sada_billing_export_resource_v1_001AC2_2B914D_822931'
```
If that fails (the source may itself be a view), do a dry-run with and without a date filter to compare estimated bytes scanned.

**Path A — Table is partitioned:** Add a rolling time window to the view (e.g., 90 days):
```sql
WHERE b.usage_start_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
```
Update `create-summary-view.sql` and recreate the view. This is the simple/preferred path.

**Path B — Table is NOT partitioned (or is a view itself):** Create a nightly materialized export. Write a scheduled query or script that:
- Queries the SADA export with a date filter (e.g., rolling 90 days)
- Writes results to a partitioned TABLE in `custom_sada_billing_views`
- Looker Studio points at the materialized table instead of the view
- Script goes in `billing-reporting/`

### 2. Verify `team=malaria` label propagation
Re-run query (f) to check if the billing export now shows `team=malaria` retroactively:
```sql
SELECT project_id, team, MIN(usage_date) AS earliest, MAX(usage_date) AS latest, COUNT(*) AS rows
FROM `gcid-data-core.custom_sada_billing_views.billing_account_summary`
WHERE project_id = 'gcid-malaria'
GROUP BY 1, 2
```

### 3. Fix and finish Looker Studio dashboard
- Confirm dashboard works after quota resets (and after fixing query cost in TODO #1)
- If filtering by `billing_account_name` still breaks, try `billing_account_id` instead
- Add charts per Step 5c/5d layout below
- Add calculated fields per Step 5e
- Consider adding more `team=` labels to non-Terra projects via Cloud Console (**IAM & Admin > Settings > Labels**)

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
