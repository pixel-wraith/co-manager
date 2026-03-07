#!/usr/bin/env bash
#
# Process Jira Backlog - Complete Pipeline
#
# Runs the full backlog processing pipeline:
#   1. Fetch all issues from a Jira board's backlog
#   2. Generate AI summaries for each issue
#   3. Estimate priority for each issue
#   4. Detect duplicates and overlapping issues
#
# Required environment variables:
#   JIRA_BASE_URL  - Your Jira instance URL (e.g., https://yourcompany.atlassian.net)
#   JIRA_EMAIL     - Your Jira account email
#   JIRA_API_TOKEN - Your Jira API token
#
# Requirements:
#   - claude CLI (Claude Code) installed and authenticated
#   - jq installed
#   - curl installed
#
# Usage:
#   ./process-backlog.sh <BOARD_ID>
#
# Example:
#   ./process-backlog.sh 123
#

set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
BOARD_ID="${1:-}"
DATA_DIR="${HOME}/.co-manager"

# Validate inputs
if [[ -z "$BOARD_ID" ]]; then
    echo "Error: Board ID is required"
    echo "Usage: $0 <BOARD_ID>"
    exit 1
fi

# Create data directory if it doesn't exist
mkdir -p "$DATA_DIR"

OUTPUT_FILE="${DATA_DIR}/${BOARD_ID}-backlog-issues.json"

echo "=============================================="
echo "  Jira Backlog Processing Pipeline"
echo "=============================================="
echo ""
echo "Board ID: $BOARD_ID"
echo "Output file: $OUTPUT_FILE"
echo ""

# ---------------------------------------------
# Step 1: Fetch backlog issues from Jira
# ---------------------------------------------
echo "=============================================="
echo "  Step 1: Fetching Backlog Issues from Jira"
echo "=============================================="
echo ""

"${SCRIPT_DIR}/fetch-jira-backlog.sh" "$BOARD_ID"

# Print summary for Step 1
total_issues=$(jq '.totalIssues' "$OUTPUT_FILE")
unprocessed_issues=$(jq '[.issues[] | select(.__processed != true)] | length' "$OUTPUT_FILE")
processed_issues=$(jq '[.issues[] | select(.__processed == true)] | length' "$OUTPUT_FILE")
echo ""
echo "----------------------------------------------"
echo "  STEP 1 SUMMARY"
echo "----------------------------------------------"
echo "  Total issues in backlog: $total_issues"
echo "  Already processed: $processed_issues"
echo "  To be processed: $unprocessed_issues"
echo "----------------------------------------------"
echo ""

# Check if there are issues to process
if [[ "$total_issues" -eq 0 ]]; then
    echo "No issues found in backlog. Exiting."
    exit 0
fi

# ---------------------------------------------
# Step 2: Generate summaries for each issue
# ---------------------------------------------
echo "=============================================="
echo "  Step 2: Generating AI Summaries"
echo "=============================================="
echo ""

"${SCRIPT_DIR}/summarize-backlog-issues.sh" "$OUTPUT_FILE"

# Print summary for Step 2
issues_with_summary=$(jq '[.issues[] | select(.__summary != null)] | length' "$OUTPUT_FILE")
echo ""
echo "----------------------------------------------"
echo "  STEP 2 SUMMARY"
echo "----------------------------------------------"
echo "  Summaries generated for: $issues_with_summary issues"
echo "----------------------------------------------"
echo ""

# ---------------------------------------------
# Step 3: Estimate priorities for each issue
# ---------------------------------------------
echo "=============================================="
echo "  Step 3: Estimating Priorities"
echo "=============================================="
echo ""

"${SCRIPT_DIR}/estimate-priorities.sh" "$OUTPUT_FILE"

