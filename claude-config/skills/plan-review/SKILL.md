---
name: plan-review
description: Create an implementation plan with adversarial review from both a Claude agent and GitHub Copilot CLI, then revise and optionally implement.
argument-hint: "[description of what to plan]"
user-invocable: true
allowed-tools: "EnterPlanMode ExitPlanMode Write Edit Read Glob Grep Bash Agent AskUserQuestion"
---

# Plan with Adversarial Review

You are orchestrating a planning workflow with adversarial review. Follow these steps precisely.

IMPORTANT: This workflow is designed to flow without unnecessary permission prompts. The tools listed in `allowed-tools` above are pre-authorized — use them without hesitation. Do NOT ask the user for confirmation before writing the plan file, exiting plan mode, running copilot, launching the adversarial agent, or updating the plan file. The user will review the plan after the adversarial reviews are complete.

## Step 1: Enter Plan Mode

Use the EnterPlanMode tool to enter plan mode.

If arguments were provided (`$ARGUMENTS`), use them as the description of what to plan. Present this to the user and confirm it captures their intent before proceeding.

If no arguments were provided, ask the user what they would like to plan. Ask as an open-ended question — do NOT present a list of categories or options to choose from. Let the user describe what they want in their own words.

## Step 2: Create the Plan

### 2a: Understand the codebase (token-efficient exploration)

Start by reading the project's CLAUDE.md (and AGENTS.md, ONBOARDING.md if they exist) in the workspace root. These files describe the project's architecture, key directories, patterns, and conventions.

**If a CLAUDE.md exists with architecture/structure information:**
- Do NOT launch broad Explore agents to scan the entire codebase
- Instead, use the information in CLAUDE.md to read the specific files and directories relevant to the task directly (using Read, Glob, Grep)
- Only launch an Explore agent if something described in CLAUDE.md doesn't match what you find (e.g., a referenced file doesn't exist, a pattern seems different), and scope that agent narrowly to investigate the discrepancy
- This approach validates the docs against reality while using far fewer tokens

**If no CLAUDE.md exists or it lacks architecture information:**
- Fall back to Explore agents, but scope them to the specific area of the codebase relevant to the task — not the entire project
- Limit to 1 Explore agent if the task is focused, 2 maximum if it spans multiple areas

### 2b: Design the plan

- Ask the user clarifying questions as needed using AskUserQuestion
- Design a step-by-step implementation plan

The plan should be detailed enough that someone unfamiliar with the conversation could implement it. Include specific file paths, function names, test descriptions, and implementation details.

### TDD Structure

Every plan step that involves code changes MUST be structured as a red-green-refactor cycle:

1. **Red**: Write the test(s) first. Describe what test file, test name, and assertions to create.
2. **Run**: Run the tests and verify they fail for the expected reason.
3. **Green**: Write the minimum implementation code to make the tests pass.
4. **Run**: Run the tests and verify they pass.
5. **Refactor** (if needed): Clean up the implementation while keeping tests green.

For example, instead of:
```
Step 3: Add the /api/tags endpoint
- Create src/routes/api/tags.ts
- Add GET handler that queries tags table
- Add route to router
```

Write:
```
Step 3: Add the /api/tags endpoint

3.1 RED - Write test:
- Create test/routes/api/tags.spec.ts
- Test: GET /api/tags returns 200 with array of tags
- Test: GET /api/tags returns empty array when no tags exist
- Test: Response includes tag id, name, and slug

3.2 RUN - Verify tests fail (routes/handler don't exist yet)

3.3 GREEN - Implement:
- Create src/routes/api/tags.tsx
- Add GET handler querying tags table via Kysely
- Register route in src/routes/index.ts

3.4 RUN - Verify all tests pass

3.5 REFACTOR - (if needed)
```

The plan file should include a note at the top reminding the implementer to follow the TDD cycle strictly: never write implementation code without a failing test first.

Once the plan is complete, write it to a file at `docs/plans/YYYY-MM-DD-short-description.md` (date + a brief kebab-case summary of what the plan does, e.g., `2026-04-05-add-team-squad-view.md`). Create the `docs/plans/` directory if it doesn't exist. The file should contain:
- The original goal/task description (including any refinements from user Q&A)
- A TDD reminder: "## Implementation Approach\nThis plan follows a strict TDD workflow. For each step: write failing tests first, verify they fail, implement the minimum code to pass, verify they pass, then refactor if needed. Never skip ahead to implementation without a failing test."
- The full implementation plan with TDD-structured steps

⚠️ CRITICAL: Do NOT call ExitPlanMode yet. Do NOT ask the user to review the plan. Do NOT present the plan for approval. You MUST complete Steps 3, 4, and 5 (adversarial reviews, consolidation, and revision) BEFORE exiting plan mode or presenting anything to the user. Tell the user the plan is written and you're now sending it for adversarial review, then immediately proceed to Step 3.

Exit plan mode using ExitPlanMode only AFTER Step 5 is complete (plan has been revised based on review feedback).

## Step 3: Parallel Adversarial Reviews

CRITICAL: You MUST launch both reviews in the SAME message using multiple tool calls. This means sending a single response that contains both an Agent tool call and a Bash tool call. Do NOT launch one, wait for it to finish, then launch the other.

