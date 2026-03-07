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

# Read the JSON file
echo "Reading issues from: $INPUT_FILE"
json_content=$(cat "$INPUT_FILE")

# Get the number of issues
issue_count=$(echo "$json_content" | jq '.issues | length')
unprocessed_count=$(echo "$json_content" | jq '[.issues[] | select(.__processed != true)] | length')
echo "Found $issue_count total issues ($unprocessed_count unprocessed)"

# Create a temporary file for building the updated JSON
temp_file=$(mktemp)
trap "rm -f $temp_file" EXIT

# Copy the original structure without issues
echo "$json_content" | jq 'del(.issues)' > "$temp_file"

# Process each issue
echo "Processing issues..."
updated_issues="[]"
summarized_count=0

for i in $(seq 0 $((issue_count - 1))); do
    # Extract issue details
    issue=$(echo "$json_content" | jq -c ".issues[$i]")
    issue_key=$(echo "$issue" | jq -r '.key // "UNKNOWN"')

    # Extract title (summary field in Jira)
    title=$(echo "$issue" | jq -r '.fields.summary // "No title"')

    # Extract description - handle both plain text and Atlassian Document Format (ADF)
    # ADF stores content in .fields.description.content, plain text is just .fields.description
    description=$(echo "$issue" | jq -r '
        if .fields.description == null then
            "No description"
        elif .fields.description | type == "string" then
            .fields.description
        elif .fields.description.content then
            # Extract text from ADF format
            [.fields.description.content[]? | .. | .text? // empty] | join(" ")
        else
            "No description"
        end
    ')

    # Truncate description if too long (to avoid token limits)
    max_desc_length=2000
    if [[ ${#description} -gt $max_desc_length ]]; then
        description="${description:0:$max_desc_length}..."
    fi

    echo "  [$((i + 1))/$issue_count] Summarizing $issue_key: $title"

    # Check if already processed
    is_processed=$(echo "$issue" | jq -r '.__processed // false')
    if [[ "$is_processed" == "true" ]]; then
        echo "    Skipping (already processed)"
        updated_issues=$(echo "$updated_issues" | jq --argjson issue "$issue" '. + [$issue]')
        continue
    fi

    # Build the prompt for Claude
    prompt="Summarize this Jira issue in 1-2 concise sentences. Focus on what needs to be done and why.

Title: $title

Description:
$description

Provide only the summary, no preamble or extra text."

    # Call Claude to generate summary
    summary=$(claude -p "$prompt" 2>/dev/null || echo "Failed to generate summary")

    # Clean up the summary (remove leading/trailing whitespace)
    summary=$(echo "$summary" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    # Add the summary to the issue
    updated_issue=$(echo "$issue" | jq --arg summary "$summary" '. + {__summary: $summary}')

    # Append to our collection
    updated_issues=$(echo "$updated_issues" | jq --argjson issue "$updated_issue" '. + [$issue]')
    ((summarized_count++))

    echo "    Summary: ${summary:0:80}..."
done

# Rebuild the final JSON with updated issues
final_json=$(echo "$json_content" | jq --argjson issues "$updated_issues" '.issues = $issues')

# Add metadata about summarization
final_json=$(echo "$final_json" | jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" '. + {summarizedAt: $ts}')

# Write back to the original file
echo "$final_json" > "$INPUT_FILE"

echo ""
echo "Successfully summarized $summarized_count issues (skipped $((issue_count - summarized_count)) already processed)"
echo "Updated file: $INPUT_FILE"
