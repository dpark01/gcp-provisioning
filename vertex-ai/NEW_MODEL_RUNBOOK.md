# Runbook: Onboarding a New Claude Model

Use this every time Anthropic releases a new Claude model (or a new sub-version
of an existing family) that we want available on Vertex AI. It covers the three
things that must happen for the model to work *and* be tracked correctly in billing:

1. **Reporting** — add the model to the BigQuery views so usage/cost is normalized
2. **Enablement** — turn the model on in each GCP project's Model Garden
3. **IT ticket** — get the model's partner features added to the org policy allowlist

> Worked example: see `OPUS_4.8_ROLLOUT.md` for the Opus 4.8 rollout (2026-05-28),
> which is a filled-in instance of this runbook.

---

## When does each step apply?

| Change | Reporting (views) | Enablement (Model Garden) | IT ticket (org policy) |
|--------|:-----------------:|:-------------------------:|:----------------------:|
| New family or sub-version (e.g. Opus 4.8, Sonnet 5) | ✅ Yes | ✅ Yes | ✅ Yes |
| New snapshot within an existing sub-version (e.g. `claude-opus-4-8-20260601`) | ❌ No¹ | ❌ No² | ❌ No |

¹ The view wildcards (`%opus-4-8%`) already catch new snapshots — zero SQL changes.
² Model Garden access and the org policy allowlist are keyed by sub-version, not snapshot.

If in doubt: a change to the version number after `claude-<family>-` (e.g. `4-7` → `4-8`)
means **all three steps**. A change only to the trailing date snapshot means **none**.

---

## Step 1 — Reporting: update the BigQuery views

Two files contain a `model_family` CASE expression that must learn the new model.
**Both** must be updated, and the new clause must go **before** the base-version
pattern (first match wins).

### 1a. `vertex-ai/create-audit-views.sql` (audit-log side)

Matches the model name from `protopayload_auditlog.resourceName`. Add one line in
the Claude 4.x block, before the base `claude-<family>-4%` clause:

```sql
WHEN model_name LIKE 'claude-opus-4-8%'        THEN 'opus-4.8'
```

Pattern: `claude-<family>-<major>-<minor>%` → `<family>-<major>.<minor>`.

### 1b. `vertex-ai/create-user-costs-view.sql` (billing-SKU side)

Matches Google's billing `sku_description`. **Google is inconsistent** and uses both
dots and spaces in SKU names (`Opus 4.8` *and* `Opus 4 8`), so add **both** variants,
before the base `%opus 4%` clause:

```sql
WHEN LOWER(b.sku_description) LIKE '%opus 4.8%'
  OR LOWER(b.sku_description) LIKE '%opus 4 8%'          THEN 'opus-4.8'
```

### 1c. Update the doc

Add the new patterns to the two reference blocks in `BILLING_PLAN.md`
("Audit log side" / "Billing SKU side").

### 1d. Deploy the views

```bash
cd ~/dev/gcp-provisioning
bq query --nouse_legacy_sql --project_id=gcid-data-core < vertex-ai/create-audit-views.sql
bq query --nouse_legacy_sql --project_id=gcid-data-core < vertex-ai/create-user-costs-view.sql
```

(For Opus 4.8 we used a one-off `deploy-opus-4.8-support.sh` wrapper; the two `bq`
commands above are the general equivalent.)

**Do this before enabling the model.** If the model is enabled first, early usage
falls through to the `ELSE` clause and shows up under raw model names instead of the
normalized `model_family` until the views are updated. (No data is lost — it just
shows up unattributed/raw in the meantime.)

### 1e. Commit and push

```bash
git add vertex-ai/
git commit -m "Add Claude <model> support to Vertex AI billing tracking"
git push
```

---

## Step 2 — Enablement: turn the model on in each project

**The mapping table is the source of truth for which projects to update.** Get the
current list with:

```bash
bq query --nouse_legacy_sql --project_id=gcid-data-core \
'SELECT project_id, project_type, user_email
 FROM `gcid-data-core.custom_sada_billing_views.claude_code_projects`
 ORDER BY project_type, project_id'
```

As of the Opus 4.8 rollout (2026-05-28) that list was **11 projects**:

**Single-user (5):** `coding-dpark`, `coding-carze`, `coding-lluebber`,
`coding-pvarilly`, `sabeti-librechat`

**Shared (6):** `gcid-data-core`, `sabeti-ai`, `sabeti-encode`, `sabeti-mgmt`,
`viral-seq-ai`, `cigass-ai`

For each project, enable the model in Vertex AI Model Garden (manual — no API/Terraform
support). The console URL pattern is:

