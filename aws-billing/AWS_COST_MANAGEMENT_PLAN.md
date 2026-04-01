# AWS Cost Management — Strategy & Research

*Last updated: 2026-04-01*

## Background

The Broad Institute manages a handful of AWS accounts under a single AWS Organization, with each account mapped to a Broad cost object. This document outlines the AWS-native tools and architecture for billing tracking, cost reporting, and dashboarding — analogous to what we've built for GCP in this repo.

## GCP → AWS Concept Mapping

### Organizational Model

| GCP Concept | AWS Equivalent | Key Difference |
|---|---|---|
| GCP Organization | AWS Organization | Top-level container |
| GCP Folder | AWS Organizational Unit (OU) | Grouping for policy inheritance |
| GCP Billing Account | AWS Organizations management account (consolidated billing) | In GCP, projects can be remapped between billing accounts freely. In AWS, billing is tied to org membership — much harder to change. |
| GCP Project | AWS Account | AWS fuses "resource container" and "billing entity" into one concept. Account = project + billing identity. |
| GCP project labels | AWS Cost Allocation Tags + Cost Categories | Tags on resources; Cost Categories for virtual grouping rules |

**Critical difference — resource mobility:** In GCP, changing a project's funding source is a simple billing account remap. In AWS, resources (S3 buckets, EC2 instances, RDS databases, etc.) cannot be moved between accounts — they must be copied/recreated. This means:
- Account structure should map to stable organizational boundaries
- Use **tags + Cost Categories** for flexible cost allocation across funding sources
- Plan account structure carefully upfront

### Billing & Cost Tools

| GCP Component | What It Does | AWS Equivalent |
|---|---|---|
| Direct billing exports → BigQuery | Raw billing line items | **CUR 2.0 → S3** (via AWS Data Exports) |
| BigQuery (materialized tables, SQL views) | Cost aggregation & querying | **Athena** querying Parquet in S3, schema via **Glue** |
| Looker Studio | Dashboards & visualization | **Amazon QuickSight** (native Cost & Usage Dashboard) |
| BQ Scheduled Queries → Cloud Function → SendGrid | Alerting pipeline | **AWS Budgets** (native) + optionally SNS → Lambda for custom alerts |
| Cloud Audit Logs → BigQuery | Usage attribution per user | **CloudTrail** → S3/Athena (or CloudTrail Lake) |
| `project_team_mapping` table | Cost allocation dimensions | **Cost Allocation Tags** + **Cost Categories** |
| `gcloud billing accounts list` | Account metadata | **AWS Organizations** consolidated billing view |

## Recommended AWS-Native Stack

### Tier 1 — Free / Near-Free (start here)

| Tool | Purpose | Cost |
|---|---|---|
| **AWS Organizations** | Consolidated billing, single invoice, pooled RI/Savings Plan discounts | Free |
| **AWS Cost Explorer** | Daily cost visibility, trending, 12-month forecasting | Free |
| **AWS Budgets** | Dollar thresholds per account/service with email/SNS alerts | First 2 free, then $0.02/budget/day |
| **Cost Categories** | Rules to group costs by team/project/environment | Free |
| **Cost Optimization Hub** | Rightsizing and Savings Plan recommendations | Free |
| **Tag Policies** | Enforce consistent tagging across accounts | Free |

### Tier 2 — Deep Analytics ($50-200/month)

| Tool | Purpose | Cost |
|---|---|---|
| **AWS Data Exports → CUR 2.0** | Detailed billing export to S3 as Parquet | Free (S3 storage only) |
| **Glue Crawler** | Auto-discover CUR schema, populate Data Catalog | Minimal |
| **Amazon Athena** | Serverless SQL over CUR data | $5/TB scanned (~$0.50-1.00/month typical) |
| **Amazon QuickSight** | Pre-built Cost & Usage Dashboard + custom dashboards | $3/dashboard/month + reader sessions |

### Tier 3 — Advanced (only if needed)

| Tool | Purpose | When |
|---|---|---|
| **Lambda + Athena custom alerting** | Stddev-based anomaly detection (like our GCP alert pipeline) | If AWS Budgets granularity is insufficient |
| **AWS Billing Conductor** | Internal chargeback with custom pricing rules | If doing reselling or complex chargeback |
| **CloudTrail + Athena** | Per-user usage attribution | If need user-level cost attribution (like Vertex AI tracking) |

