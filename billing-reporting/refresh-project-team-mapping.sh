#!/usr/bin/env bash
# Refreshes the project_team_mapping table in BigQuery.
# Pulls team labels from GCP projects and loads into BQ.
# Run after adding/changing `team` labels on any GCP project.
#
# Uses `gcloud projects list --filter='labels.team:*'` to find projects
# with a team label. This is a server-side filter and only returns
# matching projects (currently ~9).
#
# NOTE: `gcloud projects list` only returns projects the caller has access to.
# If a project is not visible (e.g. broad-dsde-alpha, team=dsp), you can
# manually append a row to the JSONL before loading:
#   echo '{"project_id":"broad-dsde-alpha","team":"dsp","refreshed_at":"..."}' >> "$TMPFILE"

set -euo pipefail

DATASET="gcid-data-core.custom_sada_billing_views"
TABLE="${DATASET}.project_team_mapping"
TMPFILE=$(mktemp /tmp/project_team_mapping.XXXXXX.jsonl)
trap 'rm -f "$TMPFILE"' EXIT

echo "Fetching projects with team labels from gcloud..."
gcloud projects list --filter='labels.team:*' --format='json' \
  | jq -c '.[] | {
      project_id: .projectId,
      team: .labels.team,
      refreshed_at: (now | strftime("%Y-%m-%d %H:%M:%S UTC"))
    }' > "$TMPFILE"

ROW_COUNT=$(wc -l < "$TMPFILE" | tr -d ' ')
echo "Found ${ROW_COUNT} projects with team labels."

echo "Loading into ${TABLE} (full replace)..."
bq load \
  --project_id=gcid-data-core \
  --replace \
  --source_format=NEWLINE_DELIMITED_JSON \
  "custom_sada_billing_views.project_team_mapping" \
  "$TMPFILE" \
  project_id:STRING,team:STRING,refreshed_at:TIMESTAMP

echo "Verifying..."
bq query --nouse_legacy_sql \
  "SELECT * FROM \`${TABLE}\` ORDER BY team, project_id"

echo "Done. ${ROW_COUNT} project-team mappings loaded into ${TABLE}."
