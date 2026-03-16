# STT Transcription Pipeline

## Overview

Self-service audio transcription pipeline for the Sabeti group. Users drop audio files (Zoom/Meet/Teams recordings) into a GCS bucket folder and receive timestamped transcripts with speaker labels and LLM-generated summaries. No web app — just GCS bucket interaction via Console, `gsutil`, or Google Drive.

**Project:** `sabeti-mgmt` (783046685009)
**Bucket:** `gs://sabeti-transcription`
**Region:** `us-central1`

## Architecture

```
User drops audio into gs://sabeti-transcription/speech-to-text/{subfolder}/
         |
Eventarc trigger fires on object.finalized for the bucket
         |
Cloud Function (2nd gen, HTTP-triggered, Python 3.12) receives CloudEvent
         |
Validates: path starts with speech-to-text/, audio MIME type
         |
Submits async Speech-to-Text v2 (Chirp 3) batch recognize job
         |
Polls for completion within function (up to 55 min)
         |
Writes transcript alongside input: {subfolder}/{filename}.txt
  (with timestamps + speaker labels: "[00:01:23] Speaker 1: ...")
         |
Reads SUMMARY_INSTRUCTIONS.md (subfolder override > root default)
         |
Calls Vertex AI Gemini to generate structured summary
         |
Writes summary alongside input: {subfolder}/{filename}.summary.md
         |
Deletes original audio file
         |
On error: writes {subfolder}/{filename}.error.txt (audio NOT deleted)
```

**Why HTTP-triggered:** Event-triggered Cloud Functions are capped at 540s timeout,
which is too short for long audio transcriptions. The function is deployed as
HTTP-triggered (supports 3600s) with a separate Eventarc trigger that routes GCS
`object.finalized` events to the function's HTTP endpoint.

## GCP Services

| Service | Purpose |
|---|---|
| Cloud Storage | File drop zone, transcript/summary output |
| Eventarc | Routes GCS events to Cloud Function via HTTP |
| Cloud Functions (2nd gen) | HTTP-triggered, runs transcription and summary logic |
| Speech-to-Text v2 | Transcription via Chirp 3 model |
| Vertex AI (Gemini) | LLM summary generation |
| Cloud Build | Builds and deploys the function |

## Bucket Layout

```
gs://sabeti-transcription/
  speech-to-text/
    SUMMARY_INSTRUCTIONS.md            <-- default LLM prompt
    meeting.mp3                        <-- root-level files also processed
    meeting.txt                        <-- raw transcript (auto-generated)
    meeting.summary.md                 <-- LLM summary (auto-generated)
    dpark/
      standup-2025-03-15.mp3           <-- user drops audio here
      standup-2025-03-15.txt           <-- raw transcript (auto)
      standup-2025-03-15.summary.md    <-- LLM summary (auto)
      SUMMARY_INSTRUCTIONS.md          <-- optional per-folder override
    team-epi/
      interview.wav
      interview.txt
      interview.summary.md
      interview.error.txt              <-- on failure (audio preserved)
```

## How to Use

### Upload via gsutil/gcloud

```bash
# Upload to your subfolder
gcloud storage cp recording.mp3 gs://sabeti-transcription/speech-to-text/yourname/

# Upload to root
gcloud storage cp recording.mp3 gs://sabeti-transcription/speech-to-text/

# Check results (wait a few minutes for short recordings)
gcloud storage ls gs://sabeti-transcription/speech-to-text/yourname/
gcloud storage cat gs://sabeti-transcription/speech-to-text/yourname/recording.txt
gcloud storage cat gs://sabeti-transcription/speech-to-text/yourname/recording.summary.md
```

### Upload via Google Cloud Console

