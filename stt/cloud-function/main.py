"""Cloud Function to transcribe audio files and generate LLM summaries.

Triggered by Eventarc on object.finalized in the sabeti-transcription bucket.
Processes audio files under speech-to-text/ prefix:
  1. Transcribes audio (via Cloud STT or Gemini multimodal) with timestamps
  2. Writes timestamped transcript as .txt alongside input
  3. Generates LLM summary via Vertex AI Gemini, writes as .summary.md
  4. Deletes original audio file on success

STT_MODEL options:
  - chirp_2: Cloud STT v2, no speaker diarization, handles long audio
  - chirp_3: Cloud STT v2 with diarization, limited to 20 min audio
  - gemini-*: Gemini multimodal transcription with speaker diarization
"""

import os
import time

import functions_framework
from google.api_core.client_options import ClientOptions
from google.cloud import speech_v2, storage

PROJECT_ID = os.environ.get("GCP_PROJECT", "sabeti-mgmt")
STT_MODEL = os.environ.get("STT_MODEL", "chirp_2")
STT_REGION = os.environ.get("STT_REGION", "us-central1")
SUMMARY_MODEL = os.environ.get("SUMMARY_MODEL", "gemini-2.5-flash")
VERTEX_REGION = os.environ.get("VERTEX_REGION", "us-central1")

PREFIX = "speech-to-text/"
INSTRUCTIONS_FILE = "SUMMARY_INSTRUCTIONS.md"

POLL_INTERVAL_SECONDS = 15
MAX_WAIT_SECONDS = 3300  # 55 minutes — under the 60 min function timeout


def format_timestamp(seconds):
    """Format seconds as [HH:MM:SS]."""
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    secs = int(seconds % 60)
    return f"[{hours:02d}:{minutes:02d}:{secs:02d}]"


def build_transcript(result):
    """Build timestamped, speaker-labeled transcript from STT result."""
    lines = []
    for file_result in result.results.values():
        for result_item in file_result.transcript.results:
            if not result_item.alternatives:
                continue
            alt = result_item.alternatives[0]

            # Get timestamp from result_end_offset (end of this segment)
            offset = result_item.result_end_offset
            timestamp_secs = offset.total_seconds() if offset else 0

            # Get speaker tag from words if available
            speaker_tag = None
            if alt.words:
                speaker_tag = alt.words[0].speaker_label

            timestamp = format_timestamp(timestamp_secs)
            text = alt.transcript.strip()
            if not text:
                continue

            if speaker_tag:
                lines.append(f"{timestamp} {speaker_tag}: {text}")
            else:
                lines.append(f"{timestamp} {text}")

    return "\n".join(lines)


TRANSCRIPTION_PROMPT = """\
Transcribe this audio recording verbatim with timestamps and speaker labels.

Rules:
- Label each speaker consistently (Speaker 1, Speaker 2, etc.). If you can \
identify a speaker's name from context (e.g. someone says "Thanks, Sarah"), \
use their name for all subsequent lines.
- Add timestamps in [HH:MM:SS] format at the start of each speaker turn or \
every 30-60 seconds within long turns.
- Remove filler words (um, uh, like, you know) and false starts.
- Preserve technical terms, names, and acronyms exactly as spoken.
- Do NOT summarize or paraphrase — transcribe what was said.
- Do NOT add any preamble, commentary, or explanation — output only the transcript.

Output format (one line per segment):
[00:01:23] Speaker 1: Good morning everyone, let's get started.
[00:01:30] Speaker 2: Thanks for setting this up.
"""

# Map common GCS content types to Gemini-compatible MIME types.
# Gemini accepts: audio/wav, audio/mp3, audio/flac, audio/aiff, audio/aac, audio/ogg
GEMINI_MIME_MAP = {
    "audio/mpeg": "audio/mp3",
    "audio/mp4": "audio/mp3",
    "audio/mp4a-latm": "audio/mp3",
    "audio/x-wav": "audio/wav",
    "audio/x-flac": "audio/flac",
    "audio/m4a": "audio/mp3",
    "audio/x-m4a": "audio/mp3",
    "audio/webm": "audio/ogg",
    "video/mp4": "audio/mp3",
    "video/webm": "audio/ogg",
}


