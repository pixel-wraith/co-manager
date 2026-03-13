#!/usr/bin/env bash
#
# Generate implementation plans for Jira backlog issues using Claude
#
# Iterates over each issue, checks if it already has Technical Notes and
# Testing Requirements headers. If not, uses Claude to analyze the issue
# and the current codebase to generate a thorough implementation plan.
#
# Requirements:
#   - claude CLI (Claude Code) installed and authenticated
#   - jq installed
#
# Usage:
#   ./write-full-ticket.sh <BACKLOG_JSON_FILE>
#
# Example:
#   ./write-full-ticket.sh ~/.co-manager/121-backlog-issues.json
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
echo "Found $issue_count total issues"

# Process each issue
echo "Generating implementation plans..."
planned_count=0
skipped_status_count=0
missing_info_count=0
already_ready_count=0

for i in $(seq 0 $((issue_count - 1))); do
    # Extract issue details to a temp file
    issue_file="${TEMP_DIR}/issue.json"
    jq -c ".issues[$i]" "$INPUT_FILE" > "$issue_file"
    issue_key=$(jq -r '.key // "UNKNOWN"' "$issue_file")

    # Extract title
    title=$(jq -r '.fields.summary // "No title"' "$issue_file")

    echo "  [$((i + 1))/$issue_count] $issue_key: $title"

    # Check issue status - skip if not "To Do"
    issue_status=$(jq -r '.fields.status.name // "Unknown"' "$issue_file")
    if [[ "$issue_status" != "To Do" ]]; then
        echo "    Skipping (status: $issue_status, not 'To Do')"
        jq --slurpfile issue "$issue_file" '. + $issue' "$UPDATED_ISSUES_FILE" > "${UPDATED_ISSUES_FILE}.tmp" && mv "${UPDATED_ISSUES_FILE}.tmp" "$UPDATED_ISSUES_FILE"
        ((skipped_status_count++))
        continue
    fi

    # Check _status - skip if already "ready-for-manager-review" or "missing-information"
    custom_status=$(jq -r '._status // "none"' "$issue_file")
    if [[ "$custom_status" == "ready-for-manager-review" || "$custom_status" == "missing-information" ]]; then
        echo "    Skipping (_status: $custom_status)"
        jq --slurpfile issue "$issue_file" '. + $issue' "$UPDATED_ISSUES_FILE" > "${UPDATED_ISSUES_FILE}.tmp" && mv "${UPDATED_ISSUES_FILE}.tmp" "$UPDATED_ISSUES_FILE"
        if [[ "$custom_status" == "ready-for-manager-review" ]]; then
            ((already_ready_count++))
        else
            ((missing_info_count++))
        fi
        continue
    fi

    # Extract description - handle both plain text and Atlassian Document Format (ADF)
    description=$(jq -r '
        if .fields.description == null then
            ""
        elif .fields.description | type == "string" then
            .fields.description
        elif .fields.description.content then
            [.fields.description.content[]? | .. | .text? // empty] | join(" ")
        else
            ""
        end
    ' "$issue_file")

    # Also check _description if it exists
    custom_description=$(jq -r '._description // ""' "$issue_file")

    # Combine all available content for header check
    full_content="${description}${custom_description}"

    # Check if the issue already has Technical Notes and Testing Requirements headers
    has_technical_notes=false
    has_testing_requirements=false

    if echo "$full_content" | grep -qi "Technical Notes"; then
        has_technical_notes=true
    fi

    if echo "$full_content" | grep -qi "Testing Requirements"; then
        has_testing_requirements=true
    fi

    if [[ "$has_technical_notes" == "true" && "$has_testing_requirements" == "true" ]]; then
        # Already has both headers - mark as ready for review
        echo "    Already has Technical Notes and Testing Requirements"
        echo "    Setting _status to 'ready-for-manager-review'"
        jq '. + {_status: "ready-for-manager-review"}' "$issue_file" > "${TEMP_DIR}/updated_issue.json"
        jq --slurpfile issue "${TEMP_DIR}/updated_issue.json" '. + $issue' "$UPDATED_ISSUES_FILE" > "${UPDATED_ISSUES_FILE}.tmp" && mv "${UPDATED_ISSUES_FILE}.tmp" "$UPDATED_ISSUES_FILE"
        ((already_ready_count++))
        continue
    fi

    # Issue is missing Technical Notes and/or Testing Requirements
    # Check if the issue has any meaningful content
    trimmed_description=$(echo "$description" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    if [[ -z "$trimmed_description" || "$trimmed_description" == "No description" ]]; then
        # No information provided - mark as missing information
        echo "    No requirements or information listed"
        echo "    Setting _status to 'missing-information'"
        jq '. + {_status: "missing-information"}' "$issue_file" > "${TEMP_DIR}/updated_issue.json"
        jq --slurpfile issue "${TEMP_DIR}/updated_issue.json" '. + $issue' "$UPDATED_ISSUES_FILE" > "${UPDATED_ISSUES_FILE}.tmp" && mv "${UPDATED_ISSUES_FILE}.tmp" "$UPDATED_ISSUES_FILE"
        ((missing_info_count++))
        continue
    fi

    # Issue has information - generate implementation plan using Claude
    echo "    Generating implementation plan..."

    # Truncate description if too long
    max_desc_length=20000
    if [[ ${#description} -gt $max_desc_length ]]; then
        description="${description:0:$max_desc_length}..."
    fi

    # Get the AI summary if available
    ai_summary=$(jq -r '.__summary // ""' "$issue_file")
    summary_section=""
    if [[ -n "$ai_summary" ]]; then
        summary_section="AI Summary: $ai_summary"
    fi

    # Build the prompt for Claude - write to a file to handle large content
    prompt_file="${TEMP_DIR}/prompt.txt"
    cat > "$prompt_file" <<PROMPT_EOF
You are a senior software engineer analyzing a Jira ticket and the current codebase to create a thorough implementation plan.

## Issue Details
Issue Key: $issue_key
Title: $title
$summary_section

Description:
$description

## Instructions
Analyze the requirements described in this issue and the codebase in the current working directory. Generate a thorough implementation plan that includes technical notes and testing requirements.

Important constraints:
- All PRs must be 300 changes or fewer. If the implementation would require more than 300 changes, break it down into multiple parts listed in blocking order, where each part can be completed in 300 changes or fewer.
- All requirements from the issue must be met.
- Tests must cover all use cases to assert the changes function correctly.

Output the plan in EXACTLY this format (no markdown code blocks wrapping the output):

{{SUMMARY - a brief overview of what this ticket accomplishes}}

## 🧩 Part 1 - {{ONE LINE DESCRIPTION OF THIS PART}}
{{PART SUMMARY - what this part accomplishes and why it comes first}}

### 💻 Technical Notes
- {{LIST OF TECHNICAL NOTES AND REQUIREMENTS - be specific about files, functions, patterns to use}}

### 🧪 Testing Requirements
*At minimum, tests must be written to cover the following use cases:*
- {{LIST OF ALL USE CASES THAT NEED TO BE TESTED}}

If more than one part is needed, continue with Part 2, Part 3, etc. following the same format. Each part should build on the previous and be completable in 300 changes or fewer.

If the work fits in a single part, that's fine - just output one part.

Provide only the plan, no preamble or extra commentary.
PROMPT_EOF

    # Call Claude to generate the implementation plan
    plan=$(env -u CLAUDECODE claude -p "$(cat "$prompt_file")" 2>/dev/null || echo "Failed to generate implementation plan")

    # Clean up the plan (remove leading/trailing whitespace)
    plan=$(echo "$plan" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    if [[ "$plan" == "Failed to generate implementation plan" ]]; then
        echo "    Warning: Failed to generate plan, skipping"
        jq --slurpfile issue "$issue_file" '. + $issue' "$UPDATED_ISSUES_FILE" > "${UPDATED_ISSUES_FILE}.tmp" && mv "${UPDATED_ISSUES_FILE}.tmp" "$UPDATED_ISSUES_FILE"
        continue
    fi

    # Add the plan as _description and move on
    echo "    Plan generated successfully"
    jq --arg plan "$plan" '. + {_description: $plan}' "$issue_file" > "${TEMP_DIR}/updated_issue.json"
    jq --slurpfile issue "${TEMP_DIR}/updated_issue.json" '. + $issue' "$UPDATED_ISSUES_FILE" > "${UPDATED_ISSUES_FILE}.tmp" && mv "${UPDATED_ISSUES_FILE}.tmp" "$UPDATED_ISSUES_FILE"
    ((planned_count++))

    # Show a preview
    preview=$(echo "$plan" | head -3)
    echo "    Preview: ${preview:0:120}..."
done

# Rebuild the final JSON with updated issues
jq --slurpfile issues "$UPDATED_ISSUES_FILE" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '.issues = $issues[0] | . + {plansGeneratedAt: $ts}' "$INPUT_FILE" > "${TEMP_DIR}/final.json"

# Write back to the original file
mv "${TEMP_DIR}/final.json" "$INPUT_FILE"

echo ""
echo "=============================================="
echo "  Implementation Plan Generation Complete"
echo "=============================================="
echo "  Plans generated:            $planned_count"
echo "  Skipped (wrong status):     $skipped_status_count"
echo "  Missing information:        $missing_info_count"
echo "  Already ready for review:   $already_ready_count"
echo "  Total issues:               $issue_count"
echo ""
echo "Updated file: $INPUT_FILE"
