#!/usr/bin/env bash
# Deploy Opus 4.8 support to BigQuery views
#
# This script updates the Claude Code billing views to recognize Opus 4.8
# model usage in both audit logs and billing SKUs.
#
# Run from the gcp-provisioning root directory:
#   ./vertex-ai/deploy-opus-4.8-support.sh

set -euo pipefail

PROJECT_ID="gcid-data-core"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================="
echo "Deploying Opus 4.8 Support to BigQuery"
echo "========================================="
echo ""
echo "This will update the following views:"
echo "  - claude_code_audit_logs"
echo "  - claude_code_daily_usage"
echo "  - claude_code_user_costs"
echo ""

# Check if bq command is available
if ! command -v bq &> /dev/null; then
    echo "ERROR: bq command not found. Install Google Cloud SDK first."
    exit 1
fi

# Verify we can access the project
echo "Verifying access to project ${PROJECT_ID}..."
if ! bq ls --project_id="${PROJECT_ID}" custom_sada_billing_views &> /dev/null; then
    echo "ERROR: Cannot access ${PROJECT_ID}.custom_sada_billing_views"
    echo "Make sure you have run 'gcloud auth login' and have appropriate permissions."
    exit 1
fi

echo "✓ Access verified"
echo ""

# Update audit views (creates claude_code_audit_logs and claude_code_daily_usage)
echo "Step 1/2: Updating audit log views..."
bq query \
  --nouse_legacy_sql \
  --project_id="${PROJECT_ID}" \
  < "${SCRIPT_DIR}/create-audit-views.sql"

if [ $? -eq 0 ]; then
    echo "✓ Audit views updated successfully"
else
    echo "✗ Failed to update audit views"
    exit 1
fi

echo ""

# Update user costs view
echo "Step 2/2: Updating user costs view..."
bq query \
  --nouse_legacy_sql \
  --project_id="${PROJECT_ID}" \
  < "${SCRIPT_DIR}/create-user-costs-view.sql"

if [ $? -eq 0 ]; then
    echo "✓ User costs view updated successfully"
else
    echo "✗ Failed to update user costs view"
    exit 1
fi

echo ""
echo "========================================="
echo "Deployment Complete!"
echo "========================================="
echo ""
echo "The following views now support Opus 4.8:"
echo "  - gcid-data-core.custom_sada_billing_views.claude_code_audit_logs"
echo "  - gcid-data-core.custom_sada_billing_views.claude_code_daily_usage"
echo "  - gcid-data-core.custom_sada_billing_views.claude_code_user_costs"
echo ""
echo "Opus 4.8 usage will now be tracked under the 'opus-4.8' model_family."
echo ""
echo "Looker Studio dashboards will automatically reflect Opus 4.8 usage"
echo "as soon as users start generating charges on the model."
echo ""
