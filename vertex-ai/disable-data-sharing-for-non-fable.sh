#!/usr/bin/env bash
# Disable data sharing for non-Fable Claude models
#
# This removes the dataSharingEnabledProvider setting for Opus/Sonnet/Haiku models.
# Only Fable 5 should have data sharing enabled.
#
# Usage:
#   ./disable-data-sharing-for-non-fable.sh <project-id>

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <project-id>"
  echo ""
  echo "Example:"
  echo "  $0 coding-dpark"
  exit 1
fi

PROJECT_ID="$1"

# Models to disable (everything except Fable 5)
MODELS_TO_DISABLE=(
  "claude-opus-4-8"
  "claude-opus-4-7"
  "claude-opus-4-6"
  "claude-sonnet-4-6"
  "claude-haiku-4-5"
)

echo "Disabling data sharing for non-Fable models in ${PROJECT_ID}..."
echo "Models to disable: ${#MODELS_TO_DISABLE[@]}"
echo ""

# Get access token
ACCESS_TOKEN=$(gcloud auth print-access-token)

# Empty request body - omitting dataSharingEnabledProvider disables it
REQUEST_BODY='{"publisherModelConfig": {}}'

SUCCESS_COUNT=0
FAILED_COUNT=0

for MODEL in "${MODELS_TO_DISABLE[@]}"; do
  ENDPOINT="https://aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/global/publishers/anthropic/models/${MODEL}:setPublisherModelConfig"

  echo "Disabling ${MODEL}..."

  HTTP_CODE=$(curl -s -o /tmp/vertex-response.txt -w "%{http_code}" -X POST \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${REQUEST_BODY}" \
    "${ENDPOINT}")

  if [[ "${HTTP_CODE}" == "200" ]]; then
    echo "  ✓ Data sharing disabled"
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
echo "  Total models: ${#MODELS_TO_DISABLE[@]}"
echo "  Successful: ${SUCCESS_COUNT}"
echo "  Failed: ${FAILED_COUNT}"
echo ""

if [[ ${FAILED_COUNT} -gt 0 ]]; then
  echo "Some models failed to disable. See errors above."
  exit 1
else
  echo "✓ Data sharing disabled for all non-Fable models in ${PROJECT_ID}"
fi
