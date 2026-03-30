# HHMI Billing Account Integration

## Context

As of 2026-03-27, we manage HHMI billing accounts in addition to Broad Institute accounts.
These are under a separate GCP billing organization (master account `00D847-EE429B-D09EC7`)
and do not appear in the Broad SADA master billing export.

| Account ID | Display Name | Master Account | Status |
|---|---|---|---|
| `01EC6B-15AAB1-294340` | HHMI Sabeti - General (SADA) | `00D847-EE429B-D09EC7` | Active — all projects here |
| `011947-176014-D8E363` | HHMI Sabeti - Human (SADA) | `00D847-EE429B-D09EC7` | Inactive — projects moved to General |

Only "HHMI Sabeti - General" is actively tracked.

## Completed (2026-03-30)

- [x] Direct billing export configured at `sabeti-mgmt.billing_export.gcp_billing_export_resource_v1_01EC6B_15AAB1_294340`
- [x] `billing_account_names` table refreshed — 22 accounts including both HHMI accounts
- [x] `vertex-ai/create-billing-union-view.sql` updated and deployed — HHMI account added
- [x] `scheduled-billing-refresh.sql` rewritten to use direct exports (dropped SADA entirely)
- [x] `refresh-materialized-billing.sh` rewritten to match
- [x] `billing_data` table rebuilt and verified with HHMI data
- [x] `vertex-ai/BILLING_PLAN.md` updated with HHMI account info
- [x] `billing-reporting/BILLING_REPORTING_PLAN.md` updated with SADA migration details

## Remaining

- [ ] **Update BQ Scheduled Query** — Replace SQL in "Daily Billing Data Refresh" (BQ Console > Scheduled Queries) with contents of `scheduled-billing-refresh.sql`. Dry-run estimate should show ~15 GB.
- [ ] **Looker Studio `cost_object` field** — Falls back to full display name for HHMI accounts. Functional but could be refined with a CASE expression to show "HHMI General".
- [ ] **billing-alerts** — No alerts configured for the HHMI account yet. When ready, insert rows into `billing_alert_config` with `scope_billing_account_id = '01EC6B-15AAB1-294340'`.

## Architecture

All billing data now comes from direct GCP billing exports (partitioned, ~6h latency).
SADA has been fully removed from the pipeline.

```
Direct billing exports (9 accounts):
  gcid-data-core      (00864F-515C74-8B1641)  ──┐
  broad-hvp-dasc      (011F41-0941F7-749F4B)  ──┤
  gcid-viral-seq      (0193CA-41033B-3FF267)  ──┤
  gcid-viral-seq      (01EA4B-6607E9-C37280)  ──┤
  sabeti-ai           (01EABF-8D854B-B4B3D0)  ──┼── CTE UNION ALL ──→ billing_data
  dsi-resources       (013A53-04CB08-63E4C8)  ──┤     (materialized, partitioned)
  sabeti-txnomics     (016D12-30A760-F5696D)  ──┤
  sabeti-dph-elc      (01E00D-6EA2B5-865FA0)  ──┤
  sabeti-mgmt [HHMI]  (01EC6B-15AAB1-294340)  ──┘
```

## HHMI-Specific Notes

- HHMI accounts do not use Broad-style numeric cost objects. The Looker `cost_object`
  calculated field falls back to the full `billing_account_name` for these accounts.
- No SADA master export exists for the HHMI billing organization.
- The "HHMI Sabeti - Human" account exists but is inactive (all projects moved to General).