def transcribe_with_cloud_stt(gcs_uri):
    """Transcribe audio using Cloud Speech-to-Text v2 (chirp_2/chirp_3)."""
    if STT_REGION == "global":
        speech_client = speech_v2.SpeechClient()
    else:
        api_endpoint = f"{STT_REGION}-speech.googleapis.com"
        speech_client = speech_v2.SpeechClient(
            client_options=ClientOptions(api_endpoint=api_endpoint)
        )
    print(f"  STT region: {STT_REGION}")

    recognizer = f"projects/{PROJECT_ID}/locations/{STT_REGION}/recognizers/_"

    features_kwargs = {
        "enable_automatic_punctuation": True,
        "enable_word_time_offsets": True,
    }
    # Speaker diarization via BatchRecognize:
    # - chirp_3: empty SpeakerDiarizationConfig() (but limited to 20 min audio)
    # - chirp_2: not supported (diarization only available on chirp_3)
    if STT_MODEL in ("chirp_3",):
        features_kwargs["diarization_config"] = speech_v2.SpeakerDiarizationConfig()

    config = speech_v2.RecognitionConfig(
        auto_decoding_config=speech_v2.AutoDetectDecodingConfig(),
        model=STT_MODEL,
        language_codes=["en-US"],
        features=speech_v2.RecognitionFeatures(**features_kwargs),
    )

    request = speech_v2.BatchRecognizeRequest(
        recognizer=recognizer,
        config=config,
        files=[speech_v2.BatchRecognizeFileMetadata(uri=gcs_uri)],
        recognition_output_config=speech_v2.RecognitionOutputConfig(
            inline_response_config=speech_v2.InlineOutputConfig(),
        ),
    )

    operation = speech_client.batch_recognize(request=request)
    print(f"  STT job submitted: {operation.operation.name}")

    elapsed = 0
    while not operation.done():
        if elapsed >= MAX_WAIT_SECONDS:
            raise TimeoutError(f"STT job timed out after {elapsed}s")
        time.sleep(POLL_INTERVAL_SECONDS)
        elapsed += POLL_INTERVAL_SECONDS
        print(f"  Waiting for STT job... {elapsed}s elapsed")

    result = operation.result()

    # Check for per-file errors in the batch result
    for uri, file_result in result.results.items():
        if file_result.error and file_result.error.code:
            raise ValueError(
                f"STT error for {uri}: {file_result.error.message}"
            )

    return build_transcript(result)


def transcribe_with_gemini(gcs_uri, content_type):
    """Transcribe audio using Gemini multimodal (speaker diarization included)."""
    from google import genai
    from google.genai import types

    # Map to a MIME type Gemini accepts
    mime_type = GEMINI_MIME_MAP.get(content_type, content_type)

    # Gemini preview models require location='global' on Vertex AI
    client = genai.Client(vertexai=True, project=PROJECT_ID, location="global")
    response = client.models.generate_content(
        model=STT_MODEL,
        contents=[
            types.Part.from_uri(file_uri=gcs_uri, mime_type=mime_type),
            TRANSCRIPTION_PROMPT,
        ],
    )
    return response.text


def read_instructions(storage_client, bucket_name, subfolder):
    """Read SUMMARY_INSTRUCTIONS.md with fallback: subfolder > root."""
    bucket = storage_client.bucket(bucket_name)

    paths_to_try = []
    if subfolder:
        paths_to_try.append(f"{PREFIX}{subfolder}/{INSTRUCTIONS_FILE}")
    paths_to_try.append(f"{PREFIX}{INSTRUCTIONS_FILE}")

    for path in paths_to_try:
        blob = bucket.blob(path)
        if blob.exists():
            print(f"Using instructions from gs://{bucket_name}/{path}")
            return blob.download_as_text()

    return None


def generate_summary(transcript_text, instructions):
    """Call Vertex AI Gemini to generate a summary."""
    from google import genai
    from google.genai import types

    client = genai.Client(vertexai=True, project=PROJECT_ID, location=VERTEX_REGION)
    response = client.models.generate_content(
        model=SUMMARY_MODEL,
        contents=transcript_text,
        config=types.GenerateContentConfig(
            system_instruction=instructions,
        ),
    )
    return response.text


