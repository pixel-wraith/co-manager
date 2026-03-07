# Co-Manager

A toolset for analyzing Jira backlogs using AI to generate summaries and detect duplicate or overlapping issues.

## Prerequisites

- **curl** - For making API requests to Jira
- **jq** - For JSON processing
- **claude** - Claude Code CLI, installed and authenticated

## Setup

Set the following environment variables:

```bash
export JIRA_BASE_URL="https://yourcompany.atlassian.net"
export JIRA_EMAIL="your-email@example.com"
export JIRA_API_TOKEN="your-api-token"
```

Generate your Jira API token at: https://id.atlassian.com/manage-profile/security/api-tokens

## Quick Start

Run the full analysis pipeline with a single command:

```bash
./analyze-backlog.sh <BOARD_ID>
```

Example:
```bash
./analyze-backlog.sh 123
```

This will:
1. Fetch all issues from the board's backlog
2. Generate AI summaries for each issue
3. Detect duplicates and overlapping issues
4. Output results to `<BOARD_ID>-backlog-issues.json`

## Scripts

### analyze-backlog.sh

The main pipeline script that runs all analysis steps in sequence.

```bash
./analyze-backlog.sh <BOARD_ID>
```

Outputs a summary after each step and a final report with:
- Total issues retrieved
- Summaries generated
- Duplicate and overlap relationships found

### fetch-jira-backlog.sh

Fetches all issues from a Jira board's backlog using the Jira REST API.

```bash
./fetch-jira-backlog.sh <BOARD_ID>
```

- Handles pagination automatically
- Outputs to `<BOARD_ID>-backlog-issues.json`

### summarize-backlog-issues.sh

Generates concise AI summaries for each issue using Claude.

```bash
./summarize-backlog-issues.sh <BACKLOG_JSON_FILE>
```

- Extracts title and description from each issue
- Handles both plain text and Atlassian Document Format (ADF)
- Adds `__summary` property to each issue
- Skips already-summarized issues (idempotent)

### detect-duplicates.sh

Analyzes all issue summaries to identify duplicates and overlaps.

```bash
./detect-duplicates.sh <BACKLOG_JSON_FILE>
```

- Sends all summaries to Claude for analysis
- Adds `duplicates` array for exact duplicate issues
- Adds `overlaps_with` array for related issues with overlap details

## Output Format

The output JSON file contains:

```json
{
  "boardId": "123",
  "fetchedAt": "2026-03-06T12:00:00Z",
  "summarizedAt": "2026-03-06T12:05:00Z",
  "duplicatesAnalyzedAt": "2026-03-06T12:10:00Z",
  "totalIssues": 50,
  "issues": [
    {
      "key": "PROJ-123",
      "fields": {
        "summary": "Issue title",
        "description": "Issue description..."
      },
      "__summary": "AI-generated concise summary of the issue.",
      "duplicates": ["PROJ-456"],
      "overlaps_with": [
        {
          "id": "PROJ-789",
          "details": "Both issues involve user authentication..."
        }
      ]
    }
  ]
}
```

## License

MIT