1. Navigate to [Cloud Storage Browser](https://console.cloud.google.com/storage/browser/sabeti-transcription/speech-to-text)
2. Click into your subfolder (or create one)
3. Click "Upload Files" and select your audio file
4. Wait for processing — transcript and summary will appear alongside the input

## Supported Audio Formats

| Format | MIME Type |
|---|---|
| MP3 | `audio/mpeg`, `audio/mp3` |
| WAV | `audio/wav`, `audio/x-wav` |
| FLAC | `audio/flac`, `audio/x-flac` |
| M4A | `audio/m4a`, `audio/x-m4a` |
| MP4 Audio | `audio/mp4` |
| MP4 Video | `video/mp4` |
| OGG | `audio/ogg` |
| WebM | `audio/webm`, `video/webm` |

## Configuration

Environment variables on the Cloud Function:

| Variable | Default | Description |
|---|---|---|
| `GCP_PROJECT` | `sabeti-mgmt` | GCP project ID |
| `STT_MODEL` | `chirp_2` | Speech-to-Text model (`chirp_2` recommended; `chirp_3` limited to 20 min audio) |
| `STT_REGION` | `us-central1` | Region for STT API endpoint |
| `SUMMARY_MODEL` | `gemini-2.5-flash` | Vertex AI model for summaries (via `google-genai` SDK) |
| `VERTEX_REGION` | `us-central1` | Region for Vertex AI Gemini API |

## Customizing Summary Instructions

The LLM prompt is stored as `SUMMARY_INSTRUCTIONS.md` in the bucket, not in code. Edit it anytime without redeploying:

```bash
# Download, edit, re-upload
gcloud storage cp gs://sabeti-transcription/speech-to-text/SUMMARY_INSTRUCTIONS.md .
# ... edit the file ...
gcloud storage cp SUMMARY_INSTRUCTIONS.md gs://sabeti-transcription/speech-to-text/

# Per-folder override
gcloud storage cp my-custom-instructions.md \
  gs://sabeti-transcription/speech-to-text/yourfolder/SUMMARY_INSTRUCTIONS.md
```

## Cost Estimate

| Component | Cost per hour of audio |
|---|---|
| Speech-to-Text v2 (Chirp 3) | ~$1.44 |
| Vertex AI Gemini Flash (summary) | ~$0.01 |
| Cloud Functions compute | Negligible |
| Cloud Storage | Negligible |

First 60 minutes of STT per month are free.

## Troubleshooting

### Check function logs

```bash
gcloud functions logs read stt-transcribe --gen2 --project=sabeti-mgmt --region=us-central1 --limit=50
```

### File not being processed

- Verify the file is under `speech-to-text/` prefix
- Check the file has an audio/video MIME type (not `application/octet-stream`)
- Re-upload with explicit content type: `gcloud storage cp --content-type=audio/mpeg file.mp3 gs://...`

### Error file appeared

- Read the `.error.txt` file for details
- The original audio is preserved on error — fix the issue and re-upload

### Summary missing but transcript exists

- Check logs for summary generation errors
- Verify `SUMMARY_INSTRUCTIONS.md` exists in the bucket
- Summary failures are non-fatal — the transcript is still delivered

## Infrastructure

- **Cloud Function:** `stt-transcribe` (2nd gen, HTTP-triggered, Python 3.12, us-central1, 3600s timeout)
- **Eventarc Trigger:** `stt-transcribe-trigger` (routes GCS object.finalized to function)
- **Service Account:** `stt-pipeline-sa@sabeti-mgmt.iam.gserviceaccount.com`
- **Bucket:** `gs://sabeti-transcription` (uniform bucket-level access)
- **User Group:** `sabetilab@broadinstitute.org` (Storage Object User on bucket)
- **Lifecycle:** Auto-delete audio files older than 7 days (safety net)

## Known Limitations

- **60-minute function timeout:** Recordings longer than ~2 hours may time out during transcription
- **Chirp 2 — no speaker diarization:** The default model (`chirp_2`) does not support speaker labels. Chirp 3 supports diarization but is limited to audio files under 20 minutes.
- **English only** by default (configurable in code via `language_codes`)
- **Max 3 concurrent function instances** to avoid STT API quota issues
