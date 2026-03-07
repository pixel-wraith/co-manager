#!/usr/bin/env bash
#
# Analyze Jira Backlog - Complete Pipeline
#
# Runs the full backlog analysis pipeline:
#   1. Fetch all issues from a Jira board's backlog
#   2. Generate AI summaries for each issue
#   3. Detect duplicates and overlapping issues
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
#   ./analyze-backlog.sh <BOARD_ID>
#
# Example:
#   ./analyze-backlog.sh 123
#

set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
BOARD_ID="${1:-}"

# Validate inputs
if [[ -z "$BOARD_ID" ]]; then
    echo "Error: Board ID is required"
    echo "Usage: $0 <BOARD_ID>"
    exit 1
fi

OUTPUT_FILE="${BOARD_ID}-backlog-issues.json"

echo "=============================================="
echo "  Jira Backlog Analysis Pipeline"
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
echo ""
echo "----------------------------------------------"
echo "  STEP 1 SUMMARY"
echo "----------------------------------------------"
echo "  Total issues retrieved from Jira: $total_issues"
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
# Step 3: Detect duplicates and overlaps
# ---------------------------------------------
echo "=============================================="
echo "  Step 3: Detecting Duplicates & Overlaps"
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
echo "  STEP 3 SUMMARY"
echo "----------------------------------------------"
echo "  Issues flagged as duplicates: $duplicate_issues"
echo "  Issues flagged with overlaps: $overlap_issues"
echo "  Total duplicate relationships: $total_duplicate_relationships"
echo "  Total overlap relationships: $total_overlap_relationships"
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
echo "  Total issues retrieved:    $total_issues"
echo "  Summaries generated:       $issues_with_summary"
echo "  Duplicate relationships:   $total_duplicate_relationships"
echo "  Overlap relationships:     $total_overlap_relationships"
echo ""
echo "  Output file: $OUTPUT_FILE"
echo ""
echo "=============================================="
