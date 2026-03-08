#!/usr/bin/env bash
#
# Fetch all issues from a Jira board's active and future sprints
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
DATA_DIR="${HOME}/.co-manager"

# Validate inputs
if [[ -z "$BOARD_ID" ]]; then
    echo "Error: Board ID is required"
    echo "Usage: $0 <BOARD_ID>"
    exit 1
fi

# Create data directory if it doesn't exist
mkdir -p "$DATA_DIR"

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
OUTPUT_FILE="${DATA_DIR}/${BOARD_ID}-backlog-issues.json"

# Temp files for handling large JSON data
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

FRESH_ISSUES_FILE="${TEMP_DIR}/fresh_issues.json"
MERGED_ISSUES_FILE="${TEMP_DIR}/merged_issues.json"

# Initialize fresh issues file
echo '[]' > "$FRESH_ISSUES_FILE"

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

# Helper function to paginate through all issues for a given endpoint
# Writes results directly to a temp file to avoid shell variable size limits
fetch_sprint_issues() {
    local endpoint="$1"
    local sprint_file="${TEMP_DIR}/sprint_issues.json"
    local start_at=0
    local total=0
    local first_request=true

    echo '[]' > "$sprint_file"

    while true; do
        local separator="?"
        if [[ "$endpoint" == *"?"* ]]; then
            separator="&"
        fi

        local response
        response=$(jira_request "${endpoint}${separator}startAt=${start_at}&maxResults=${MAX_RESULTS}")

        # Check for errors
        if echo "$response" | jq -e '.errorMessages' > /dev/null 2>&1; then
            echo "    Error from Jira API:"
            echo "$response" | jq -r '.errorMessages[]'
            return 1
        fi

        # On first request, get the total count
        if [[ "$first_request" == "true" ]]; then
            total=$(echo "$response" | jq -r '.total // 0')
            first_request=false
        fi

        # Extract issues from this page and append to sprint file
        local page_file="${TEMP_DIR}/page.json"
        echo "$response" | jq -c '.issues // []' > "$page_file"
        local page_count
        page_count=$(jq 'length' "$page_file")

        # Merge page into sprint file
        jq -s 'add' "$sprint_file" "$page_file" > "${sprint_file}.tmp" && mv "${sprint_file}.tmp" "$sprint_file"

        # Calculate next start position
        start_at=$((start_at + MAX_RESULTS))

        # Check if we've fetched all issues
        if [[ $start_at -ge $total ]] || [[ $page_count -eq 0 ]]; then
            break
        fi
    done
}

echo "Fetching issues for board ${BOARD_ID}..."

# Step 1: Get all active and future sprints
echo "  Fetching active and future sprints..."
sprints_response=$(jira_request "/rest/agile/1.0/board/${BOARD_ID}/sprint?state=active,future&maxResults=50")

if echo "$sprints_response" | jq -e '.errorMessages' > /dev/null 2>&1; then
    echo "Error from Jira API:"
    echo "$sprints_response" | jq -r '.errorMessages[]'
    exit 1
fi

sprint_count=$(echo "$sprints_response" | jq '.values | length')
echo "  Found $sprint_count active/future sprints"

# Step 2: Fetch issues from each sprint
for i in $(seq 0 $((sprint_count - 1))); do
    sprint_id=$(echo "$sprints_response" | jq -r ".values[$i].id")
    sprint_name=$(echo "$sprints_response" | jq -r ".values[$i].name")
    sprint_state=$(echo "$sprints_response" | jq -r ".values[$i].state")

    echo "  Fetching issues from sprint: $sprint_name ($sprint_state)..."
    fetch_sprint_issues "/rest/agile/1.0/sprint/${sprint_id}/issue"

    sprint_issue_count=$(jq 'length' "${TEMP_DIR}/sprint_issues.json")
    echo "    Found $sprint_issue_count issues"

    # Merge sprint issues into all issues
    jq -s 'add' "$FRESH_ISSUES_FILE" "${TEMP_DIR}/sprint_issues.json" > "${FRESH_ISSUES_FILE}.tmp" && mv "${FRESH_ISSUES_FILE}.tmp" "$FRESH_ISSUES_FILE"
