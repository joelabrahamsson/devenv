---
name: implement-plan
description: Implement a plan file using strict TDD workflow, then run adversarial code reviews and offer next steps.
argument-hint: "[path to plan file]"
user-invocable: true
allowed-tools: "Write Edit Read Glob Grep Bash Agent AskUserQuestion TaskCreate TaskUpdate TaskList TaskGet"
effort: high
---

# Implement Plan

You are orchestrating the implementation of a plan file. Implementation is delegated to Sonnet subagents for efficiency, while you coordinate, track progress, and handle reviews.

IMPORTANT: This workflow is designed to flow without unnecessary permission prompts. The tools listed in `allowed-tools` above are pre-authorized — use them without hesitation.

## Step 1: Load the Plan

⚠️ CRITICAL: Your role is ORCHESTRATOR. Do NOT explore the codebase, read source files, or investigate implementation details yourself. Subagents will do all of that. You ONLY need to:

1. Locate the plan file:
   - If `$ARGUMENTS` contains a path, use it
   - If not, check if a plan path is known from the current conversation context
   - If neither, look in `docs/plans/` for the most recent plan file
   - If multiple plan files exist, ask the user which one to implement

2. Read the plan file — note the step numbers/titles and the plan file path. Do NOT read any other files.

3. Identify the project's test command from CLAUDE.md or AGENTS.md (e.g., `npm test`, `pytest`). If not documented, ask the user.

Then immediately proceed to Step 2. Do NOT read source code, types, components, or any other project files.

## Step 2: Create Task List

Create a task for each implementation step in the plan using TaskCreate. Each task should:
- Have a clear subject matching the plan step
- Use an activeForm that describes what's being done (e.g., "Implementing GET /api/tags endpoint")

## Step 3: TDD Implementation via Subagents

Work through each task in order. For each task (or group of closely related tasks):

1. Mark the task as `in_progress` using TaskUpdate

2. Launch an Agent with `model: sonnet` to implement the step. The agent prompt should tell it to:
   - Read the plan file at `<plan-file-path>` and implement step N (specify which step number(s))
   - Read the project's CLAUDE.md / AGENTS.md for conventions and patterns
   - Follow strict TDD: RED (write failing tests) → RUN (confirm failure) → GREEN (minimal implementation) → RUN (confirm pass) → REFACTOR (if needed)
   - Report back: what files were created/modified, what tests were added, whether all tests pass

   Also include in the prompt:
   - The test command to use (from the project's docs or inferred from the codebase)
   - A short list of files created/modified by previous steps (so the agent has context on what already exists)

3. When the agent completes, review its summary. If it reports failing tests or issues:
   - Try launching another Sonnet agent to fix the specific issue
   - If it fails after 2 attempts, stop and ask the user for guidance via AskUserQuestion

4. Mark the task as `completed`

5. Move to the next task only after the previous step's tests are confirmed green

**Grouping steps:** If the plan has small, closely related steps (e.g., "add a type" then "add a function using that type"), you can group 2-3 into a single agent call. Don't group more than 3, and don't group steps that are conceptually independent.

## Step 4: Verification

Once all tasks are complete, run the full test suite yourself (via Bash) to confirm everything is green end-to-end. This catches any issues between steps that individual agents might have missed.

If tests fail, launch a Sonnet agent to investigate and fix, providing it with the test output and relevant file paths.

## Step 5: Code Review

Once all tests pass, launch adversarial code reviews.

CRITICAL: You MUST launch both reviews in the SAME message using multiple tool calls. Do NOT launch one, wait for it, then launch the other.

Before launching, prepare the copilot prompt file (prerequisite for the Bash call).

### 5a: Claude Code Review Agent

Launch the `code-reviewer` agent with a prompt that includes:
- The path to the plan file — tell it to read the file itself
- The full git diff of all changes (`git diff` for unstaged, or `git diff HEAD` if staged) — the agent can't run git, so this must be included in the prompt

Do NOT paste the plan contents into the agent prompt. The agent has read tools and should read the plan and CLAUDE.md/AGENTS.md directly.

### 5b: GitHub Copilot CLI Review

Write the review prompt to `/tmp/copilot-code-review-prompt.txt`. Include:
- The path to the plan file — instruct copilot to read it with its `view` tool
- The full git diff (copilot can't run git, so this must be in the prompt)
- The paths to CLAUDE.md and AGENTS.md — instruct copilot to read them with its `view` tool
- Instructions to review the implementation for: bugs, security issues, test coverage gaps, code quality, adherence to project conventions, performance issues

Do NOT paste the plan or CLAUDE.md/AGENTS.md contents into the prompt — copilot should read them directly.

The prompt should ask copilot to structure its response as: Critical Issues, Suggested Improvements, Minor Observations, and Positive Aspects.

Run copilot:
```
cd /workspace && copilot -p "$(cat /tmp/copilot-code-review-prompt.txt)" \
  --model gpt-5.4 \
  --available-tools='view,glob,rg' \
  --no-ask-user
```

Notes:
- Run copilot in the background using `run_in_background: true` with a Bash timeout of 900000ms (15 minutes)
- If the Claude review finishes first and copilot is still running, inform the user. If it's been more than 5 minutes, note that it's taking longer than expected.
- If copilot times out after 15 minutes, ask the user whether to proceed with only the Claude review or retry.

## Step 6: Consolidate and Fix

Once BOTH reviews are complete:
1. Consolidate feedback — group by severity, deduplicate, note consensus and disagreements
2. Present consolidated feedback to the user
3. Go through each piece of feedback:
   - **Obviously valid**: Launch a Sonnet agent to fix it
   - **Obviously dismissible**: Dismiss it, briefly noting why
   - **Ambiguous**: Present to user with your assessment and ask
4. Run the full test suite again after fixes to confirm nothing broke

## Step 7: Next Steps

All implementation and review is complete. Before presenting options, assess whether this implementation introduced decisions, patterns, or reasoning that would provide valuable context for future sessions (e.g., new architectural patterns, non-obvious trade-offs, convention changes). If so, suggest the `/finalize` option.

Determine the current git state:
- What branch are we on?
- Is it `main` or a feature branch?
- Are there unstaged/staged changes?

Present options to the user, marking one as **(suggested)** based on your ADR assessment:

### If an ADR would be valuable:

1. Run `/finalize` to create an ADR, clean up, and commit/PR **(suggested)**
2. Remove plan file + commit and push to current branch
3. Remove plan file + create branch + push + create PR (if on main), or commit + push + create PR (if on branch)

### If an ADR is not needed:

1. Remove plan file + commit and push to current branch
2. Remove plan file + create branch + push + create PR (if on main), or commit + push + create PR (if on branch)
3. Run `/finalize` if you'd like to create an ADR anyway

For options that remove the plan file, delete the plan file from `docs/plans/` and include that deletion in the commit.

When committing, stage all implementation changes plus the plan file deletion. Write a clear commit message summarizing what was implemented and why.

When creating a PR, include a summary of what was implemented, the test coverage, and any notable decisions.
