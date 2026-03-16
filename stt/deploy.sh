#!/usr/bin/env bash
set -euo pipefail

# STT Transcription Pipeline - Deployment Script
#
# Prerequisites:
#   - gcloud CLI authenticated with sufficient permissions
#   - Speech-to-Text, Storage, and AI Platform APIs already enabled
#
# Usage:
#   ./deploy.sh                    # Run all steps
#   ./deploy.sh --step apis        # Run a specific step
#   ./deploy.sh --step bucket
#   ./deploy.sh --step lifecycle
#   ./deploy.sh --step sa
#   ./deploy.sh --step iam
#   ./deploy.sh --step eventarc
#   ./deploy.sh --step instructions
#   ./deploy.sh --step function

PROJECT="sabeti-mgmt"
PROJECT_NUMBER="783046685009"
REGION="us-central1"
BUCKET="sabeti-transcription"
SA_NAME="stt-pipeline-sa"
SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
FUNCTION_NAME="stt-transcribe"
USER_GROUP="sabetilab@broadinstitute.org"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

step="${1:-all}"
if [[ "$step" == "--step" ]]; then
  step="${2:?Usage: $0 --step <apis|bucket|lifecycle|sa|iam|eventarc|instructions|function>}"
fi

run_step() {
  [[ "$step" == "all" || "$step" == "$1" ]]
}

# --- Step 1: Enable APIs ---
if run_step "apis"; then
  echo "==> Enabling APIs..."
  gcloud services enable \
    cloudfunctions.googleapis.com \
    eventarc.googleapis.com \
    run.googleapis.com \
    cloudbuild.googleapis.com \
    --project="$PROJECT"
  echo "    Done."
fi

# --- Step 2: Create bucket ---
if run_step "bucket"; then
  echo "==> Creating GCS bucket..."
  if gcloud storage buckets describe "gs://$BUCKET" --project="$PROJECT" 2>/dev/null; then
    echo "    Bucket already exists."
  else
    gcloud storage buckets create "gs://$BUCKET" \
      --project="$PROJECT" \
      --location="$REGION" \
      --uniform-bucket-level-access
  fi

  # Create placeholder for speech-to-text/ prefix
  echo "" | gcloud storage cp - "gs://$BUCKET/speech-to-text/.keep"
  echo "    Done."
fi

# --- Step 3: Set lifecycle rules ---
if run_step "lifecycle"; then
  echo "==> Setting lifecycle rules (auto-delete audio after 7 days)..."
  cat > /tmp/stt-lifecycle.json << 'EOF'
{
  "lifecycle": {
    "rule": [{
      "action": {"type": "Delete"},
      "condition": {
        "age": 7,
        "matchesPrefix": ["speech-to-text/"],
        "matchesSuffix": [".mp3", ".wav", ".flac", ".mp4", ".ogg", ".webm", ".m4a"]
      }
    }]
  }
}
EOF

  gcloud storage buckets update "gs://$BUCKET" \
    --lifecycle-file=/tmp/stt-lifecycle.json
  rm /tmp/stt-lifecycle.json
  echo "    Done."
fi

# --- Step 4: Create service account ---
if run_step "sa"; then
  echo "==> Creating service account..."
  gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT" 2>/dev/null || \
    gcloud iam service-accounts create "$SA_NAME" \
      --project="$PROJECT" \
      --display-name="STT Pipeline Service Account"

  # Storage object admin on the bucket
  gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/storage.objectAdmin"

  # Speech-to-Text editor
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/speech.editor" \
    --condition=None \
    --quiet

  # Vertex AI user (for Gemini summary)
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/aiplatform.user" \
    --condition=None \
    --quiet

  echo "    Done."
fi

# --- Step 5: Grant user group access ---
if run_step "iam"; then
  echo "==> Granting user group bucket access..."
  gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" \
    --member="group:${USER_GROUP}" \
    --role="roles/storage.objectUser"
  echo "    Done."
fi

