#!/usr/bin/env bash
#
# Summarize Jira backlog issues using Claude
#
# Iterates over each issue in a backlog JSON file, uses Claude to generate
# a concise summary, and writes the summary back to the JSON file.
#
# Requirements:
#   - claude CLI (Claude Code) installed and authenticated
#   - jq installed
#
# Usage:
#   ./summarize-backlog-issues.sh <BACKLOG_JSON_FILE>
#
# Example:
#   ./summarize-backlog-issues.sh 123-backlog-issues.json
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

UPDATED_ISSUES_FILE="${TEMP_DIR}/updated_issues.json"
echo '[]' > "$UPDATED_ISSUES_FILE"

echo "Reading issues from: $INPUT_FILE"

# Get the number of issues
issue_count=$(jq '.issues | length' "$INPUT_FILE")
unprocessed_count=$(jq '[.issues[] | select(.__processed != true)] | length' "$INPUT_FILE")
echo "Found $issue_count total issues ($unprocessed_count unprocessed)"

# Process each issue
echo "Processing issues..."
summarized_count=0

for i in $(seq 0 $((issue_count - 1))); do
    # Extract issue details to a temp file
    issue_file="${TEMP_DIR}/issue.json"
    jq -c ".issues[$i]" "$INPUT_FILE" > "$issue_file"
    issue_key=$(jq -r '.key // "UNKNOWN"' "$issue_file")

    # Extract title (summary field in Jira)
    title=$(jq -r '.fields.summary // "No title"' "$issue_file")

    echo "  [$((i + 1))/$issue_count] Summarizing $issue_key: $title"

    # Check if already processed
    is_processed=$(jq -r '.__processed // false' "$issue_file")
    if [[ "$is_processed" == "true" ]]; then
        echo "    Skipping (already processed)"
        jq --slurpfile issue "$issue_file" '. + $issue' "$UPDATED_ISSUES_FILE" > "${UPDATED_ISSUES_FILE}.tmp" && mv "${UPDATED_ISSUES_FILE}.tmp" "$UPDATED_ISSUES_FILE"
        continue
    fi

    # Extract description - handle both plain text and Atlassian Document Format (ADF)
    description=$(jq -r '
        if .fields.description == null then
            "No description"
        elif .fields.description | type == "string" then
            .fields.description
        elif .fields.description.content then
            [.fields.description.content[]? | .. | .text? // empty] | join(" ")
        else
            "No description"
        end
    ' "$issue_file")

    # Truncate description if too long (to avoid token limits)
    max_desc_length=2000
    if [[ ${#description} -gt $max_desc_length ]]; then
        description="${description:0:$max_desc_length}..."
    fi

    # Build the prompt for Claude
    prompt="Summarize this Jira issue in 1-2 concise sentences. Focus on what needs to be done and why.

Title: $title

Description:
$description

Provide only the summary, no preamble or extra text."

    # Call Claude to generate summary
    summary=$(env -u CLAUDECODE claude -p "$prompt" 2>/dev/null || echo "Failed to generate summary")

    # Clean up the summary (remove leading/trailing whitespace)
    summary=$(echo "$summary" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    # Add the summary to the issue and append to updated issues
    jq --arg summary "$summary" '. + {__summary: $summary}' "$issue_file" > "${TEMP_DIR}/updated_issue.json"
    jq --slurpfile issue "${TEMP_DIR}/updated_issue.json" '. + $issue' "$UPDATED_ISSUES_FILE" > "${UPDATED_ISSUES_FILE}.tmp" && mv "${UPDATED_ISSUES_FILE}.tmp" "$UPDATED_ISSUES_FILE"
    ((summarized_count++))

    echo "    Summary: ${summary:0:80}..."
done

# Rebuild the final JSON with updated issues
jq --slurpfile issues "$UPDATED_ISSUES_FILE" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '.issues = $issues[0] | . + {summarizedAt: $ts}' "$INPUT_FILE" > "${TEMP_DIR}/final.json"

# Write back to the original file
mv "${TEMP_DIR}/final.json" "$INPUT_FILE"

echo ""
echo "Successfully summarized $summarized_count issues (skipped $((issue_count - summarized_count)) already processed)"
echo "Updated file: $INPUT_FILE"
