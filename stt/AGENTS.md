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
Validates: path starts with speech-to-text/, audio/video MIME type
         |
Transcribes audio (default: Gemini 3.1 Pro multimodal)
  - Gemini models: single API call with speaker diarization + named speakers
  - Cloud STT models (chirp_2/chirp_3): async batch job with polling
         |
Writes transcript alongside input: {subfolder}/{filename}.txt
  (with timestamps + speaker labels: "[00:01:23] Pardis: ...")
         |
Reads SUMMARY_INSTRUCTIONS.md (subfolder override > root default)
         |
Calls Vertex AI Gemini Flash to generate structured summary
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

## Transcription Backends

The `STT_MODEL` env var selects the transcription backend:

| Model | Backend | Speaker Labels | Max Audio | Notes |
|---|---|---|---|---|
| `gemini-3.1-pro-preview` | Gemini multimodal | Yes (named) | ~9.5 hrs | **Default.** Identifies speakers by name from context |
| `gemini-2.5-pro` | Gemini multimodal | Yes (named) | ~9.5 hrs | Stable alternative |
| `chirp_2` | Cloud STT v2 | No | Hours | Fallback for long audio |
| `chirp_3` | Cloud STT v2 | Yes (Speaker 1/2/...) | 20 min | Limited audio length |

Gemini models use `location='global'` on Vertex AI. Cloud STT models use the regional
endpoint configured via `STT_REGION`.

## GCP Services

| Service | Purpose |
|---|---|
| Cloud Storage | File drop zone, transcript/summary output |
| Eventarc | Routes GCS events to Cloud Function via HTTP |
| Cloud Functions (2nd gen) | HTTP-triggered, runs transcription and summary logic |
| Vertex AI (Gemini) | Transcription (multimodal) and summary generation |
| Speech-to-Text v2 | Alternative transcription backend (chirp_2/chirp_3) |
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

# Check results (wait ~8 minutes for a 1-hour recording)
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
| `STT_MODEL` | `gemini-3.1-pro-preview` | Transcription model (see Transcription Backends table) |
| `STT_REGION` | `us-central1` | Region for Cloud STT endpoint (ignored for Gemini models) |
| `SUMMARY_MODEL` | `gemini-2.5-flash` | Vertex AI model for summaries (via `google-genai` SDK) |
| `VERTEX_REGION` | `us-central1` | Region for Vertex AI summary API |

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
| Gemini 3.1 Pro (transcription) | ~$0.40 |
| Gemini 2.5 Flash (summary) | ~$0.01 |
| Cloud Functions compute | Negligible |
| Cloud Storage | Negligible |

Alternative: Cloud STT v2 (Chirp 2) costs ~$1.44/hr (first 60 min/month free).

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

- **60-minute function timeout:** Very long recordings (>2 hours) may time out
- **Gemini timestamp accuracy:** Timestamps from Gemini models are approximate (not frame-accurate like dedicated STT)
- **English only** by default (Gemini handles multilingual automatically; Cloud STT configurable via `language_codes`)
- **Max 3 concurrent function instances** to avoid API quota issues
- **Gemini preview models:** `gemini-3.1-pro-preview` requires `location='global'` and may change with model updates
