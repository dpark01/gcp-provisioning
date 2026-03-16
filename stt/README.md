# Transcription Service — How It Works

## What This Does

When you drop an audio file into the bucket, it gets automatically transcribed and summarized:

1. **Raw transcript** — a `.txt` file with everything that was said, straight from Google's speech-to-text engine
2. **Summary** — a `.summary.md` file with a cleaned-up, structured overview produced by an AI language model

The raw transcript is always produced. The summary is shaped by an instruction file called `SUMMARY_INSTRUCTIONS.md` that tells the AI *how* to process the transcript — what sections to include, what tone to use, what to pay attention to.

## Where the Instructions Live

The default instruction file is at:

```
gs://sabeti-transcription/speech-to-text/SUMMARY_INSTRUCTIONS.md
```

This is what gets used for every transcript unless there's an override (see below). It's currently configured for our most common use case: summarizing calls with external collaborators (academic partners, clinical sites, funders, government agencies, etc.).

## Overriding the Default

If a specific subdirectory has its own `SUMMARY_INSTRUCTIONS.md`, that file takes precedence for any audio processed in that directory.

```
gs://sabeti-transcription/anysubdirectoryname/SUMMARY_INSTRUCTIONS.md
```

This means you can tailor the summary format for different contexts without affecting anyone else. For example, you might create a subdirectory for internal lab meetings with instructions that skip the "Data Sharing" section and add a "Paper Updates" section instead. Or a subdirectory for funder calls that emphasizes grant milestones and deliverables.

The resolution order is:

1. `SUMMARY_INSTRUCTIONS.md` in the same subdirectory as the audio → **used if present**
2. `gs://sabeti-transcription/speech-to-text/SUMMARY_INSTRUCTIONS.md` → **fallback default**
3. If neither exists → no summary is generated, but the raw transcript is still produced

## Editing the Instructions

The `SUMMARY_INSTRUCTIONS.md` file is just Markdown — open it in any text editor or directly in the Google Cloud Console. Changes take effect on the next transcript that gets processed. No code changes or redeployment needed.

Feel free to experiment. If a change doesn't work well, just edit the file again. The instructions don't affect previously generated summaries, only future ones.

### What You Can Change

Pretty much anything about the summary output:

- **Sections** — add, remove, rename, or reorder sections
- **Tone** — make it more formal, more casual, more technical
- **Detail level** — ask for longer or shorter summaries
- **Special handling** — tell the AI to watch for specific things (e.g., "always flag mentions of IRB status" or "list any datasets referenced by name")
- **Output format** — change the Markdown structure, add tables, change heading levels

### What You Probably Shouldn't Change

The STT artifact handling section (filler word removal, `[unclear]` flagging, speaker label cleanup) works well as-is. If you remove it, summaries will be noisier.

## Finding Inspiration for New Instructions

If you want to create a custom `SUMMARY_INSTRUCTIONS.md` for a specific subdirectory, you don't have to start from scratch. The **BrassTranscripts AI Prompt Library** is an MIT-licensed open-source collection of 90+ transcript processing prompts, available at:

> **GitHub:** [CopperSunDev/brasstranscripts-ai-prompts](https://github.com/CopperSunDev/brasstranscripts-ai-prompts)
>
> **Browsable guide:** [brasstranscripts.com/ai-prompt-guide](https://brasstranscripts.com/ai-prompt-guide)

Some templates that might be useful starting points for us:

| Template | Good for |
|---|---|
| Executive Summary Generator | High-stakes calls where you need decisions + risk assessment |
| Action Item Tracker | Calls that are heavy on task assignments and deadlines |
| Meeting Minutes Generator | Formal documentation for governance or compliance |
| Training Material Creator | Turning a training session or workshop into structured notes |
| Interview Thematic Analysis | Qualitative research interviews where you want themes extracted |

To use one: grab the prompt text from the repo, paste it into a new `SUMMARY_INSTRUCTIONS.md`, and adapt it to our context (research group, scientific terminology, collaborator dynamics). Drop it in the appropriate subdirectory and you're set.

## Questions or Problems

If summaries aren't being generated, check that `SUMMARY_INSTRUCTIONS.md` exists in the expected location and that the filename is spelled exactly right (it's case-sensitive). If the raw transcript appears but the summary doesn't, check the `errors/` folder in the bucket for details.
