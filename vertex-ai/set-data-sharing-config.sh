#!/usr/bin/env bash
# Set PublisherModelConfig.data_sharing_enabled_provider to 'anthropic' for GCP projects
#
# This sets the config for all Claude models on Vertex AI. You can optionally specify
# a single model, or it will loop through common models.
#
# Usage:
#   ./set-data-sharing-config.sh <project-id> [model-id]
#
# Example:
#   ./set-data-sharing-config.sh coding-dpark
#   ./set-data-sharing-config.sh coding-dpark claude-fable-5

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <project-id> [model-id]"
  echo ""
  echo "Example:"
  echo "  $0 coding-dpark"
  echo "  $0 coding-dpark claude-fable-5"
  exit 1
fi

PROJECT_ID="$1"
SINGLE_MODEL="${2:-}"

# Only enable for Fable 5 - do NOT enable for Opus/Sonnet/Haiku
MODELS=(
  "claude-fable-5"
)

# If a single model was specified, only process that one
if [[ -n "${SINGLE_MODEL}" ]]; then
  MODELS=("${SINGLE_MODEL}")
fi

echo "Setting data_sharing_enabled_provider for ${PROJECT_ID}..."
echo "Models to configure: ${#MODELS[@]}"
echo ""

# Get access token
ACCESS_TOKEN=$(gcloud auth print-access-token)

# Request body
REQUEST_BODY='{
  "publisherModelConfig": {
    "dataSharingEnabledProvider": "anthropic"
  }
}'

SUCCESS_COUNT=0
FAILED_COUNT=0

for MODEL in "${MODELS[@]}"; do
  # API endpoint - note: uses 'global' location and v1beta1
  ENDPOINT="https://aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/global/publishers/anthropic/models/${MODEL}:setPublisherModelConfig"

  echo "Configuring ${MODEL}..."

  # Make the API call
  HTTP_CODE=$(curl -s -o /tmp/vertex-response.txt -w "%{http_code}" -X POST \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${REQUEST_BODY}" \
    "${ENDPOINT}")

  if [[ "${HTTP_CODE}" == "200" ]]; then
    echo "  ✓ Success"
    ((SUCCESS_COUNT++))
  else
    echo "  ✗ Failed (HTTP ${HTTP_CODE})"
    cat /tmp/vertex-response.txt
    echo ""
    ((FAILED_COUNT++))
  fi
done

echo ""
echo "=========================================="
echo "Summary:"
echo "  Total models: ${#MODELS[@]}"
echo "  Successful: ${SUCCESS_COUNT}"
echo "  Failed: ${FAILED_COUNT}"
echo ""

if [[ ${FAILED_COUNT} -gt 0 ]]; then
  echo "Some models failed to configure. See errors above."
  exit 1
else
  echo "✓ All models configured successfully for ${PROJECT_ID}"
fi
