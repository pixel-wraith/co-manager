#!/usr/bin/env bash
#
# Detect duplicate and overlapping issues in a Jira backlog
#
# Analyzes issue summaries using Claude to identify duplicates and overlaps,
# then updates the JSON file with relationship metadata.
#
# Requirements:
#   - claude CLI (Claude Code) installed and authenticated
#   - jq installed
#
# Usage:
#   ./detect-duplicates.sh <BACKLOG_JSON_FILE>
#
# Example:
#   ./detect-duplicates.sh 123-backlog-issues.json
#

set -euo pipefail

# Configuration
INPUT_FILE="${1:-}"

# Validate inputs
if [[ -z "$INPUT_FILE" ]]; then
    echo "Error: Backlog JSON file is required"
    echo "Usage: $0 <BACKLOG_JSON_FILE>"
    exit 1
fi

if [[ ! -f "$INPUT_FILE" ]]; then
    echo "Error: File not found: $INPUT_FILE"
    exit 1
fi

# Check for required tools
if ! command -v claude &> /dev/null; then
    echo "Error: claude CLI is not installed or not in PATH"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed"
    exit 1
fi

# Temp files for handling large JSON data
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

WORKING_FILE="${TEMP_DIR}/working.json"
cp "$INPUT_FILE" "$WORKING_FILE"

echo "Reading issues from: $INPUT_FILE"

# Get issue counts
issue_count=$(jq '.issues | length' "$WORKING_FILE")
unprocessed_count=$(jq '[.issues[] | select(.__processed != true)] | length' "$WORKING_FILE")
echo "Found $issue_count total issues ($unprocessed_count unprocessed)"

# First, clean up stale references from existing issues
echo "Cleaning up stale references..."
jq '
    ([.issues[].key]) as $valid_keys |
    .issues = [.issues[] |
        # Clean up duplicates array - remove IDs that no longer exist
        if .duplicates then
            .duplicates = [.duplicates[] | select(. as $id | $valid_keys | index($id))]
        else
            .
        end |
        # Remove empty duplicates array
        if .duplicates and (.duplicates | length) == 0 then
            del(.duplicates)
        else
            .
        end |
        # Clean up overlaps_with array - remove entries with IDs that no longer exist
        if .overlaps_with then
            .overlaps_with = [.overlaps_with[] | select(.id as $id | $valid_keys | index($id))]
        else
            .
        end |
        # Remove empty overlaps_with array
        if .overlaps_with and (.overlaps_with | length) == 0 then
            del(.overlaps_with)
        else
            .
        end
    ]
' "$WORKING_FILE" > "${WORKING_FILE}.tmp" && mv "${WORKING_FILE}.tmp" "$WORKING_FILE"

# Check if we have unprocessed issues to analyze
if [[ $unprocessed_count -eq 0 ]]; then
    echo "No unprocessed issues to analyze."
    # Still write back to save any stale reference cleanup
    cp "$WORKING_FILE" "$INPUT_FILE"
    echo "Updated file: $INPUT_FILE"
    exit 0
fi

if [[ $issue_count -lt 2 ]]; then
    echo "Need at least 2 issues to detect duplicates. Exiting."
    exit 0
fi

# Extract issue data for the prompt into temp files
echo "Extracting issues for analysis..."
unprocessed_file="${TEMP_DIR}/unprocessed.json"
all_context_file="${TEMP_DIR}/all_context.json"

jq '[.issues[] | select(.__processed != true) | {id: .key, summary: (.__summary // .fields.summary // "No summary available"), is_new: true}]' "$WORKING_FILE" > "$unprocessed_file"
jq '[.issues[] | {id: .key, summary: (.__summary // .fields.summary // "No summary available"), is_new: (if .__processed == true then false else true end)}]' "$WORKING_FILE" > "$all_context_file"

# Build the prompt for Claude
echo "Analyzing unprocessed issues for duplicates and overlaps..."

prompt_file="${TEMP_DIR}/prompt.txt"
cat > "$prompt_file" <<'PROMPT_HEADER'
You are analyzing Jira issues to identify duplicates and overlaps.

Here are ALL issues in the backlog (for context):
PROMPT_HEADER
cat "$all_context_file" >> "$prompt_file"
cat >> "$prompt_file" <<'PROMPT_MID'

Here are the NEW/UNPROCESSED issues that need to be checked:
PROMPT_MID
cat "$unprocessed_file" >> "$prompt_file"
cat >> "$prompt_file" <<'PROMPT_FOOTER'

Analyze the NEW/UNPROCESSED issues and identify:
1. DUPLICATES: Where a new issue duplicates ANY other issue (new or existing)
2. OVERLAPS: Where a new issue overlaps with ANY other issue (new or existing)

