---
name: implement-plan
description: Implement a plan file using strict TDD workflow, then run adversarial code reviews and offer next steps. Invoke with $implement-plan followed by the path to a plan file.
---

# Implement Plan

You are orchestrating the implementation of a plan file. Implementation is delegated to subagents for efficiency, while you coordinate, track progress, and handle reviews.

## Step 1: Load the Plan

Your role is ORCHESTRATOR. Do NOT explore the codebase or read source files yourself. Subagents will do that.

1. Locate the plan file:
   - If `$ARGUMENTS` contains a path, use it
   - If not, check if a plan path is known from the current conversation context
   - If neither, look in `docs/plans/` for the most recent plan file
   - If multiple plan files exist, ask the user which one to implement

2. Read the plan file — note the step numbers/titles and the plan file path. Do NOT read any other files.

3. Identify the project's test command from AGENTS.md or CLAUDE.md (e.g., `npm test`, `pytest`). If not documented, ask the user.

Then immediately proceed to Step 2.

## Step 2: Track Progress

Use `update_plan` to create a visible plan with a task for each implementation step. Update the plan status as you progress through steps.

## Step 3: TDD Implementation via Subagents

Work through each step in order. For each step (or group of closely related steps):

1. Update the plan to mark the step as in progress

2. Use `spawn_agent` to launch a subagent to implement the step. The prompt should tell it to:
   - Read the plan file at `<plan-file-path>` and implement step N (specify which)
   - Read the project's AGENTS.md / CLAUDE.md for conventions and patterns
   - Follow strict TDD: RED (write failing tests) → RUN (confirm failure) → GREEN (minimal implementation) → RUN (confirm pass) → REFACTOR (if needed)
   - Do NOT spawn further subagents
   - Report back: what files were created/modified, what tests were added, whether all tests pass

   Also include:
   - The test command to use
   - A short list of files created/modified by previous steps (context for the agent)

3. Use `wait_agent` to collect the result. If it reports failing tests:
   - Spawn another subagent to fix the specific issue
   - If it fails after 2 attempts, ask the user for guidance

4. Update the plan to mark the step as completed

5. Move to the next step only after the previous step's tests are confirmed green

**Grouping steps:** Group 2-3 small, closely related steps into a single subagent call. Don't group more than 3 or steps that are conceptually independent.

## Step 4: Verification

Once all steps are complete, run the full test suite yourself (via `shell`) to confirm everything is green end-to-end.

If tests fail, spawn a subagent to investigate and fix, providing the test output and relevant file paths.

## Step 5: Code Review

Once all tests pass, launch adversarial code reviews. Launch BOTH reviews simultaneously.

Before launching, prepare the Claude review prompt file (prerequisite for the shell call).

### 5a: Codex Code Review Subagent

Read `references/code-reviewer.md` for the subagent instructions template. Use `spawn_agent` with a prompt that includes:
- The instructions from the reference file
- The path to the plan file

### 5b: Claude CLI Review (second opinion)

Write the review prompt to `/tmp/claude-code-review-prompt.txt`. Include:
- The path to the plan file — instruct Claude to read it
- The full git diff (Claude can read files and run commands, but include the diff path or tell it to read the diff)
- Instruction to read `~/workflows/planning/code-review-criteria.md` for the review checklist
- The paths to AGENTS.md and CLAUDE.md — instruct Claude to read them

Do NOT paste file contents into the prompt — Claude should read files directly.

Run Claude CLI:
```
claude -p "$(cat /tmp/claude-code-review-prompt.txt)" --allowedTools Read,Glob,Grep --model sonnet --effort high
```

Notes:
- Run the Claude command in the background with a 15-minute timeout
- If the Codex subagent finishes first and Claude is still running, inform the user
- If Claude times out, ask whether to proceed with only the Codex review or retry

## Step 6: Consolidate and Fix

Once BOTH reviews are complete:
1. Consolidate feedback — group by severity, deduplicate, note consensus and disagreements
2. Present consolidated feedback to the user
3. Go through each piece of feedback:
   - **Obviously valid**: Spawn a subagent to fix it
   - **Obviously dismissible**: Dismiss it, briefly noting why
   - **Ambiguous**: Present to user with your assessment and ask
4. Run the full test suite again after fixes to confirm nothing broke

## Step 7: Next Steps

All implementation and review is complete. Before presenting options, assess whether this implementation introduced decisions, patterns, or reasoning that would provide valuable context for future sessions. If so, suggest the `$finalize` option.

Determine the current git state (branch, staged/unstaged changes).

Present options, marking one as **(suggested)** based on your ADR assessment:

### If an ADR would be valuable:

1. Run `$finalize` to create an ADR, clean up, and commit/PR **(suggested)**
2. Remove plan file + commit and push to current branch
3. Remove plan file + create branch + push + create PR (if on main), or commit + push + create PR (if on branch)

### If an ADR is not needed:

1. Remove plan file + commit and push to current branch
2. Remove plan file + create branch + push + create PR (if on main), or commit + push + create PR (if on branch)
3. Run `$finalize` if you'd like to create an ADR anyway

For options that remove the plan file, delete it from `docs/plans/` and include the deletion in the commit.

When committing, write a clear commit message summarizing what was implemented and why.

When creating a PR, include a summary of what was implemented, test coverage, and any notable decisions.