Before launching the reviews, write the copilot prompt to a temporary file first (this is a prerequisite for the Bash call). Then, in a single message, launch both:

### 3a: Claude Adversarial Agent Review

Launch the `adversarial-reviewer` agent with a prompt that includes:
- The original goal/task description
- The path to the plan file — tell it to read the file itself
- The paths to CLAUDE.md / AGENTS.md if they exist — tell it to read them itself

Do NOT paste the plan contents into the agent prompt. The agent has read tools and should read files directly.

### 3b: GitHub Copilot CLI Review

Run the copilot CLI in non-interactive mode using Bash.

**Building the prompt (do this BEFORE launching the parallel reviews):** Write the review prompt to a temporary file (e.g., `/tmp/copilot-plan-review-prompt.txt`) to avoid shell argument length limits. The prompt should contain:
- The original goal/task description (refined version after user Q&A)
- The path to the plan file — instruct copilot to read it using its `view` tool
- The paths to CLAUDE.md and AGENTS.md (if they exist) — instruct copilot to read them using its `view` tool
- Review instructions (see below)

Do NOT paste the plan contents or CLAUDE.md/AGENTS.md into the prompt — copilot has `view`, `glob`, and `rg` tools and should read files directly. This keeps the prompt small.

The prompt must instruct copilot to perform a thorough review covering:
- Whether the plan follows conventions in CLAUDE.md and AGENTS.md
- Whether the plan includes documentation updates where needed
- Whether the plan uses a test-driven approach with tests covering all planned functionality
- Whether the plan risks introducing bugs in new or existing code
- Edge cases, error handling, security considerations
- Whether the implementation order is logical and dependencies are correct
- Whether the plan is over-engineered or missing simpler approaches

The prompt should ask copilot to structure its response as: Critical Issues, Suggested Improvements, Minor Observations, and Positive Aspects.

**Running copilot:** Use the following command pattern:
```
cd /workspace && copilot -p "$(cat /tmp/copilot-plan-review-prompt.txt)" \
  --model gpt-5.4 \
  --available-tools='view,glob,rg' \
  --no-ask-user
```

Notes:
- `--available-tools='view,glob,rg'` restricts copilot to read-only tools, keeping the review focused and faster
- `--no-ask-user` ensures copilot works autonomously without trying to ask questions
- Run the copilot command in the background using `run_in_background: true` with a Bash timeout of 900000ms (15 minutes)
- Since copilot runs in the background, you will be notified when it completes. If the adversarial agent review finishes first and copilot is still running, inform the user that the Claude review is done and copilot is still working. If copilot has been running for more than 5 minutes when the agent review finishes, let the user know it's taking longer than expected but is still in progress.
- If copilot times out after 15 minutes, inform the user and ask whether they want to proceed with only the Claude adversarial review or retry the copilot review.

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

NOW call ExitPlanMode to exit plan mode.

## Step 6: Offer Implementation

⚠️ CRITICAL: Do NOT start implementing automatically. You MUST present the options below and WAIT for the user to choose. Never assume the user wants to implement immediately — even if the plan is small or the reviews found no issues. The user decides when and how to implement.

The ONLY exception: if the user explicitly included instructions like "implement after review" or "go ahead and implement" in their original request (the `$ARGUMENTS` passed to the skill). In that case, choose Option 4 (auto-implement) automatically.

Once the plan is revised, present the final plan summary to the user and ask whether they approve it for implementation. Recommend clearing context first if the conversation has been long (many planning rounds, large review outputs, etc.).

Present the user with clear options:

1. **Implement now** (keep current context)
2. **Clear context and implement** (recommended if conversation is long)
3. **Save plan and stop** (just keep the plan file for later)

### Option 1: Implement now
- Begin implementation following the plan and the TDD implementation rules below

### Option 2: Clear context and implement
- Make sure the plan file is saved and fully up to date
- Tell the user to run the following two commands in sequence:
  1. `/compact`
  2. `/implement-plan docs/plans/YYYY-MM-DD-short-description.md` (with the actual filename)
- Display both commands clearly so the user can copy-paste them

### Option 3: Save plan and stop
- Confirm the plan file path to the user
- Let them know they can implement later with `/implement-plan docs/plans/YYYY-MM-DD-short-description.md`

### Option 4: Auto-implement (only when user explicitly requested it)
- This option is NEVER presented to the user — it is only used when the user's original request explicitly said to implement after review
- Begin implementation following the TDD implementation rules below
- After implementation is complete, delete the plan file
- Then follow the normal post-implementation flow (commit, PR, etc.)

### TDD Implementation Rules

When implementing the plan (Options 1 or 4), follow each step's TDD cycle strictly:

1. Write the test(s) described in the RED phase. Do NOT write any implementation code yet.
2. Run the tests. Confirm they fail. If they pass unexpectedly, investigate — either the test is wrong or the functionality already exists.
3. Write the implementation code described in the GREEN phase. Write the minimum code needed to pass the tests.
4. Run the tests. Confirm they pass. If they fail, fix the implementation (not the tests, unless the test itself was wrong).
5. Refactor if the plan calls for it, running tests again after.
6. Move to the next step only after all tests for the current step are green.