@functions_framework.http
def transcribe_audio(request):
    """Main entry point: transcribe audio and generate summary.

    Deployed as HTTP-triggered function to support 3600s timeout (event-triggered
    functions are capped at 540s). Eventarc routes GCS object.finalized events
    here as CloudEvents over HTTP.
    """
    # Parse CloudEvent from Eventarc HTTP request.
    # Eventarc sends GCS events as CloudEvents with the storage object data
    # nested under the "data" key of the JSON body (or under "message.data"
    # for Pub/Sub-wrapped events).
    body = request.get_json(silent=True)
    if not body:
        return "Bad Request: no JSON payload", 400

    # CloudEvent format: event data is in body directly or under "data"
    if "bucket" in body:
        data = body
    elif "data" in body:
        data = body["data"]
    elif "message" in body and "data" in body["message"]:
        # Pub/Sub wrapped format
        import base64
        import json
        raw = base64.b64decode(body["message"]["data"])
        data = json.loads(raw)
    else:
        data = body

    bucket_name = data.get("bucket", "")
    object_name = data.get("name", "")
    content_type = data.get("contentType", "")

    if not bucket_name or not object_name:
        return "Bad Request: missing bucket or name", 400

    # Only process files under speech-to-text/ prefix
    if not object_name.startswith(PREFIX):
        print(f"Ignoring {object_name} — not under {PREFIX}")
        return "OK", 200

    # Ignore placeholder/folder objects and output files
    if object_name.endswith("/") or object_name.endswith(".keep"):
        return "OK", 200
    if object_name.endswith(".txt") or object_name.endswith(".md"):
        return "OK", 200

    # Check MIME type — accept any audio/* or video/* type
    if not content_type.startswith("audio/") and not content_type.startswith("video/"):
        print(f"Ignoring {object_name} — unsupported MIME type: {content_type}")
        return "OK", 200

    print(f"Processing: gs://{bucket_name}/{object_name} ({content_type})")

    # Parse path components
    # object_name = "speech-to-text/dpark/standup.mp3" -> subfolder="dpark", filename="standup.mp3"
    # object_name = "speech-to-text/standup.mp3" -> subfolder=None, filename="standup.mp3"
    relative_path = object_name[len(PREFIX):]
    parts = relative_path.rsplit("/", 1)
    if len(parts) == 2:
        subfolder, filename = parts
    else:
        subfolder = None
        filename = parts[0]

    base_name = os.path.splitext(filename)[0]
    if subfolder:
        output_prefix = f"{PREFIX}{subfolder}/{base_name}"
    else:
        output_prefix = f"{PREFIX}{base_name}"

    transcript_path = f"{output_prefix}.txt"
    summary_path = f"{output_prefix}.summary.md"
    error_path = f"{output_prefix}.error.txt"

    storage_client = storage.Client()
    bucket = storage_client.bucket(bucket_name)

    try:
        # --- Phase A: Transcription ---
        gcs_uri = f"gs://{bucket_name}/{object_name}"
        print(f"Using model: {STT_MODEL}")

        if STT_MODEL.startswith("gemini-"):
            # Gemini multimodal transcription — supports speaker diarization
            transcript_text = transcribe_with_gemini(gcs_uri, content_type)
        else:
            # Cloud STT v2 (chirp_2, chirp_3, etc.)
            transcript_text = transcribe_with_cloud_stt(gcs_uri)

        if not transcript_text.strip():
            raise ValueError("Transcription returned empty result")

        # Write transcript
        transcript_blob = bucket.blob(transcript_path)
        transcript_blob.upload_from_string(transcript_text, content_type="text/plain")
        print(f"Transcript written to gs://{bucket_name}/{transcript_path}")

    except Exception as e:
        print(f"Transcription failed for {object_name}: {e}")
        error_blob = bucket.blob(error_path)
        error_blob.upload_from_string(
            f"Error transcribing {object_name}:\n{str(e)}",
            content_type="text/plain",
        )
        return "Transcription failed", 500  # Do NOT delete audio on failure

    # --- Phase B: LLM Summary (failure-isolated) ---
    try:
        instructions = read_instructions(storage_client, bucket_name, subfolder)
        if instructions:
            summary_text = generate_summary(transcript_text, instructions)
            summary_blob = bucket.blob(summary_path)
            summary_blob.upload_from_string(
                summary_text, content_type="text/markdown"
            )
            print(f"Summary written to gs://{bucket_name}/{summary_path}")
        else:
            print("No SUMMARY_INSTRUCTIONS.md found — skipping summary")
    except Exception as e:
        print(f"Summary generation failed (non-fatal): {e}", flush=True)

    # --- Cleanup: delete original audio ---
    try:
        audio_blob = bucket.blob(object_name)
        audio_blob.delete()
        print(f"Deleted original: gs://{bucket_name}/{object_name}")
    except Exception as e:
        print(f"Failed to delete original audio (non-fatal): {e}")

    return "OK", 200
