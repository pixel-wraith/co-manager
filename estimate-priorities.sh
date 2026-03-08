#!/usr/bin/env bash
#
# Estimate priority for Jira backlog issues using Claude
#
# Analyzes each issue and estimates its priority based on the summary,
# using standard Jira priority levels.
#
# Requirements:
#   - claude CLI (Claude Code) installed and authenticated
#   - jq installed
#
# Usage:
#   ./estimate-priorities.sh <BACKLOG_JSON_FILE>
#
# Example:
#   ./estimate-priorities.sh 123-backlog-issues.json
#

set -euo pipefail

# Configuration
INPUT_FILE="${1:-}"

# Standard Jira priority levels (from highest to lowest)
VALID_PRIORITIES=("Highest" "High" "Medium" "Low" "Lowest")

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

# Process each issue
echo "Estimating priorities..."
updated_issues="[]"
estimated_count=0

for i in $(seq 0 $((issue_count - 1))); do
    # Extract issue details
    issue=$(echo "$json_content" | jq -c ".issues[$i]")
    issue_key=$(echo "$issue" | jq -r '.key // "UNKNOWN"')

    # Get the summary (prefer AI summary, fall back to title)
    summary=$(echo "$issue" | jq -r '.__summary // .fields.summary // "No summary"')
    title=$(echo "$issue" | jq -r '.fields.summary // "No title"')

    # Get existing Jira priority if set
    existing_priority=$(echo "$issue" | jq -r '.fields.priority.name // "Not set"')

    echo "  [$((i + 1))/$issue_count] Estimating priority for $issue_key"

    # Check if already processed
    is_processed=$(echo "$issue" | jq -r '.__processed // false')
    if [[ "$is_processed" == "true" ]]; then
        echo "    Skipping (already processed)"
        updated_issues=$(echo "$updated_issues" | jq --argjson issue "$issue" '. + [$issue]')
        continue
    fi

    # Build the prompt for Claude
    prompt="Estimate the priority for this Jira issue. Consider factors like:
- Business impact and urgency
- Number of users affected
- Whether it's blocking other work
- Security or compliance implications
- Technical debt implications

Issue Title: $title

Summary: $summary

Current Jira Priority: $existing_priority

Respond with ONLY one of these priority levels (no explanation, just the word):
- Highest (critical, immediate attention required)
- High (important, should be addressed soon)
- Medium (normal priority)
- Low (can be deferred)
- Lowest (nice to have, no urgency)"

    # Call Claude to estimate priority
    priority=$(env -u CLAUDECODE claude -p "$prompt" 2>/dev/null || echo "Medium")

    # Clean up and validate the priority
    priority=$(echo "$priority" | tr -d '[:space:]' | sed 's/[^a-zA-Z]//g')

    # Normalize to proper case and validate
    priority_valid=false
    priority_lower=$(echo "$priority" | tr '[:upper:]' '[:lower:]')
    for valid in "${VALID_PRIORITIES[@]}"; do
        valid_lower=$(echo "$valid" | tr '[:upper:]' '[:lower:]')
        if [[ "$priority_lower" == "$valid_lower" ]]; then
            priority="$valid"
            priority_valid=true
            break
        fi
    done

    # Default to Medium if invalid response
    if [[ "$priority_valid" == "false" ]]; then
        echo "    Warning: Invalid priority '$priority', defaulting to Medium"
        priority="Medium"
    fi

    # Add the priority to the issue
    updated_issue=$(echo "$issue" | jq --arg priority "$priority" '. + {__priority: $priority}')

    # Append to our collection
    updated_issues=$(echo "$updated_issues" | jq --argjson issue "$updated_issue" '. + [$issue]')
    ((estimated_count++))

    echo "    Priority: $priority"
done

# Rebuild the final JSON with updated issues
final_json=$(echo "$json_content" | jq --argjson issues "$updated_issues" '.issues = $issues')

# Add metadata about priority estimation
final_json=$(echo "$final_json" | jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" '. + {prioritiesEstimatedAt: $ts}')

# Write back to the original file
echo "$final_json" > "$INPUT_FILE"

# Calculate priority distribution
echo ""
echo "Priority distribution:"
for priority in "${VALID_PRIORITIES[@]}"; do
    count=$(echo "$final_json" | jq --arg p "$priority" '[.issues[] | select(.__priority == $p)] | length')
    echo "  $priority: $count"
done

echo ""
echo "Successfully estimated priorities for $estimated_count issues (skipped $((issue_count - estimated_count)) already processed)"
echo "Updated file: $INPUT_FILE"