## Simplifications vs GCP Pipeline

Our GCP billing pipeline has complexity that AWS eliminates:

| GCP Pattern | AWS Simplification |
|---|---|
| UNION ALL across 9 billing export tables (`scheduled-billing-refresh.sql`) | **Single CUR export** covers all accounts under the Organization |
| Daily materialized table refresh (`billing_data`, 90-day rolling) | Athena queries Parquet directly — no materialization needed |
| Account name sync scripts (`refresh-billing-account-names.sh`) | CUR 2.0 includes `bill_payer_account_name` and `line_item_usage_account_name` natively |
| Per-account billing export setup (`setup-billing-export.sh`) | Single CUR 2.0 export from management account |
| Summary view for Looker (`create-summary-view-v2.sql`) | QuickSight connects to Athena directly |

## CUR 2.0 Technical Details

### Schema

Fixed 125-column schema. Key columns:

**Cost:**
- `line_item_unblended_cost` — actual rate x usage (primary metric, analogous to GCP `cost`)
- `line_item_net_unblended_cost` — after discounts (analogous to GCP `net_cost`)
- `line_item_blended_cost` — org-average rate x usage
- `line_item_usage_amount` — quantity consumed

**Identity:**
- `line_item_usage_account_id` / `line_item_usage_account_name` — which account (analogous to GCP `project.id`)
- `bill_payer_account_id` / `bill_payer_account_name` — management account
- `line_item_product_code` — service name (AmazonEC2, AmazonS3, etc.)
- `line_item_resource_id` — specific resource

**Tags (nested maps, not flat columns):**
- `resource_tags` — `map<string,string>`, queried via `resource_tags['user_team']`
- `cost_category` — `map<string,string>`

### S3 Directory Structure

```
s3://billing-bucket/prefix/
└── export-name/
    ├── data/
    │   ├── BILLING_PERIOD=2025-01/
    │   │   ├── export-name-00001.snappy.parquet
    │   │   └── export-name-00002.snappy.parquet
    │   ├── BILLING_PERIOD=2025-02/
    │   │   └── ...
    │   └── ...
    └── metadata/
        └── BILLING_PERIOD=YYYY-MM/
            └── export-name-Manifest.json
```

Monthly partitions. Parquet files chunked at ~128MB-1GB.

### Data Freshness

- **First export:** ~24 hours after enabling
- **Ongoing:** Daily refresh
- **Current month:** Updated daily, may be amended until month-end
- **Previous months:** May be amended within 2 weeks post-month-end
- **Historical backfill:** Up to 36 months via AWS Support ticket

### Athena Table Setup

Two options:

**Option A — CloudFormation (recommended):** AWS provides a template that creates Glue database, crawler, Lambda trigger, and IAM roles automatically.

**Option B — Manual DDL with partition projection:**

```sql
CREATE EXTERNAL TABLE cur_data (
  bill_payer_account_id string,
  bill_payer_account_name string,
  line_item_usage_account_id string,
  line_item_usage_account_name string,
  line_item_product_code string,
  line_item_resource_id string,
  line_item_operation string,
  line_item_usage_start_date timestamp,
  line_item_usage_end_date timestamp,
  line_item_usage_amount double,
  line_item_unblended_cost double,
  line_item_blended_cost double,
  line_item_net_unblended_cost double,
  line_item_line_item_type string,
  line_item_line_item_description string,
  line_item_currency_code string,
  resource_tags map<string,string>,
  cost_category map<string,string>,
  product map<string,string>
)
PARTITIONED BY (billing_period string)
ROW FORMAT SERDE 'org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe'
STORED AS PARQUET
LOCATION 's3://billing-bucket/prefix/export-name/data/'
TBLPROPERTIES (
  'projection.enabled' = 'true',
  'projection.billing_period.type' = 'date',
  'projection.billing_period.range' = '2025-01,2030-12',
  'projection.billing_period.format' = 'yyyy-MM',
  'projection.billing_period.interval' = '1',
  'projection.billing_period.interval.unit' = 'MONTHS',
  'storage.location.template' =
    's3://billing-bucket/prefix/export-name/data/BILLING_PERIOD=${billing_period}'
);
```