# Print summary for Step 3
issues_with_priority=$(jq '[.issues[] | select(.__priority != null)] | length' "$OUTPUT_FILE")
echo ""
echo "----------------------------------------------"
echo "  STEP 3 SUMMARY"
echo "----------------------------------------------"
echo "  Priorities estimated for: $issues_with_priority issues"
priority_highest=$(jq '[.issues[] | select(.__priority == "Highest")] | length' "$OUTPUT_FILE")
priority_high=$(jq '[.issues[] | select(.__priority == "High")] | length' "$OUTPUT_FILE")
priority_medium=$(jq '[.issues[] | select(.__priority == "Medium")] | length' "$OUTPUT_FILE")
priority_low=$(jq '[.issues[] | select(.__priority == "Low")] | length' "$OUTPUT_FILE")
priority_lowest=$(jq '[.issues[] | select(.__priority == "Lowest")] | length' "$OUTPUT_FILE")
echo "  Distribution: $priority_highest Highest, $priority_high High, $priority_medium Medium, $priority_low Low, $priority_lowest Lowest"
echo "----------------------------------------------"
echo ""

# ---------------------------------------------
# Step 4: Detect duplicates and overlaps
# ---------------------------------------------
echo "=============================================="
echo "  Step 4: Detecting Duplicates & Overlaps"
echo "=============================================="
echo ""

"${SCRIPT_DIR}/detect-duplicates.sh" "$OUTPUT_FILE"

# Print summary for Step 3
duplicate_issues=$(jq '[.issues[] | select(.duplicates != null)] | length' "$OUTPUT_FILE")
overlap_issues=$(jq '[.issues[] | select(.overlaps_with != null)] | length' "$OUTPUT_FILE")

# Count unique duplicate pairs (each pair is counted once)
total_duplicate_relationships=$(jq '[.issues[] | select(.duplicates != null) | .duplicates | length] | add // 0' "$OUTPUT_FILE")
total_duplicate_relationships=$((total_duplicate_relationships / 2))

# Count unique overlap relationships
total_overlap_relationships=$(jq '[.issues[] | select(.overlaps_with != null) | .overlaps_with | length] | add // 0' "$OUTPUT_FILE")
total_overlap_relationships=$((total_overlap_relationships / 2))

echo ""
echo "----------------------------------------------"
echo "  STEP 4 SUMMARY"
echo "----------------------------------------------"
echo "  Issues flagged as duplicates: $duplicate_issues"
echo "  Issues flagged with overlaps: $overlap_issues"
echo "  Total duplicate relationships: $total_duplicate_relationships"
echo "  Total overlap relationships: $total_overlap_relationships"
echo "----------------------------------------------"
echo ""

# ---------------------------------------------
# Step 5: Mark processed issues
# ---------------------------------------------
echo "=============================================="
echo "  Step 5: Marking Issues as Processed"
echo "=============================================="
echo ""

# Count unprocessed issues before marking
unprocessed_before=$(jq '[.issues[] | select(.__processed != true)] | length' "$OUTPUT_FILE")

# Mark all unprocessed issues as processed
jq '.issues = [.issues[] | if .__processed != true then . + {__processed: true} else . end] | . + {processedAt: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))}' "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp" && mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"

echo "Marked $unprocessed_before issues as processed"
echo ""
echo "----------------------------------------------"
echo "  STEP 5 SUMMARY"
echo "----------------------------------------------"
echo "  Newly processed issues: $unprocessed_before"
echo "----------------------------------------------"
echo ""

# ---------------------------------------------
# Final Summary
# ---------------------------------------------
echo "=============================================="
echo "  PIPELINE COMPLETE"
echo "=============================================="
echo ""
echo "  Board ID:                  $BOARD_ID"
echo "  Total issues in backlog:   $total_issues"
echo "  Newly processed:           $unprocessed_before"
echo "  Previously processed:      $processed_issues"
echo "  Duplicate relationships:   $total_duplicate_relationships"
echo "  Overlap relationships:     $total_overlap_relationships"
echo ""
echo "  Priority breakdown:"
echo "    Highest: $priority_highest | High: $priority_high | Medium: $priority_medium | Low: $priority_low | Lowest: $priority_lowest"
echo ""
echo "  Output file: $OUTPUT_FILE"
echo ""
echo "=============================================="