# --- Step 6: Grant Eventarc permissions ---
if run_step "eventarc"; then
  echo "==> Granting Eventarc permissions..."

  # GCS service agent needs Pub/Sub publisher for Eventarc GCS triggers.
  # The agent may not exist until storage API is used; create it explicitly.
  gcloud storage service-agent --project="$PROJECT" 2>/dev/null || true
  GCS_SA="service-${PROJECT_NUMBER}@gs-project-accounts.iam.gserviceaccount.com"

  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:${GCS_SA}" \
    --role="roles/pubsub.publisher" \
    --condition=None \
    --quiet

  # The trigger's SA needs run.invoker and eventarc.eventReceiver
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/run.invoker" \
    --condition=None \
    --quiet

  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/eventarc.eventReceiver" \
    --condition=None \
    --quiet

  echo "    Done."
fi

# --- Step 7: Upload summary instructions ---
if run_step "instructions"; then
  echo "==> Uploading SUMMARY_INSTRUCTIONS.md to bucket..."
  gcloud storage cp "$SCRIPT_DIR/SUMMARY_INSTRUCTIONS.md" \
    "gs://$BUCKET/speech-to-text/SUMMARY_INSTRUCTIONS.md"
  echo "    Done."
fi

# --- Step 8: Deploy Cloud Function (HTTP) + Eventarc trigger ---
# Event-triggered Cloud Functions are capped at 540s timeout, too short for
# long STT jobs. Instead, deploy as HTTP-triggered (supports 3600s) with a
# separate Eventarc trigger that routes GCS events to the function URL.
if run_step "function"; then
  echo "==> Deploying Cloud Function (HTTP-triggered)..."
  gcloud functions deploy "$FUNCTION_NAME" \
    --gen2 \
    --project="$PROJECT" \
    --region="$REGION" \
    --runtime=python312 \
    --source="$SCRIPT_DIR/cloud-function" \
    --entry-point=transcribe_audio \
    --trigger-http \
    --no-allow-unauthenticated \
    --service-account="$SA_EMAIL" \
    --set-env-vars="GCP_PROJECT=${PROJECT},STT_MODEL=chirp_3,STT_REGION=${REGION},SUMMARY_MODEL=gemini-2.0-flash" \
    --timeout=3600s \
    --memory=512Mi \
    --max-instances=3

  echo "==> Creating Eventarc trigger..."
  # Delete existing trigger if present (idempotent)
  gcloud eventarc triggers delete "$FUNCTION_NAME-trigger" \
    --project="$PROJECT" --location="$REGION" --quiet 2>/dev/null || true

  FUNCTION_URL=$(gcloud functions describe "$FUNCTION_NAME" \
    --gen2 --project="$PROJECT" --region="$REGION" \
    --format='value(serviceConfig.uri)')

  gcloud eventarc triggers create "$FUNCTION_NAME-trigger" \
    --project="$PROJECT" \
    --location="$REGION" \
    --destination-run-service="$FUNCTION_NAME" \
    --destination-run-region="$REGION" \
    --event-filters="type=google.cloud.storage.object.v1.finalized" \
    --event-filters="bucket=$BUCKET" \
    --service-account="$SA_EMAIL"

  # Eventarc creates a Pub/Sub subscription with 10s ack deadline by default.
  # For long-running STT jobs, increase to 600s (max) to prevent redelivery.
  echo "==> Updating Pub/Sub ack deadline..."
  TRIGGER_SUB=$(gcloud eventarc triggers describe "$FUNCTION_NAME-trigger" \
    --project="$PROJECT" --location="$REGION" \
    --format='value(transport.pubsub.subscription)' | sed 's|.*/||')
  gcloud pubsub subscriptions update "$TRIGGER_SUB" \
    --ack-deadline=600 --project="$PROJECT"

  echo "    Done."
fi

echo ""
echo "=== Deployment complete ==="
echo ""
echo "Verification steps:"
echo "  1. Upload test audio:  gcloud storage cp test.mp3 gs://$BUCKET/speech-to-text/"
echo "  2. Watch logs:         gcloud functions logs read $FUNCTION_NAME --gen2 --project=$PROJECT --region=$REGION --limit=50"
echo "  3. Check outputs:      gcloud storage ls gs://$BUCKET/speech-to-text/"
echo "  4. Read transcript:    gcloud storage cat gs://$BUCKET/speech-to-text/test.txt"
echo "  5. Read summary:       gcloud storage cat gs://$BUCKET/speech-to-text/test.summary.md"
