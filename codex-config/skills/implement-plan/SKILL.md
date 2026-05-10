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
   - **deferred**: subagents run only inner-loop targeted tests at commits; the orchestrator runs the regression bar once at Step 5 (end of plan).

   This selection changes how the Step 3 subagent prompt and the Step 4 boy-scout prompt are constructed, and how Step 5 is framed. If the marker phrasing is ambiguous, ask the user which policy applies.

6. Check if the plan has an "## Acceptance Criteria" section. If so, record the spec file paths listed there. These are **specification tests** — human-owned, read-only. They serve as acceptance gates for the implementation. Read the spec files to understand which scenarios they cover.

7. Read the plan's "## Review depth" section and capture the value. Acceptable values are `single` (default) or `extended`. If the section is missing, treat it as `single`. If it's set to anything else, ask the user to clarify before proceeding. This value gates whether Step 8b runs.

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

## Step 4: Boy Scout Pass

Once all implementation steps are complete, improve the code around the implementation before final verification and review.

1. Get the list of files changed by the implementation:

   ```bash
   git diff --name-only HEAD
   ```

   (or `git diff --name-only` if changes are unstaged)

2. Read `references/boyscout.md` for the subagent instructions template.

3. Use `spawn_agent` with a prompt that includes:
   - The instructions from the reference file
   - The list of changed files
   - The test command — depends on the regression policy captured in Step 1:
     - **per-commit policy**: pass the project's full test command; the boy scout runs it after its changes.
     - **deferred policy**: pass only the inner-loop targeted test command, and tell the boy scout: "Run only targeted tests against the files you touch. Do NOT run the full project test suite — the orchestrator will run the full regression bar at end-of-plan."

4. Use `wait_agent` to collect the result. If it reports test failures it couldn't resolve, spawn another subagent to fix, or revert the problematic boy-scout changes via `git checkout -- <file>` before continuing.

## Step 5: Verification

Once the boy scout pass completes, run the full test suite yourself (via `shell`) to confirm everything is green end-to-end. This catches any issues between steps — including any changes made by the boy scout pass.

If the project's regression policy is **deferred** (captured in Step 1), this is the SOLE full-regression run for the entire plan. It must pass before proceeding to Step 6 (Plan Conformance Audit).

**If acceptance criteria exist**: Also run the spec tests explicitly and report their status separately. All spec test scenarios must pass — this is the acceptance gate. If any spec test fails:
- Do NOT attempt to fix by modifying the spec test
- Check if the implementation is wrong (spawn a subagent to investigate and fix the implementation)
- If the implementation appears correct but the spec test still fails, report the conflict to the user — the user decides whether the spec needs revision

If tests fail, spawn a subagent to investigate and fix, providing the test output and relevant file paths.

## Step 6: Plan Conformance Audit

Before code review, verify that every concrete behavior the plan promised is actually delivered in the diff. Reviewers focused on code quality have repeatedly missed missing-promise cases — this is a dedicated, single-responsibility gate that runs first.

1. Read `references/plan-conformance.md` for the subagent instructions template.

2. Use `spawn_agent` with a prompt that includes:
   - The instructions from the reference file
   - The path to the plan file

3. Use `wait_agent` to collect the result. Examine the verdict:
   - **`pass`** — proceed to Step 7
   - **`gaps`** — default to implementing each missing/partial promise: spawn a subagent to deliver the missing behavior, then re-run the audit. The plan said this would happen, so closing the gap is the conservative move. Only stop and consult the user if (a) the implementation fix fails after one retry, or (b) the gap suggests the plan itself is wrong — e.g., delivering the promise would conflict with code that was deliberately added during implementation, or it would require scope changes the plan didn't anticipate. In the consult case, present the relevant gaps with your assessment and ask whether to implement, defer (mark the promise out of scope in the plan), or acknowledge and proceed.
   - **`unscorable`** — the plan was too abstract to enumerate concrete promises. Note this in your end-of-step summary and proceed to Step 7; do not re-run.

   Do NOT proceed to Step 7 while the audit reports unresolved `gaps`.

4. "Unpromised Additions" listed by the audit are informational — note them in your end-of-step summary so the user sees them, but do not pause for input. They may indicate scope creep that belongs in a separate change; the user can flag any concerns.

## Step 7: Code Review

Once the conformance audit passes (or its gaps have been resolved or accepted), launch adversarial code reviews. Launch BOTH reviews simultaneously.

Before launching, prepare the second-opinion review prompt file (prerequisite for the shell call).

### 7a: Codex Code Review Subagent

Read `references/code-reviewer.md` for the subagent instructions template. Use `spawn_agent` with a prompt that includes:
- The instructions from the reference file
- The path to the plan file
- **If acceptance criteria exist**: The spec file paths and a note: "These are specification tests (human-owned). Check that (1) they were not modified, and (2) the implementation semantically satisfies the behavior they describe — not just that the tests pass mechanically."

### 7b: Second-opinion Reviewer (configurable via `$CODEX_REVIEWER`)

The second-opinion CLI is selected at container build time and is one of `copilot` or `claude`. The wrong one may not be installed — do NOT assume Copilot is available.

**Pre-dispatch — read the env var first.** Use the `shell` tool to capture the value before doing anything else in this step:

```
echo "${CODEX_REVIEWER:-claude}"
```

Capture the result. Acceptable values are `copilot` or `claude`. If anything else, abort with: "CODEX_REVIEWER is set to an unsupported value. Run `bash setup-mac.sh --reconfigure-reviewers` on the Mac, then `dev <project> --rebuild`." Treat the captured string as a known constant for the rest of this step.