```
https://console.cloud.google.com/vertex-ai/publishers/anthropic/model-garden/<MODEL_ID>?project=<PROJECT_ID>
```

e.g. `.../model-garden/claude-opus-4-8?project=coding-dpark`. Click **Enable** →
accept terms → wait for enablement.

> **Keep the mapping table current.** If a new user/project should get the model,
> add it to `create-project-mapping.sql` first (and run `setup-audit-sink.sh` for a
> new *shared* project) so it appears in the source-of-truth list above.

---

## Step 3 — IT ticket: org policy partner-feature allowlist

**This is the easy-to-miss step.** Enabling a model in Model Garden grants *inference*
access only. Server-side **partner model features** — most importantly `web_search`
(used by Claude Code's WebSearch tool) — are gated separately by the org policy
constraint `constraints/vertexai.allowedPartnerModelFeatures`, which is an **allowlist
keyed per model sub-version**. A newly enabled model is **not** automatically on it,
so WebSearch (and other gated features) break on the new model until IT adds it.

The policy is set at the **folder/org level** (inherited by projects), so editing it
requires Org Policy Admin — hence a ticket to IT rather than a self-serve change.

### Symptom (how to recognize this is the problem)

WebSearch fails with `web_search` working on the *old* model but not the new one:

```
Organization Policy constraint constraints/vertexai.allowedPartnerModelFeatures
violated ... attempting to use a disallowed feature web_search for Partner model
claude-opus-4-8.
```

### Check the current allowlist

```bash
gcloud org-policies describe constraints/vertexai.allowedPartnerModelFeatures \
  --project=coding-dpark --effective
```

### Ticket template

> **Subject:** Add Claude <model> to Vertex AI partner-feature allowlist
>
> **Request:** Please add the following value(s) to the `is:` allowlist on the org
> policy constraint `constraints/vertexai.allowedPartnerModelFeatures` (set at the
> folder/org level that our GCP projects inherit from). **Preserve all existing
> entries** — this is an allowlist, not a replacement.
>
> - `publishers/anthropic/models/<MODEL_ID>:web_search`
>   (e.g. `publishers/anthropic/models/claude-opus-4-8:web_search`)
>
> **Why:** We've enabled Claude <model> in Vertex AI Model Garden across our projects.
> Model Garden enablement does not add the model to this partner-feature allowlist,
> so the Vertex `web_search` feature (used by Claude Code's WebSearch tool) is blocked
> for the new model until this entry is added. Existing models (Opus 4.7, 4.6,
> Sonnet 4.6) are already on the allowlist.
>
> **Scope:** Applies to all projects inheriting the constraint. Add any other partner
> features we use for the new model at the same time if applicable.

---

## Step 4 — Verify (after enablement + some real usage)

Wait ~6–24h for billing data (audit logs are near real-time). Replace `opus-4.8`
with the new `model_family`.

**Audit logs normalize correctly:**
```sql
SELECT model_name, model_family, COUNT(*) AS requests, COUNT(DISTINCT user_email) AS users
FROM `gcid-data-core.custom_sada_billing_views.claude_code_audit_logs`
WHERE model_name LIKE 'claude-opus-4-8%'
  AND usage_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
GROUP BY 1, 2 ORDER BY 3 DESC;
-- Expect model_family = 'opus-4.8', NOT a raw model name.
```

**Billing/cost attribution works:**
```sql
SELECT user_email, project_id, model_family,
       ROUND(SUM(cost), 2) AS total_cost, COUNT(DISTINCT usage_date) AS days_active
FROM `gcid-data-core.custom_sada_billing_views.claude_code_user_costs`
WHERE model_family = 'opus-4.8'
  AND usage_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
GROUP BY 1, 2, 3 ORDER BY 4 DESC;
```

**WebSearch works** (after IT closes the Step 3 ticket): run a trivial WebSearch in
a Claude Code session pointed at the new model; it should return results instead of
the `allowedPartnerModelFeatures` error.

**Looker:** confirm the new `model_family` appears in the model filter dropdown.

---

## Quick checklist

- [ ] Step 1: Add `model_family` clause to **both** SQL files (sub-version before base)
- [ ] Step 1: Update `BILLING_PLAN.md` pattern blocks
- [ ] Step 1: Deploy both views to `gcid-data-core`
- [ ] Step 1: Commit + push
- [ ] Step 2: Pull current project list from `claude_code_projects`
- [ ] Step 2: Enable model in Model Garden for every project in that list
- [ ] Step 3: File IT ticket to add `<model>:web_search` to the org policy allowlist
- [ ] Step 4: Verify audit/cost normalization, WebSearch, and Looker after real usage