done

# Deduplicate issues by key (in case an issue appears in multiple sprints)
jq '[group_by(.key)[] | .[0]]' "$FRESH_ISSUES_FILE" > "${FRESH_ISSUES_FILE}.tmp" && mv "${FRESH_ISSUES_FILE}.tmp" "$FRESH_ISSUES_FILE"

# Get the final count
final_count=$(jq 'length' "$FRESH_ISSUES_FILE")

# Check if we have existing data to merge with
if [[ -f "$OUTPUT_FILE" ]]; then
    echo "Merging with existing data..."

    # Merge fresh issues with existing data, preserving custom properties
    jq --slurpfile existing <(jq '.issues // []' "$OUTPUT_FILE") '
        # Build a map of existing issues by key
        ($existing[0] | map({key: .key, value: .}) | from_entries) as $existing_map |

        # Process each fresh issue
        [
            .[] |
            .key as $key |

            # Check if this issue exists in our local data
            if $existing_map[$key] then
                # Get the existing issue
                $existing_map[$key] as $old |

                # Check if content has changed (compare updated timestamp)
                if .fields.updated != $old.fields.updated then
                    # Content changed - merge fresh data but clear __processed flag
                    . + {
                        __summary: null,
                        __priority: null,
                        __processed: false,
                        duplicates: null,
                        overlaps_with: null
                    }
                else
                    # Content unchanged - preserve all custom properties
                    . + {
                        __summary: $old.__summary,
                        __priority: $old.__priority,
                        __processed: ($old.__processed // false),
                        duplicates: $old.duplicates,
                        overlaps_with: $old.overlaps_with
                    }
                end
            else
                # New issue - mark as unprocessed
                . + {__processed: false}
            end
        ]
    ' "$FRESH_ISSUES_FILE" > "$MERGED_ISSUES_FILE"

    # Count statistics
    new_count=$(jq '[.[] | select(.__processed == false and .__summary == null)] | length' "$MERGED_ISSUES_FILE")
    changed_count=$(jq '[.[] | select(.__processed == false and .__summary != null)] | length' "$MERGED_ISSUES_FILE")
    preserved_count=$(jq '[.[] | select(.__processed == true)] | length' "$MERGED_ISSUES_FILE")
    removed_count=$(jq --slurpfile fresh "$FRESH_ISSUES_FILE" '
        [.issues[].key] as $old_keys |
        [$fresh[0][].key] as $new_keys |
        [$old_keys[] | select(. as $k | $new_keys | index($k) | not)] | length
    ' "$OUTPUT_FILE")

    echo "  New issues: $new_count"
    echo "  Changed issues (will reprocess): $changed_count"
    echo "  Unchanged issues (preserved): $preserved_count"
    echo "  Removed issues (completed): $removed_count"

    cp "$MERGED_ISSUES_FILE" "$FRESH_ISSUES_FILE"
else
    echo "No existing data found, creating new file..."
    # Mark all issues as unprocessed
    jq '[.[] | . + {__processed: false}]' "$FRESH_ISSUES_FILE" > "${FRESH_ISSUES_FILE}.tmp" && mv "${FRESH_ISSUES_FILE}.tmp" "$FRESH_ISSUES_FILE"
fi

# Build the final output JSON
jq -n \
    --arg board_id "$BOARD_ID" \
    --arg fetched_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --argjson total "$final_count" \
    --slurpfile issues "$FRESH_ISSUES_FILE" \
    '{
        boardId: $board_id,
        fetchedAt: $fetched_at,
        totalIssues: $total,
        issues: $issues[0]
    }' > "$OUTPUT_FILE"

echo "Successfully fetched ${final_count} issues"
echo "Output written to: ${OUTPUT_FILE}"
