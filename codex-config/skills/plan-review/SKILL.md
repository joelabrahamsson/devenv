---
name: plan-review
description: Create an implementation plan with adversarial review from both a Codex subagent and Claude CLI, then revise and optionally implement. Invoke with $plan-review followed by a description of what to plan.
---

# Plan with Adversarial Review

You are orchestrating a planning workflow with adversarial review. Follow these steps precisely.

## Step 1: Establish the Task

If arguments were provided (`$ARGUMENTS`), use them as the description of what to plan. Present this to the user and confirm it captures their intent before proceeding.

If no arguments were provided, ask the user what they would like to plan. Ask as an open-ended question — do NOT present a list of categories or options to choose from.

### Spec File Detection

Check if any part of `$ARGUMENTS` contains a path to an existing file. For each path found, read the file and check if it begins with a `SPECIFICATION TEST` header comment. If so:
- Separate it as **acceptance criteria** — these spec tests define the required behavior
- The remaining text in `$ARGUMENTS` is additional scope and implementation guidance
- Present both to the user: "I see this spec file as acceptance criteria, and the additional scope is: ..."

If no spec files are found in the arguments, proceed normally. The rest of this workflow works with or without acceptance criteria.

## Step 2: Create the Plan

### 2a: Understand the codebase

Start by reading the project's AGENTS.md (and CLAUDE.md, ONBOARDING.md if they exist) in the workspace root. These describe the project's architecture, key directories, patterns, and conventions.

While reading the convention docs, look specifically for any section describing the project's regression-testing bar — tiered gates per phase or per commit category, or a strict "run everything on every commit" rule. Capture this text verbatim; it will be paraphrased or quoted into the generated plan's "Implementation Approach" section. If no such section exists, note that explicitly so the plan can use the documented strict default.

If the convention docs also state a regression *policy* such as `Regression policy: defer to end-of-plan`, this affects when the bar runs (the implementer honors it) but NOT what the bar is. The plan stays implementation-agnostic — document the bar verbatim regardless of the deferral policy.

**If convention docs exist with architecture/structure information:**
- Do NOT do broad codebase scans
- Use the information in the docs to read the specific files and directories relevant to the task directly
- Only investigate further if something described in the docs doesn't match what you find

**If no convention docs exist or they lack architecture information:**
- Explore the specific area of the codebase relevant to the task — not the entire project

### 2b: Design the plan

- Ask the user clarifying questions as needed
- Before drafting the step-by-step plan, populate the plan's **Motivation & Context** section (see `~/workflows/planning/plan-format.md` for the field structure). Draw the content from the user's original request, conversation history, and clarifying-question answers. The four fields are:
  - **Problem** — synthesize from what the user described.
  - **Constraints** — extract hard requirements surfaced in conversation or in convention docs.
  - **Alternatives considered** — list approaches discussed (including ones the user dismissed) and the reason for rejecting each. If alternatives weren't surfaced and the change is non-trivial, ask the user directly what other approaches they considered before drafting this field.
  - **Decision rationale** — articulate why the chosen approach is correct given the problem, constraints, and alternatives.
  If the change is genuinely trivial (typo, mechanical rename, dependency bump), the section may be a single italicized line per `plan-format.md`. Both adversarial reviewers will read the entire plan including this section, and **may critique the reasoning** as well as the steps — `~/workflows/planning/review-criteria.md` includes a dedicated Motivation & Context checklist.
- Design a step-by-step implementation plan

While designing the plan, also:
- Determine the project's targeted (inner-loop) test command by inspecting tooling — `package.json` scripts, `pyproject.toml`, `Cargo.toml`, project convention docs, etc. This concrete command goes into the "Inner-loop test command" line of the Implementation Approach section.
- Identify any adjacent steps that share a single edit surface and could be implemented as one TDD cycle / one commit. List them explicitly at the end of the Implementation Approach section (e.g., *"Steps 5a–5d may be grouped into one commit."*). If none, say so.

### When Acceptance Criteria Exist

If spec files were identified in Step 1:
1. Read the spec files to understand the required behavior
2. Include an "## Acceptance Criteria" section in the plan listing the spec file paths (see plan-format.md for the format)
3. For implementation steps that satisfy spec scenarios, the RED phase is "run the existing spec test and confirm it fails" rather than "write a new test" — the spec IS the failing test
4. Additional tests (integration, unit) should still be written per normal TDD for implementation details, edge cases, and any additional scope beyond the spec

The plan covers ALL the work needed — both satisfying the spec and any additional scope the user described. The spec provides the acceptance criteria, not the complete plan.

### Plan Format and TDD Structure

Read `~/workflows/planning/plan-format.md` for the required plan file format and TDD structure. Follow it exactly.

The Implementation Approach section is required to include the regression bar (inherited from project convention docs or the documented strict default), the inner-loop test command, and the step-grouping allowance — see plan-format.md for the exact wording.

Once the plan is complete, write it to the location specified in plan-format.md.

⚠️ CRITICAL: Do NOT ask the user to review the plan. Do NOT present the plan for approval. You MUST complete Steps 3, 4, and 5 (adversarial reviews, consolidation, and revision) BEFORE presenting anything to the user. Tell the user the plan is written and you're now sending it for adversarial review, then immediately proceed to Step 3.

## Step 3: Parallel Adversarial Reviews

**Pre-launch gate:** Before launching reviews, confirm the plan file contains a populated `## Motivation & Context` section. Acceptable states: (a) all four fields populated with substantive content, (b) the section replaced with a single italicized "trivial change" line, or (c) individual fields marked `n/a` with a one-line justification. If the section is missing entirely, or any field is left as a placeholder/empty, return to Step 2b and complete it. Do NOT launch the parallel reviews with an incomplete Motivation & Context section.

CRITICAL: You MUST launch both reviews simultaneously. Use `spawn_agent` for the Codex adversarial review and `shell` for the Claude CLI review in the same turn.

Before launching, write the Copilot review prompt to a temporary file (prerequisite for the shell call).

### 3a: Codex Adversarial Subagent Review

Read `references/adversarial-reviewer.md` for the subagent instructions template. Use `spawn_agent` with a prompt that includes:
- The instructions from the reference file
- The original goal/task description
- The path to the plan file

### 3b: GitHub Copilot CLI Review (second opinion)

Write the review prompt to a temporary file (e.g., `/tmp/copilot-plan-review-prompt.txt`). The prompt should contain:
- The original goal/task description (refined version after user Q&A)
- The path to the plan file — instruct copilot to read it using its `view` tool
- The paths to AGENTS.md and CLAUDE.md (if they exist) — instruct copilot to read them using its `view` tool
- The path to `~/workflows/planning/review-criteria.md` — instruct copilot to read it for the review checklist
- Do NOT paste file contents into the prompt — copilot has `view`, `glob`, and `rg` tools and should read files directly

Run Copilot CLI:
```
cd /workspace && copilot -p "$(cat /tmp/copilot-plan-review-prompt.txt)" \
  --model sonnet \
  --available-tools='view,glob,rg' \
  --no-ask-user
```

Notes:
- Run the copilot command in the background with a 15-minute timeout
- If the Codex subagent review finishes first and copilot is still running, inform the user
- If copilot times out after 15 minutes, inform the user and ask whether to proceed with only the Codex review or retry

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
