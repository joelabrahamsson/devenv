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

4. Parse the plan's "Implementation Approach" section and capture three pieces of text verbatim. These will be passed verbatim into each implementation subagent's prompt — subagents shouldn't have to re-derive them:
   - **Regression bar** — the project's tiered convention or the documented strict default
   - **Inner-loop test command** — the line specifying the targeted command for RED/GREEN/REFACTOR
   - **Step-grouping allowance** — the standard wording plus any explicit groupings the planner identified (e.g., *"Steps 5a–5d may be grouped"*)

5. Check the project's AGENTS.md and CLAUDE.md (in the workspace root) for a regression policy marker. Look for a line or section indicating the regression bar should be deferred to end-of-plan — the canonical phrasing is `Regression policy: defer to end-of-plan` (case-insensitive match is fine; equivalent phrasing in a "Regression Policy" section also counts). Record one of:
   - **per-commit** (default — no marker found): subagents run the regression bar at each commit boundary, as the plan specifies.
   - **deferred**: subagents run only inner-loop targeted tests at commits; the orchestrator runs the regression bar once at Step 4 (end of plan).

   This selection changes how the Step 3 subagent prompt is constructed and how Step 4 is framed. If the marker phrasing is ambiguous, ask the user which policy applies.

6. Check if the plan has an "## Acceptance Criteria" section. If so, record the spec file paths listed there. These are **specification tests** — human-owned, read-only. They serve as acceptance gates for the implementation. Read the spec files to understand which scenarios they cover.

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
   - **Inner-loop test command**: "During RED/GREEN/REFACTOR, run targeted tests against the file(s) under change using the command captured from the plan (passed verbatim below). Do NOT run the project's full test suite for inner-loop verification."

     ```
     <verbatim inner-loop test command line captured in Step 1>
     ```
   - **Commit-boundary gate** — the wording you include here depends on the regression policy captured in Step 1:
     - If **per-commit policy** (default): "At the commit boundary, run the regression bar specified in the plan's 'Implementation Approach' section (passed verbatim below). If the plan tiers gates by phase or commit category, follow that tiering. Do NOT impose a stricter bar than the plan specifies."

       ```
       <verbatim regression-bar text captured in Step 1>
       ```
     - If **deferred policy**: "The full regression bar is DEFERRED to the orchestrator. After your inner-loop targeted tests pass green, commit and report back. Do NOT run the project's full test suite or any equivalent full-suite command at the commit boundary — the orchestrator will run the regression bar once at end-of-plan. Failing tests during RED/GREEN/REFACTOR are still never acceptable: investigate, do not dismiss."
   - **Grouping permission**: "If the plan's preamble explicitly permits grouping certain adjacent steps into a single commit (passed below), you may do so. Otherwise, one commit per step."

     ```
     <verbatim step-grouping allowance + any explicit groupings captured in Step 1>
     ```
   - **If acceptance criteria exist**: "The following files are SPECIFICATION TESTS — human-owned and read-only. Do NOT modify them under any circumstances: `<list spec file paths>`. If your implementation contradicts a spec test (the test fails and you believe the test is wrong), STOP and report the conflict. Do not modify the spec test to make it pass."

   Also include:
   - A short list of files created/modified by previous steps (context for the agent)

3. Use `wait_agent` to collect the result. If it reports failing tests:
   - Spawn another subagent to fix the specific issue
   - If it fails after 2 attempts, ask the user for guidance

4. Update the plan to mark the step as completed

5. Move to the next step only after the previous step's tests are confirmed green

**Grouping steps:** Follow the grouping allowance and any explicit groupings the plan specifies in its "Implementation Approach" section. If the plan calls out specific steps as groupable, group them into a single subagent call; otherwise, do one step per call.

## Step 4: Verification

Once all steps are complete, run the full test suite yourself (via `shell`) to confirm everything is green end-to-end.

If the project's regression policy is **deferred** (captured in Step 1), this is the SOLE full-regression run for the entire plan. It must pass before proceeding to Step 5 (Code Review).

**If acceptance criteria exist**: Also run the spec tests explicitly and report their status separately. All spec test scenarios must pass — this is the acceptance gate. If any spec test fails:
- Do NOT attempt to fix by modifying the spec test
- Check if the implementation is wrong (spawn a subagent to investigate and fix the implementation)
- If the implementation appears correct but the spec test still fails, report the conflict to the user — the user decides whether the spec needs revision

If tests fail, spawn a subagent to investigate and fix, providing the test output and relevant file paths.

## Step 5: Code Review

Once all tests pass, launch adversarial code reviews. Launch BOTH reviews simultaneously.

Before launching, prepare the Copilot review prompt file (prerequisite for the shell call).

### 5a: Codex Code Review Subagent

Read `references/code-reviewer.md` for the subagent instructions template. Use `spawn_agent` with a prompt that includes:
- The instructions from the reference file
- The path to the plan file
- **If acceptance criteria exist**: The spec file paths and a note: "These are specification tests (human-owned). Check that (1) they were not modified, and (2) the implementation semantically satisfies the behavior they describe — not just that the tests pass mechanically."

### 5b: GitHub Copilot CLI Review (second opinion)

Write the review prompt to `/tmp/copilot-code-review-prompt.txt`. Include:
- The path to the plan file — instruct copilot to read it using its `view` tool
- The full git diff (copilot can't run git, so the diff must be in the prompt)
- Instruction to read `~/workflows/planning/code-review-criteria.md` for the review checklist
- The paths to AGENTS.md and CLAUDE.md — instruct copilot to read them using its `view` tool

Do NOT paste the plan or convention files into the prompt — copilot should read them directly.

Run Copilot CLI:
```
cd /workspace && copilot -p "$(cat /tmp/copilot-code-review-prompt.txt)" \
  --model sonnet \
  --available-tools='view,glob,rg' \
  --no-ask-user
```

Notes:
- Run the copilot command in the background with a 15-minute timeout
- If the Codex subagent finishes first and copilot is still running, inform the user
- If copilot times out, ask whether to proceed with only the Codex review or retry

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
