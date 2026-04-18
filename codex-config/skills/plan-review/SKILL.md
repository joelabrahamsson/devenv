---
name: plan-review
description: Create an implementation plan with adversarial review from both a Codex subagent and Claude CLI, then revise and optionally implement. Invoke with $plan-review followed by a description of what to plan.
---

# Plan with Adversarial Review

You are orchestrating a planning workflow with adversarial review. Follow these steps precisely.

## Step 1: Establish the Task

If arguments were provided (`$ARGUMENTS`), use them as the description of what to plan. Present this to the user and confirm it captures their intent before proceeding.

If no arguments were provided, ask the user what they would like to plan. Ask as an open-ended question — do NOT present a list of categories or options to choose from.

## Step 2: Create the Plan

### 2a: Understand the codebase

Start by reading the project's AGENTS.md (and CLAUDE.md, ONBOARDING.md if they exist) in the workspace root. These describe the project's architecture, key directories, patterns, and conventions.

**If convention docs exist with architecture/structure information:**
- Do NOT do broad codebase scans
- Use the information in the docs to read the specific files and directories relevant to the task directly
- Only investigate further if something described in the docs doesn't match what you find

**If no convention docs exist or they lack architecture information:**
- Explore the specific area of the codebase relevant to the task — not the entire project

### 2b: Design the plan

- Ask the user clarifying questions as needed
- Design a step-by-step implementation plan

Read `~/workflows/planning/plan-format.md` for the required plan file format and TDD structure. Follow it exactly.

Once the plan is complete, write it to the location specified in plan-format.md.

⚠️ CRITICAL: Do NOT ask the user to review the plan. Do NOT present the plan for approval. You MUST complete Steps 3, 4, and 5 (adversarial reviews, consolidation, and revision) BEFORE presenting anything to the user. Tell the user the plan is written and you're now sending it for adversarial review, then immediately proceed to Step 3.

## Step 3: Parallel Adversarial Reviews

CRITICAL: You MUST launch both reviews simultaneously. Use `spawn_agent` for the Codex adversarial review and `shell` for the Claude CLI review in the same turn.

Before launching, write the Claude review prompt to a temporary file (prerequisite for the shell call).

### 3a: Codex Adversarial Subagent Review

Read `references/adversarial-reviewer.md` for the subagent instructions template. Use `spawn_agent` with a prompt that includes:
- The instructions from the reference file
- The original goal/task description
- The path to the plan file

### 3b: Claude CLI Review (second opinion)

Write the review prompt to a temporary file (e.g., `/tmp/claude-plan-review-prompt.txt`). The prompt should contain:
- The original goal/task description (refined version after user Q&A)
- The path to the plan file — instruct Claude to read it
- The paths to AGENTS.md and CLAUDE.md (if they exist) — instruct Claude to read them
- The path to `~/workflows/planning/review-criteria.md` — instruct Claude to read it for the review checklist
- Do NOT paste file contents into the prompt — Claude has file access and should read files directly

Run Claude CLI:
```
claude -p "$(cat /tmp/claude-plan-review-prompt.txt)" --allowedTools Read,Glob,Grep --model sonnet --effort high
```

Notes:
- Run the Claude command in the background with a 15-minute timeout
- If the Codex subagent review finishes first and Claude is still running, inform the user
- If Claude times out after 15 minutes, inform the user and ask whether to proceed with only the Codex review or retry

## Step 4: Consolidate Feedback

Once BOTH reviews have completed, consolidate the feedback:
- Group issues by severity: Critical, Suggested Improvements, Minor
- Deduplicate — if both reviewers flagged the same issue, note the consensus
- Note where reviewers disagree
- Present the consolidated feedback to the user in a clear summary

## Step 5: Revise the Plan

Go through each piece of feedback:

- **Obviously valid feedback**: Implement the change to the plan without asking.
- **Obviously dismissible feedback**: Dismiss it, briefly noting why.
- **Ambiguous feedback**: Present it to the user with your assessment and ask whether to incorporate it.

Update the plan file with the revisions. Note what changed and why at the bottom of the file under a "## Revision Notes" section.

## Step 6: Offer Implementation

⚠️ CRITICAL: Do NOT start implementing automatically. You MUST present the options below and WAIT for the user to choose.

The ONLY exception: if the user explicitly included instructions like "implement after review" or "go ahead and implement" in their original request. In that case, choose Option 3 (auto-implement) automatically.

Present the user with clear options:

1. **Implement now** (keep current context)
2. **Save plan and stop** (just keep the plan file for later)

### Option 1: Implement now
- Begin implementation following the plan and the TDD implementation rules below

### Option 2: Save plan and stop
- Confirm the plan file path to the user

### Option 3: Auto-implement (only when user explicitly requested it)
- This option is NEVER presented to the user
- Begin implementation following the TDD implementation rules below
- After implementation is complete, delete the plan file

### TDD Implementation Rules

When implementing the plan, follow each step's TDD cycle strictly:

1. Write the test(s) described in the RED phase. Do NOT write any implementation code yet.
2. Run the tests. Confirm they fail. If they pass unexpectedly, investigate.
3. Write the implementation code described in the GREEN phase. Write the minimum code needed.
4. Run the tests. Confirm they pass. If they fail, fix the implementation (not the tests, unless the test itself was wrong).
5. Refactor if the plan calls for it, running tests again after.
6. Move to the next step only after all tests for the current step are green.
