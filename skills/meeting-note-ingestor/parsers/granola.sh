#!/usr/bin/env bash
# skills/meeting-note-ingestor/parsers/granola.sh — SP13 T-11
#
# Granola transcript JSON → JSON envelope on stdout:
#   {"title", "date", "participants": [...], "body"}
#
# Recognized JSON shapes (lenient — Granola MCP shape varies by version):
#   {title, date, attendees: [...], transcript: [{speaker, text} | ...]}
#   {meeting_title, meeting_date, participants: [...], body | text}
#   {title, transcript: "Speaker: text\n..."}  (string transcript)
#
# Body output: "Speaker: text" lines, one per utterance. Empty speaker labels
# are emitted as "Unknown:" so downstream participant-extract can still flag
# the gap.
#
# Constraints (R-23): bash 3.2 + jq.
#
# Author: Claude Opus 4.7 (1M context) — Plan 71 SP13 Session 9

set -u

[ $# -eq 1 ] || { echo "granola.sh: usage: granola.sh <PATH>" >&2; exit 2; }
in="$1"

if [ ! -f "$in" ]; then
  printf 'granola.sh FAIL: file not found: %s\n' "$in" >&2
  exit 2
fi

if ! jq -e . "$in" >/dev/null 2>&1; then
  printf 'granola.sh FAIL: not valid JSON: %s\n' "$in" >&2
  exit 2
fi

jq -c '
  def to_speaker_text(item):
    if (item | type) == "object" then
      ((item.speaker // item.name // item.role // "Unknown") | tostring) + ": " + ((item.text // item.content // item.utterance // "") | tostring)
    elif (item | type) == "string" then
      item
    else
      ""
    end;

  def safe_attendee(a):
    if (a | type) == "object" then (a.name // a.full_name // a.first_name // "")
    elif (a | type) == "string" then a
    else ""
    end;

  {
    title: ((.title // .meeting_title // .name // "") | tostring),
    date: ((.date // .meeting_date // .start_time // .created_at // "") | tostring),
    participants: (
      ((.attendees // .participants // .speakers // [])
       | if type == "array" then map(safe_attendee(.)) | map(select(. != "")) else [] end)
    ),
    body: (
      if (.transcript | type) == "array" then
        (.transcript | map(to_speaker_text(.)) | map(select(. != "")) | join("\n"))
      elif (.transcript | type) == "string" then
        .transcript
      elif (.body | type) == "string" then
        .body
      elif (.text | type) == "string" then
        .text
      else
        ""
      end
    )
  }
' "$in"
