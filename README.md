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

### Global Alias (macOS)

To run `process-backlog` from any directory, add an alias to your shell configuration:

1. Open your shell config file:
   ```bash
   # For zsh (default on macOS)
   open -e ~/.zshrc

   # For bash
   open -e ~/.bash_profile
   ```

2. Add the following line (update the path to match your installation):
   ```bash
   alias process-backlog="/path/to/co-manager/process-backlog.sh"
   ```

3. Reload your shell configuration:
   ```bash
   # For zsh
   source ~/.zshrc

   # For bash
   source ~/.bash_profile
   ```

4. Now you can run the pipeline from anywhere:
   ```bash
   process-backlog 123
   ```

## Data Directory

All output files are stored in `~/.co-manager/`. This directory is created automatically when you run the pipeline.

## Incremental Processing

The pipeline supports incremental processing, making it efficient to run repeatedly:

- **New issues** are fully processed (summary, priority, duplicate detection)
- **Unchanged issues** are skipped (marked with `__processed: true`)
- **Changed issues** are automatically re-processed when their content changes in Jira
- **Completed issues** (removed from Jira backlog) are automatically removed from the local file
- **Stale references** are cleaned up (e.g., if issue A was a duplicate of B, and B is completed, the reference is removed from A)

## Quick Start

Run the full analysis pipeline with a single command:

```bash
./process-backlog.sh <BOARD_ID>
```

Example:
```bash
./process-backlog.sh 123
```

This will:
1. Fetch all issues from the board's backlog
2. Generate AI summaries for each issue
3. Estimate priority for each issue
4. Detect duplicates and overlapping issues
5. Output results to `~/.co-manager/<BOARD_ID>-backlog-issues.json`

## Scripts

### process-backlog.sh

The main pipeline script that runs all analysis steps in sequence.

```bash
./process-backlog.sh <BOARD_ID>
```

Outputs a summary after each step and a final report with:
- Total issues retrieved
- Summaries generated
- Priorities estimated (with distribution breakdown)
- Duplicate and overlap relationships found

### fetch-jira-backlog.sh

Fetches all issues from a Jira board's backlog using the Jira REST API.

```bash
./fetch-jira-backlog.sh <BOARD_ID>
```

- Handles pagination automatically
- Merges with existing local data, preserving processed state
- Detects content changes and marks changed issues for re-processing
- Removes issues no longer in the Jira backlog
- Outputs to `~/.co-manager/<BOARD_ID>-backlog-issues.json`

### summarize-backlog-issues.sh

Generates concise AI summaries for each issue using Claude.

```bash
./summarize-backlog-issues.sh <BACKLOG_JSON_FILE>
```

- Extracts title and description from each issue
- Handles both plain text and Atlassian Document Format (ADF)
- Adds `__summary` property to each issue
- Skips already-processed issues (`__processed: true`)

### estimate-priorities.sh

Estimates priority for each issue using Claude based on the issue content.

```bash
./estimate-priorities.sh <BACKLOG_JSON_FILE>
```

- Analyzes issue summary to estimate business priority
- Uses standard Jira priority levels: Highest, High, Medium, Low, Lowest
- Considers factors like business impact, urgency, and user impact
- Adds `__priority` property to each issue
- Skips already-processed issues (`__processed: true`)
- Outputs priority distribution summary

### detect-duplicates.sh

Analyzes all issue summaries to identify duplicates and overlaps.

```bash
./detect-duplicates.sh <BACKLOG_JSON_FILE>
```

- Compares unprocessed issues against ALL issues (new and existing)
- Adds `duplicates` array for exact duplicate issues
- Adds `overlaps_with` array for related issues with overlap details
- Updates both sides of any relationship found
- Cleans up stale references (removes IDs that no longer exist)

## Output Format

The output JSON file contains:

```json
{
  "boardId": "123",
  "fetchedAt": "2026-03-06T12:00:00Z",
  "summarizedAt": "2026-03-06T12:05:00Z",
  "prioritiesEstimatedAt": "2026-03-06T12:07:00Z",
  "duplicatesAnalyzedAt": "2026-03-06T12:10:00Z",
  "processedAt": "2026-03-06T12:10:00Z",
  "totalIssues": 50,
  "issues": [
    {
      "key": "PROJ-123",
      "fields": {
        "summary": "Issue title",
        "description": "Issue description...",
        "updated": "2026-03-06T10:00:00.000+0000"
      },
      "__processed": true,
      "__summary": "AI-generated concise summary of the issue.",
      "__priority": "High",
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
