#!/usr/bin/env bash
# Sets up a BigQuery dataset for direct GCP billing export in a target project.
#
# Direct billing exports deliver data in ~6 hours (vs ~36 hours from SADA)
# and are partitioned, making queries cheap. Each billing account needs its
# own export configured in Cloud Console after the dataset is created.
#
# This script:
#   1. Creates a `billing_export` dataset in the target project
#   2. Prints Cloud Console instructions for configuring the billing export
#   3. Optionally verifies the export table exists (--verify flag)
#
# Prerequisites:
#   - gcloud CLI authenticated with sufficient permissions
#   - Target project must exist
#   - You must have roles/bigquery.dataOwner on the target project
#
# Usage:
#   ./setup-billing-export.sh <project-id>
#   ./setup-billing-export.sh --verify <project-id> <billing-account-id>
#
# Examples:
#   ./setup-billing-export.sh broad-hvp-dasc
#   ./setup-billing-export.sh --verify broad-hvp-dasc 011F41-0941F7-749F4B

set -euo pipefail

# ============================================================================
# Argument parsing
# ============================================================================
VERIFY=false
if [[ "${1:-}" == "--verify" ]]; then
  VERIFY=true
  shift
fi

if $VERIFY; then
  if [[ $# -ne 2 ]]; then
    echo "Usage: $0 --verify <project-id> <billing-account-id>"
    echo ""
    echo "Verify that the billing export table exists after setup."
    exit 1
  fi
  TARGET_PROJECT="$1"
  BILLING_ACCOUNT_ID="$2"
else
  if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <project-id>"
    echo "       $0 --verify <project-id> <billing-account-id>"
    echo ""
    echo "Creates a billing_export dataset and prints setup instructions."
    echo ""
    echo "Projects needing setup (Broad Institute):"
    echo "  broad-hvp-dasc   (billing account 011F41-0941F7-749F4B)"
    echo "  gcid-viral-seq   (billing account 0193CA-41033B-3FF267, 01EA4B-6607E9-C37280)"
    echo "  sabeti-ai        (billing account 01EABF-8D854B-B4B3D0)"
    echo "  dsi-resources    (billing account 013A53-04CB08-63E4C8)"
    echo ""
    echo "Projects needing setup (HHMI):"
    echo "  sabeti-mgmt      (billing account 01EC6B-15AAB1-294340)"
    exit 1
  fi
  TARGET_PROJECT="$1"
fi

DATASET="billing_export"

# ============================================================================
# Verify mode: check if the export table exists
# ============================================================================
if $VERIFY; then
  ACCT_UNDERSCORED=$(echo "${BILLING_ACCOUNT_ID}" | tr '-' '_')
  TABLE_PREFIX="gcp_billing_export_resource_v1_${ACCT_UNDERSCORED}"

  echo "Checking for export table in ${TARGET_PROJECT}.${DATASET}..."
  TABLES=$(bq ls --project_id="${TARGET_PROJECT}" "${DATASET}" 2>/dev/null || true)

  if echo "${TABLES}" | grep -q "${TABLE_PREFIX}"; then
    echo "  Export table found: ${TABLE_PREFIX}"
    echo ""
    echo "  Row count:"
    bq query --nouse_legacy_sql --project_id="${TARGET_PROJECT}" \
      "SELECT COUNT(*) AS row_count FROM \`${TARGET_PROJECT}.${DATASET}.${TABLE_PREFIX}\`"
    echo ""
    echo "  Date range:"
    bq query --nouse_legacy_sql --project_id="${TARGET_PROJECT}" \
      "SELECT MIN(DATE(usage_start_time)) AS earliest, MAX(DATE(usage_start_time)) AS latest FROM \`${TARGET_PROJECT}.${DATASET}.${TABLE_PREFIX}\`"
  else
    echo "  Export table NOT found yet."
    echo "  Expected table: ${TABLE_PREFIX}"
    echo "  This is normal if the billing export was just configured."
    echo "  Initial backfill takes ~24 hours."
  fi
  exit 0
fi

# ============================================================================
# Step 1: Verify the target project exists
# ============================================================================
echo "=== Billing Export Dataset Setup ==="
echo "Target project: ${TARGET_PROJECT}"
echo "Dataset:        ${DATASET}"
echo ""

echo "Step 1: Verifying project ${TARGET_PROJECT}..."
if ! gcloud projects describe "${TARGET_PROJECT}" --format='value(projectId)' > /dev/null 2>&1; then
  echo "ERROR: Cannot access project '${TARGET_PROJECT}'. Check that it exists and you have access."
  exit 1
fi
echo "  Project verified."
echo ""

# ============================================================================
# Step 2: Create the billing_export dataset
# ============================================================================
echo "Step 2: Creating dataset ${TARGET_PROJECT}:${DATASET}..."
bq --project_id="${TARGET_PROJECT}" mk --dataset --force \
  --description="GCP billing export - direct export for Claude Code cost tracking" \
  --location=US \
  "${DATASET}"
echo "  Dataset created (or already exists)."
echo ""

# ============================================================================
# Step 3: Print Cloud Console instructions
# ============================================================================
echo "=== Dataset Created ==="
echo ""
echo "NEXT STEPS — Configure billing export in Cloud Console:"
echo ""
echo "  1. Go to: https://console.cloud.google.com/billing"
echo "  2. Select the billing account associated with ${TARGET_PROJECT}"
echo "  3. Navigate to: Billing export → BigQuery export"
echo "  4. Under 'Detailed usage cost', click EDIT SETTINGS"
echo "  5. Set:"
echo "       Project:  ${TARGET_PROJECT}"
echo "       Dataset:  ${DATASET}"
echo "  6. Click SAVE"
echo ""
echo "  The export table will be auto-created with a name like:"
echo "    gcp_billing_export_resource_v1_<ACCOUNT_ID_WITH_UNDERSCORES>"
echo ""
echo "  Initial backfill takes ~24 hours. After that, data arrives in ~6 hours."
echo ""
echo "  To verify after backfill:"
echo "    $0 --verify ${TARGET_PROJECT} <billing-account-id>"
echo ""
echo "ADDING TO THE BILLING UNION VIEW:"
echo ""
echo "  After the export table is populated:"
echo "  1. Add the table to vertex-ai/create-billing-union-view.sql"
echo "  2. Re-run: bq query --nouse_legacy_sql --project_id=gcid-data-core < vertex-ai/create-billing-union-view.sql"
echo "  3. If new billing account, ensure it's in billing_account_names:"
echo "     Run: ./billing-reporting/refresh-billing-account-names.sh"
echo "  4. If new Claude Code project, add row to claude_code_projects:"
echo "     INSERT INTO \`gcid-data-core.custom_sada_billing_views.claude_code_projects\`"
echo "       (project_id, project_type, user_email)"
echo "     VALUES ('<project>', '<type>', '<email_or_null>');"