**Build the prompt file.** Write the review prompt to `/tmp/second-opinion-code-review-prompt.txt`. Include:
- The path to the plan file — instruct the reviewer to read it with its file-read tool
- The full git diff (the reviewer can't run git, so the diff must be in the prompt)
- Instruction to read `~/workflows/planning/code-review-criteria.md` for the review checklist
- The paths to AGENTS.md and CLAUDE.md — instruct the reviewer to read them with its file-read tool

Do NOT paste the plan or convention files into the prompt — the reviewer has its own file-read tools.

**Dispatch on the captured value.** Take exactly one of these branches:

- **`copilot` branch** — run in the background with a 15-minute timeout:

  ```
  cd /workspace && copilot -p "$(cat /tmp/second-opinion-code-review-prompt.txt)" \
    --model "$REVIEWER_COPILOT_MODEL" \
    --available-tools='view,glob,rg' \
    --no-ask-user
  ```

  Note: this differs from the previous behaviour, which hardcoded `--model sonnet` regardless of user preference; the configured model now applies.

- **`claude` branch** — run in the background with a 15-minute timeout:

  ```
  cd /workspace && claude -p "$(cat /tmp/second-opinion-code-review-prompt.txt)" \
    --output-format text \
    --dangerously-skip-permissions \
    --no-session-persistence \
    --allowedTools "Read Glob Grep"
  ```

Notes (apply to both branches):
- If the Codex subagent (7a) finishes first and the second-opinion CLI is still running, inform the user.
- If the second-opinion CLI times out, ask whether to proceed with only the Codex review or retry.

## Step 8: Consolidate and Fix

Once BOTH reviews are complete, consolidate the feedback — group by severity, deduplicate, note consensus and disagreements — and present the summary to the user.

Then proceed without waiting for confirmation. Go through each piece of feedback:

- **Obviously valid**: Spawn a subagent to fix it.
- **Obviously dismissible**: Dismiss it, briefly noting why.
- **Ambiguous at minor/nit severity**: Default to action without asking — apply if the fix is cheap and low-risk, dismiss otherwise. Note your call in the summary.
- **Ambiguous at critical/major severity**: Present it to the user with your assessment and ask.

Only stop and wait on ambiguous critical/major items. Do NOT pause for user approval before applying clear-cut fixes, dismissals, or low-severity judgment calls — the consolidated summary is informational, not a checkpoint.

After fixes, run the full test suite again to confirm nothing broke.

## Step 8b: Extended Round (only when Review depth is `extended`)

Skip this step entirely if the plan's `Review depth` field (captured in Step 1) is `single`. Otherwise, run one additional parallel code review on the post-fix diff. **Hard cap: one extra round only.** Even if round 2 surfaces new critical findings, do NOT run a round 3 — apply the Step 8 triage rule and proceed.

Round 2 should be framed to look beyond what round 1 anchored on. Use the same parallel-launch mechanics as Step 7 (`spawn_agent` for the Codex code review and `shell` for the second-opinion CLI in the same turn), but with these differences:

- **Capture the post-fix diff freshly** with `git diff HEAD` (or `git diff` if unstaged) — round 2 reviews the current state, including round-1 fixes.
- **Output files use `-r2` suffixes** to avoid clobbering round 1: write the second-opinion prompt to `/tmp/second-opinion-code-review-prompt-r2.txt`.
- **Reviewer framing** — include this in both prompts:

  > This change has been through one round of adversarial review and revised in response. Round 1 already covered the obvious surface-level issues. Your job in this round is to surface what round 1 may have anchored away from: deeper architectural or functional concerns, second-order effects, security or correctness issues that weren't visible while the louder findings dominated the frame, and any new issues introduced by the round-1 fixes. Do not re-litigate items round 1 already raised and that the fixes addressed; focus on what's still latent.

- The reviewers should still read the plan and convention docs directly. They do NOT need round 1's findings — withholding them is intentional, to reduce anchoring.

After both round-2 reviews complete, run a compact version of Step 8 on the new findings: consolidate by severity, present to the user, then triage (obviously valid → subagent fixes; obviously dismissible → dismiss with note; ambiguous critical/major → ask user; ambiguous minor/nit → default to action without asking). After fixes, run the full test suite again.

Then proceed to Step 9.

## Step 9: Next Steps

All implementation and review is complete. Before presenting options, assess whether this implementation introduced decisions, patterns, or reasoning that would provide valuable context for future sessions. If so, suggest the `$finalize` option.

Note: `$finalize` itself now decides whether the implementation warrants an ADR (based on the plan's Motivation & Context section and the diff). Your assessment here is a hint — `$finalize` may second-guess it. Choosing `$finalize` doesn't commit you to producing an ADR; the skip path still ships the change with a richer commit message drawn from Motivation & Context.

Determine the current git state (branch, staged/unstaged changes).

Present options, marking one as **(suggested)** based on your ADR assessment:

### If an ADR would be valuable:

1. Run `$finalize` — it will assess ADR worthiness, write one if warranted, and ship the change either way **(suggested)**
2. Remove plan file + commit and push to current branch
3. Remove plan file + create branch + push + create PR (if on main), or commit + push + create PR (if on branch)

### If an ADR is not needed:

1. Remove plan file + commit and push to current branch
2. Remove plan file + create branch + push + create PR (if on main), or commit + push + create PR (if on branch)
3. Run `$finalize` if you want it to decide the ADR question for you (it may agree no ADR is needed, in which case it ships with a richer commit message)

For options that remove the plan file, delete it from `docs/plans/` and include the deletion in the commit.

When committing, write a clear commit message summarizing what was implemented and why.

When creating a PR, include a summary of what was implemented, test coverage, and any notable decisions.
