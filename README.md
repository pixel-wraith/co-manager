# Co-Manager

Co-Manager is an AI-powered Jira backlog analysis pipeline. Given a Jira board ID, it fetches all issues from active and future sprints, then uses Claude to generate concise summaries, estimate priorities, and detect duplicate or overlapping issues. The pipeline is incremental — it only processes new or changed issues on subsequent runs, making it efficient to run regularly. All results are stored locally as enriched JSON, giving you a quick, AI-augmented view of your backlog without modifying anything in Jira.

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

## How the Pipeline Works

The main entry point is `process-backlog.sh`, which orchestrates five sequential steps. Each step reads and writes to a single JSON file at `~/.co-manager/<BOARD_ID>-backlog-issues.json`.

### Step 1: Fetch Backlog Issues from Jira

The pipeline queries the Jira Agile REST API to discover all active and future sprints for the given board, then paginates through each sprint to collect every issue. Issues that appear in multiple sprints are deduplicated by key, and completed issues (status category "Done") are filtered out.

If a local JSON file already exists from a previous run, the fresh data is merged with it:
- **New issues** (not seen before) are added and marked as unprocessed.
- **Changed issues** (where `fields.updated` differs from the local copy) have their AI-generated metadata cleared so they will be re-analyzed.
- **Unchanged issues** retain all previously generated summaries, priorities, and relationship data.
- **Removed issues** (present locally but no longer in Jira) are dropped from the file.

### Step 2: Generate AI Summaries

Each unprocessed issue is sent to Claude (via the `claude` CLI) with its title and description. Claude returns a 1–2 sentence summary focusing on what needs to be done and why. The summary is stored as the `__summary` property on the issue.

Descriptions in Atlassian Document Format (ADF) are flattened to plain text before prompting. Long descriptions are truncated to 2,000 characters to stay within token limits.

### Step 3: Estimate Priorities

Each unprocessed issue is sent to Claude with its title, AI summary, and current Jira priority. Claude evaluates factors like business impact, number of users affected, blocking potential, security implications, and technical debt to return one of five priority levels: Highest, High, Medium, Low, or Lowest. The result is stored as `__priority`. Invalid responses default to Medium.

### Step 4: Detect Duplicates and Overlaps

All unprocessed issues are compared against the entire backlog (both new and previously processed issues) in a single Claude prompt. Claude identifies two kinds of relationships:
- **Duplicates** — issues that describe the same work.
- **Overlaps** — issues that are distinct but share related scope, with a description of how they relate.

Relationships are stored bidirectionally: both sides of a duplicate or overlap pair are updated. Stale references (pointing to issues that no longer exist in the backlog) are cleaned up before the analysis runs.

### Step 5: Mark Issues as Processed

All issues that were analyzed in steps 2–4 are marked with `__processed: true` and a `processedAt` timestamp is added to the file. On the next run, these issues will be skipped unless their content has changed in Jira.

The pipeline finishes with a summary report showing totals for issues fetched, summaries generated, priority distribution, and duplicate/overlap relationships found.

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
