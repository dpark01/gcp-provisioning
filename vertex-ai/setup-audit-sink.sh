#!/usr/bin/env bash
# Sets up audit log routing for a shared Claude Code project.
#
# This script:
#   1. Enables Data Access audit logging for Vertex AI on the target project
#   2. Creates a log sink that routes Claude/Anthropic API audit logs
#      to the central BigQuery dataset in gcid-data-core
#   3. Grants the sink's service account write access to the BQ dataset
#
# Prerequisites:
#   - gcloud CLI authenticated with sufficient permissions
#   - Target project must exist
#   - You must have roles/logging.configWriter on the target project
#   - You must have roles/bigquery.dataOwner on gcid-data-core:billing_export
#
# After running this script, also add the project to the mapping table:
#   INSERT INTO `gcid-data-core.custom_sada_billing_views.claude_code_projects`
#     (project_id, project_type, user_email, billing_account_id, funding_source, enabled_date)
#   VALUES ('PROJECT_ID', 'shared', NULL, 'BILLING_ACCT_ID', 'SOURCE_NAME', CURRENT_DATE());
#
# Usage:
#   ./setup-audit-sink.sh <project-id>
#
# Example:
#   ./setup-audit-sink.sh sabeti-ai

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
CENTRAL_PROJECT="gcid-data-core"
CENTRAL_DATASET="billing_export"
SINK_NAME="claude-code-audit-logs"

# ============================================================================
# Argument validation
# ============================================================================
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <project-id>"
  echo ""
  echo "Sets up audit log routing for a shared Claude Code project."
  echo "Routes Vertex AI / Anthropic audit logs to:"
  echo "  ${CENTRAL_PROJECT}.${CENTRAL_DATASET}"
  exit 1
fi

TARGET_PROJECT="$1"

echo "=== Claude Code Audit Log Sink Setup ==="
echo "Target project:     ${TARGET_PROJECT}"
echo "Central BQ dataset: ${CENTRAL_PROJECT}.${CENTRAL_DATASET}"
echo "Sink name:          ${SINK_NAME}"
echo ""

# ============================================================================
# Step 1: Verify the target project exists and is accessible
# ============================================================================
echo "Step 1: Verifying project ${TARGET_PROJECT}..."
if ! gcloud projects describe "${TARGET_PROJECT}" --format='value(projectId)' > /dev/null 2>&1; then
  echo "ERROR: Cannot access project '${TARGET_PROJECT}'. Check that it exists and you have access."
  exit 1
fi
echo "  Project verified."
echo ""

# ============================================================================
# Step 2: Enable Data Access audit logs for Vertex AI
# ============================================================================
echo "Step 2: Enabling Data Access audit logs for Vertex AI..."

CURRENT_POLICY=$(gcloud projects get-iam-policy "${TARGET_PROJECT}" --format=json 2>/dev/null)

if echo "${CURRENT_POLICY}" | grep -q 'aiplatform.googleapis.com'; then
  echo "  Vertex AI audit logging already enabled."
else
  echo "  Enabling Vertex AI DATA_READ and DATA_WRITE audit logs..."
  POLICY_FILE=$(mktemp /tmp/audit-policy.XXXXXX.json)
  trap 'rm -f "${POLICY_FILE}"' EXIT

  echo "${CURRENT_POLICY}" | jq '
    .auditConfigs += [{
      "service": "aiplatform.googleapis.com",
      "auditLogConfigs": [
        {"logType": "DATA_READ"},
        {"logType": "DATA_WRITE"}
      ]
    }]
  ' > "${POLICY_FILE}"

  gcloud projects set-iam-policy "${TARGET_PROJECT}" "${POLICY_FILE}" --format=none
  echo "  Audit logging enabled."
fi
echo ""

# ============================================================================
# Step 3: Create log sink for Claude/Anthropic API calls
# ============================================================================
echo "Step 3: Creating log sink '${SINK_NAME}'..."

if gcloud logging sinks describe "${SINK_NAME}" --project="${TARGET_PROJECT}" > /dev/null 2>&1; then
  echo "  Sink '${SINK_NAME}' already exists. Updating..."
  SINK_CMD="update"
else
  echo "  Creating new sink..."
  SINK_CMD="create"
fi

gcloud logging sinks ${SINK_CMD} "${SINK_NAME}" \
  "bigquery.googleapis.com/projects/${CENTRAL_PROJECT}/datasets/${CENTRAL_DATASET}" \
  --project="${TARGET_PROJECT}" \
  --log-filter='resource.type="audited_resource"
    protoPayload.serviceName="aiplatform.googleapis.com"
    protoPayload.resourceName:"anthropic"'

echo "  Sink configured."
echo ""

# ============================================================================
# Step 4: Grant the sink's service account BigQuery write access
# ============================================================================
echo "Step 4: Granting BigQuery access to sink service account..."

SINK_SA=$(gcloud logging sinks describe "${SINK_NAME}" \
  --project="${TARGET_PROJECT}" \
  --format='value(writerIdentity)')

echo "  Sink service account: ${SINK_SA}"
echo "  Granting roles/bigquery.dataEditor on ${CENTRAL_PROJECT}:${CENTRAL_DATASET}..."

gcloud projects add-iam-policy-binding "${CENTRAL_PROJECT}" \
  --member="${SINK_SA}" \
  --role="roles/bigquery.dataEditor" \
  --condition=None \
  --format=none \
  --quiet

echo "  Access granted."
echo ""

# ============================================================================
# Step 5: Verify the sink
# ============================================================================
echo "Step 5: Verification..."
echo ""
gcloud logging sinks describe "${SINK_NAME}" \
  --project="${TARGET_PROJECT}" \
  --format='table(name,destination,filter)'

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Audit logs from ${TARGET_PROJECT} will now route to:"
echo "  ${CENTRAL_PROJECT}.${CENTRAL_DATASET}.cloudaudit_googleapis_com_data_access_*"
echo ""
echo "NEXT STEPS:"
echo "  1. Add the project to the mapping table (if not already done):"
echo "     INSERT INTO \`gcid-data-core.custom_sada_billing_views.claude_code_projects\`"
echo "       (project_id, project_type, user_email, billing_account_id, funding_source, enabled_date)"
echo "     VALUES ('${TARGET_PROJECT}', 'shared', NULL, 'BILLING_ACCT_ID', 'SOURCE_NAME', CURRENT_DATE());"
echo ""
echo "  2. Wait ~5 minutes for the first audit log entries to appear."
echo ""
echo "  3. Verify with:"
echo "     bq query --nouse_legacy_sql \\"
echo "       \"SELECT COUNT(*) FROM \\\`${CENTRAL_PROJECT}.${CENTRAL_DATASET}.cloudaudit_googleapis_com_data_access_*\\\`"
echo "        WHERE resource.labels.project_id = '${TARGET_PROJECT}'"
echo "        AND protopayload_auditlog.resourceName LIKE '%anthropic%'\""