Return your analysis as valid JSON in this exact format (no markdown, no code blocks, just raw JSON):
{
  "duplicates": [
    {
      "ids": ["ISSUE-1", "ISSUE-2"],
      "reason": "Brief explanation of why these are duplicates"
    }
  ],
  "overlaps": [
    {
      "ids": ["ISSUE-3", "ISSUE-4"],
      "details": "Description of how these issues overlap or relate"
    }
  ]
}

Rules:
- Only include relationships where AT LEAST ONE issue is from the NEW/UNPROCESSED list
- Only include actual duplicates and overlaps you're confident about
- Each issue can appear in multiple duplicate/overlap groups if applicable
- If no duplicates are found, return an empty array for "duplicates"
- If no overlaps are found, return an empty array for "overlaps"
- Return ONLY the JSON object, nothing else
PROMPT_FOOTER

# Call Claude to analyze
response_file="${TEMP_DIR}/response.json"
env -u CLAUDECODE claude -p "$(cat "$prompt_file")" > "$response_file" 2>/dev/null

# Validate Claude's response
if ! jq -e '.' "$response_file" > /dev/null 2>&1; then
    # Try to extract JSON from response
    sed -n '/^{/,/^}/p' "$response_file" > "${response_file}.clean"
    if jq -e '.' "${response_file}.clean" > /dev/null 2>&1; then
        mv "${response_file}.clean" "$response_file"
    else
        echo "Error: Failed to parse Claude's response as JSON"
        echo "Raw response:"
        cat "$response_file"
        exit 1
    fi
fi

echo "Analysis complete. Processing results..."

# Extract duplicate and overlap counts
duplicates_file="${TEMP_DIR}/duplicates.json"
overlaps_file="${TEMP_DIR}/overlaps.json"
jq -c '.duplicates // []' "$response_file" > "$duplicates_file"
jq -c '.overlaps // []' "$response_file" > "$overlaps_file"

duplicate_count=$(jq 'length' "$duplicates_file")
overlap_count=$(jq 'length' "$overlaps_file")

echo "  Found $duplicate_count duplicate groups"
echo "  Found $overlap_count overlap groups"

# Process the issues and merge new relationship data with existing
echo "Updating issues with relationship metadata..."

jq --slurpfile dups "$duplicates_file" --slurpfile overlaps "$overlaps_file" '
    ($dups[0]) as $dups |
    ($overlaps[0]) as $overlaps |

    # Build duplicate map: issue_id -> [other_ids]
    def build_duplicate_map:
        reduce $dups[] as $group ({};
            reduce ($group.ids | to_entries[]) as $entry (.;
                .[$entry.value] = ((.[$entry.value] // []) + [$group.ids[] | select(. != $entry.value)]) | unique
            )
        );

    # Build overlap map: issue_id -> [{id, details}]
    def build_overlap_map:
        reduce $overlaps[] as $group ({};
            reduce ($group.ids | to_entries[]) as $entry (.;
                .[$entry.value] = ((.[$entry.value] // []) + [
                    $group.ids[] | select(. != $entry.value) | {id: ., details: $group.details}
                ])
            )
        );

    . as $root |
    build_duplicate_map as $dup_map |
    build_overlap_map as $overlap_map |

    .issues = [.issues[] |
        .key as $key |
        # Merge new duplicates with existing (if any)
        if $dup_map[$key] and ($dup_map[$key] | length) > 0 then
            .duplicates = ((.duplicates // []) + $dup_map[$key]) | unique
        else
            .
        end |
        # Merge new overlaps with existing (if any), avoiding duplicate entries
        if $overlap_map[$key] and ($overlap_map[$key] | length) > 0 then
            (.overlaps_with // []) as $existing |
            ($existing | map(.id)) as $existing_ids |
            .overlaps_with = ($existing + [$overlap_map[$key][] | select(.id as $id | $existing_ids | index($id) | not)])
        else
            .
        end
    ] |
    # Add metadata about duplicate detection
    . + {duplicatesAnalyzedAt: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))}
' "$WORKING_FILE" > "${WORKING_FILE}.tmp" && mv "${WORKING_FILE}.tmp" "$WORKING_FILE"

# Write back to the original file
cp "$WORKING_FILE" "$INPUT_FILE"

echo ""
echo "Successfully analyzed $unprocessed_count unprocessed issues against $issue_count total"
echo "  - Duplicate groups found: $duplicate_count"
echo "  - Overlap groups found: $overlap_count"
echo "Updated file: $INPUT_FILE"

# Print summary of findings
if [[ $duplicate_count -gt 0 ]]; then
    echo ""
    echo "Duplicate groups:"
    jq -r '.[] | "  - \(.ids | join(", ")): \(.reason)"' "$duplicates_file"
fi

if [[ $overlap_count -gt 0 ]]; then
    echo ""
    echo "Overlap groups:"
    jq -r '.[] | "  - \(.ids | join(", ")): \(.details)"' "$overlaps_file"
fi
