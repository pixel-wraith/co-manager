#!/usr/bin/env bash
#
# Fetch all issues from a Jira board's backlog
#
# Required environment variables:
#   JIRA_BASE_URL  - Your Jira instance URL (e.g., https://yourcompany.atlassian.net)
#   JIRA_EMAIL     - Your Jira account email
#   JIRA_API_TOKEN - Your Jira API token (generate at https://id.atlassian.com/manage-profile/security/api-tokens)
#
# Usage:
#   ./fetch-jira-backlog.sh <BOARD_ID>
#
# Example:
#   ./fetch-jira-backlog.sh 123
#

set -euo pipefail

# Configuration
BOARD_ID="${1:-}"
MAX_RESULTS=100  # Jira's max per request

# Validate inputs
if [[ -z "$BOARD_ID" ]]; then
    echo "Error: Board ID is required"
    echo "Usage: $0 <BOARD_ID>"
    exit 1
fi

if [[ -z "${JIRA_BASE_URL:-}" ]]; then
    echo "Error: JIRA_BASE_URL environment variable is not set"
    exit 1
fi

if [[ -z "${JIRA_EMAIL:-}" ]]; then
    echo "Error: JIRA_EMAIL environment variable is not set"
    exit 1
fi

if [[ -z "${JIRA_API_TOKEN:-}" ]]; then
    echo "Error: JIRA_API_TOKEN environment variable is not set"
    exit 1
fi

# Remove trailing slash from base URL if present
JIRA_BASE_URL="${JIRA_BASE_URL%/}"

# Output file
OUTPUT_FILE="${BOARD_ID}-backlog-issues.json"

# Build auth header (Base64 encoded email:token)
AUTH_HEADER=$(echo -n "${JIRA_EMAIL}:${JIRA_API_TOKEN}" | base64)

# Function to make authenticated API requests
jira_request() {
    local endpoint="$1"
    curl -s -X GET \
        -H "Authorization: Basic ${AUTH_HEADER}" \
        -H "Content-Type: application/json" \
        "${JIRA_BASE_URL}${endpoint}"
}

echo "Fetching backlog issues for board ${BOARD_ID}..."

# Initialize variables for pagination
start_at=0
total=0
all_issues="[]"
first_request=true

# Paginate through all results
while true; do
    echo "  Fetching issues starting at ${start_at}..."

    # Fetch a page of issues
    response=$(jira_request "/rest/agile/1.0/board/${BOARD_ID}/backlog?startAt=${start_at}&maxResults=${MAX_RESULTS}")

    # Check for errors
    if echo "$response" | jq -e '.errorMessages' > /dev/null 2>&1; then
        echo "Error from Jira API:"
        echo "$response" | jq -r '.errorMessages[]'
        exit 1
    fi

    # On first request, get the total count
    if [[ "$first_request" == "true" ]]; then
        total=$(echo "$response" | jq -r '.total // 0')
        echo "  Total issues in backlog: ${total}"
        first_request=false
    fi

    # Extract issues from this page
    page_issues=$(echo "$response" | jq -c '.issues // []')
    page_count=$(echo "$page_issues" | jq 'length')

    # Merge issues into our collection
    all_issues=$(echo "$all_issues" "$page_issues" | jq -s 'add')

    # Calculate next start position
    start_at=$((start_at + MAX_RESULTS))

    # Check if we've fetched all issues
    if [[ $start_at -ge $total ]] || [[ $page_count -eq 0 ]]; then
        break
    fi
done

# Get the final count
final_count=$(echo "$all_issues" | jq 'length')

# Build the final output JSON
output_json=$(jq -n \
    --arg board_id "$BOARD_ID" \
    --arg fetched_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --argjson total "$total" \
    --argjson issues "$all_issues" \
    '{
        boardId: $board_id,
        fetchedAt: $fetched_at,
        totalIssues: $total,
        issues: $issues
    }')

# Write to file
echo "$output_json" > "$OUTPUT_FILE"

echo "Successfully fetched ${final_count} issues"
echo "Output written to: ${OUTPUT_FILE}"