Partition projection auto-discovers new monthly partitions — no manual `ALTER TABLE ADD PARTITION` needed.

### Example Queries

**Daily cost by service:**
```sql
SELECT
  DATE(line_item_usage_start_date) AS usage_date,
  line_item_product_code AS service,
  ROUND(SUM(line_item_unblended_cost), 2) AS daily_cost
FROM cur_data
WHERE line_item_usage_start_date >= DATE '2025-03-01'
  AND line_item_usage_start_date < DATE '2025-04-01'
GROUP BY 1, 2
ORDER BY usage_date, daily_cost DESC;
```

**Cost by account:**
```sql
SELECT
  line_item_usage_account_name,
  ROUND(SUM(line_item_unblended_cost), 2) AS total_cost
FROM cur_data
WHERE line_item_usage_start_date >= DATE '2025-03-01'
  AND line_item_usage_start_date < DATE '2025-04-01'
GROUP BY 1
ORDER BY total_cost DESC;
```

**Cost by tag (team):**
```sql
SELECT
  resource_tags['user_team'] AS team,
  line_item_product_code AS service,
  ROUND(SUM(line_item_unblended_cost), 2) AS total_cost
FROM cur_data
WHERE line_item_usage_start_date >= DATE '2025-03-01'
  AND line_item_usage_start_date < DATE '2025-04-01'
  AND resource_tags['user_team'] IS NOT NULL
GROUP BY 1, 2
ORDER BY total_cost DESC;
```

**Month-over-month comparison:**
```sql
WITH monthly AS (
  SELECT
    DATE_TRUNC('month', line_item_usage_start_date) AS month,
    line_item_product_code AS service,
    ROUND(SUM(line_item_unblended_cost), 2) AS cost
  FROM cur_data
  WHERE line_item_usage_start_date >= DATE '2025-01-01'
    AND line_item_usage_start_date < DATE '2025-04-01'
  GROUP BY 1, 2
)
SELECT service,
  MAX(CASE WHEN month = DATE '2025-03-01' THEN cost END) AS mar,
  MAX(CASE WHEN month = DATE '2025-02-01' THEN cost END) AS feb,
  MAX(CASE WHEN month = DATE '2025-03-01' THEN cost END)
    - MAX(CASE WHEN month = DATE '2025-02-01' THEN cost END) AS delta
FROM monthly
GROUP BY service
ORDER BY delta DESC;
```

### Query Cost Optimization

| Technique | Impact | Notes |
|---|---|---|
| **Partition pruning** | ~90% reduction | Always filter on `line_item_usage_start_date` |
| **Column selection** | ~96% reduction | Avoid `SELECT *` (125 columns); select only what you need |
| **Parquet format** | 6-10x vs CSV | Enables column pruning and predicate pushdown |
| **Query caching** | Free re-runs | Athena caches results 24h; identical query = no scan cost |

Typical monthly query cost for a handful of accounts: **$0.50-2.00/month**.

## Cross-Cloud Considerations

**Recommendation: Keep AWS data in AWS.** The S3 → Athena → QuickSight pipeline avoids cross-cloud egress, auth complexity, and data sovereignty issues.

If a unified view is eventually needed:
- **Option A (recommended):** Separate dashboards — Looker Studio for GCP, QuickSight for AWS — side-by-side in a portal
- **Option B:** Export AWS CUR summary to BigQuery via lightweight scheduled transfer, build combined Looker dashboard
- **Option C:** Third-party tool (Grafana Cloud, etc.) that federates queries across both

## Implementation Order

1. **Set up AWS Organizations** (if not already) with consolidated billing
2. **Enable Cost Explorer** and **create initial Budgets** — immediate visibility, zero code
3. **Define tagging strategy** and enforce via Tag Policies
4. **Create Cost Categories** mapping accounts/tags to teams
5. **Enable CUR 2.0 export** via Data Exports to S3
6. **Deploy pre-built QuickSight Cost & Usage Dashboard**
7. **Set up Athena** for ad-hoc SQL queries against CUR data
8. *(If needed)* Build custom alerting with Lambda + Athena for anomaly detection
