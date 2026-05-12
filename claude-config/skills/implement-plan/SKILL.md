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

4. Parse the plan's "Implementation Approach" section and capture three pieces of text verbatim. These will be passed verbatim into each implementation subagent's prompt — subagents shouldn't have to re-derive them:
   - **Regression bar** — the project's tiered convention or the documented strict default
   - **Inner-loop test command** — the line specifying the targeted command for RED/GREEN/REFACTOR
   - **Step-grouping allowance** — the standard wording plus any explicit groupings the planner identified (e.g., *"Steps 5a–5d may be grouped"*)

   Also capture the plan's **Behavioral Contract** section verbatim — the entire `## Behavioral Contract` section text including all scenario bodies, the Invariants sub-section (if any), and any escape line. Capture the entire section text, not just titles — subagents need the bodies to evaluate whether a discovered behavior is in-scope. If the section uses the pointer form, additionally read the referenced spec file(s) listed in `## Acceptance Criteria` and capture either the spec files' full contents (preferred, for small spec files) or the scenario titles plus the spec file paths (acceptable for large spec files). If the section uses an escape line, just capture the escape line. If the plan is a legacy plan with no `## Behavioral Contract` section at all, capture the absence as a note — subagents will see "no contract section captured" and treat the contract scope policy as inapplicable.

   **Per-step `test_strategy` and `Covers:` line capture (Stage 2).** For each implementation step in the plan, parse:

   - The strategy from the step's heading (the `— strategy: <value>` suffix). Accepted values: `red-first`, `build-then-test`, `property-based`, `integration-only`.
   - For `integration-only` steps, the parent step name from the `(covered by Step M)` parenthetical on the heading.
   - The `**Covers:**` line (if present) immediately below the step heading. Parse per the format spec in `~/workflows/planning/plan-format.md` (comma-space-separated tokens; each token is `"quoted scenario title"` or `**bold invariant title**`; strip outer markers; normalize trailing periods on invariants).

   **Pre-dispatch validation (fail-fast, BEFORE launching any subagent in Step 3).** Run these checks in order. Any failure STOPs the workflow and reports to the user via `AskUserQuestion` with the recovery hint listed. Skip all checks for legacy plans (no strategy suffix on any step) — they default to `red-first` and these rules don't apply.

   1. **Consistency:** if ANY step has a strategy suffix, ALL steps must. Mixed labeled/unlabeled in a single plan is malformed. Recovery: 'Edit the plan file directly to add `— strategy: <value>` suffixes to the unlabeled steps (or remove suffixes from all steps to opt out of Stage 2), then re-run `/implement-plan`.'
   2. **Valid values:** every captured strategy must be one of the four accepted values. Recovery: 'Edit the plan file to correct the invalid strategy value, then re-run `/implement-plan`.'
   3. **`integration-only` parent existence:** for each `integration-only` step, the parent must exist in the plan, be referenced by step number, and NOT itself be `integration-only` (chained `integration-only` is malformed). Recovery: 'Return to `/plan-review` sub-step 2c, revise the affected steps (change parent reference, or change the integration-only step to red-first), and re-run adversarial review on the changed section.'
   4. **Grouped-step strategy consistency:** for each explicit group in the step-grouping allowance, verify all steps in the group share the same `test_strategy` — OR the group is the explicit integration-only-with-parent grouping. Mixed-strategy groups are malformed. Recovery: 'Edit the plan to either match strategies within the group or remove the grouping.'
   5. **`Covers:` line completeness:** for every labeled step that delivers contract scenarios or invariants (the plan has a populated Behavioral Contract and the step contributes to it), a `**Covers:**` line MUST be present directly below the step heading. Skipped for escape-line contracts. Recovery: 'Edit the plan to add the Covers line.'
   6. **`Covers:` line parse:** every `**Covers:**` line must parse cleanly. Parse failure is malformed. Recovery: 'Edit the plan to fix the Covers line syntax; consult plan-format.md for the format spec (comma-space-separated tokens; double-quoted scenarios; bold invariants; no embedded double quotes in titles).'
   7. **Parent-superset rule for `integration-only`:** for each `integration-only` step N with parent step M, M's `Covers:` line must include every entry on N's `Covers:` line (identical canonical titles, no paraphrasing). Recovery: 'Edit the parent step's Covers line to add the missing scenario/invariant titles.'
   8. **`property-based` contract-invariant existence:** for each `property-based` step, every invariant title in its `Covers:` line must exist as a bolded entry in the plan's `## Behavioral Contract` `### Invariants` sub-section. Recovery: 'Either add the invariant to the contract (revise via `/plan-review`) or change the step to a different strategy.'
   9. **Strategy/spec-test consistency:** if the plan has an `## Acceptance Criteria` section, any step whose `Covers:` line references a scenario whose canonical title matches a test name in the listed spec files MUST use `red-first` strategy. Steps satisfying spec scenarios with `build-then-test`, `property-based`, or `integration-only` are malformed. Recovery: 'Either change the step to `red-first` or revise the Acceptance Criteria to remove the affected spec file.'

   The plan-review pre-launch gate (per `claude-config/skills/plan-review/SKILL.md` Step 3 item 4) and this pre-dispatch validation gate are functionally duplicated for defense in depth and MUST stay in sync — when adding a check to one, mirror it in the other.

   **Pass-through to subagent prompts.** Each step's parsed Covers list is passed verbatim into that step's subagent prompt (so subagents know which scenarios their tests must cover) and into the conformance audit prompt (so the audit can map promises to steps).

   **Incoming integration-only coverage map (for parent steps).** Build a child-to-parent coverage map by scanning all `integration-only` steps and their named parents. For each parent step, record the union of all child `integration-only` steps' Covers entries that name this parent. When the parent step is dispatched to its subagent, the prompt explicitly lists the incoming coverage as additional scenarios/invariants the parent's tests must cover (in addition to the parent step's own Covers entries). This guards against the planner forgetting to mirror integration-only Covers into the parent's Covers; even if validation check 7 above somehow passed, the parent's subagent still sees the complete list of obligations.

5. Check the project's CLAUDE.md and AGENTS.md (in the workspace root) for a regression policy marker. Look for a line or section indicating the regression bar should be deferred to end-of-plan — the canonical phrasing is `Regression policy: defer to end-of-plan` (case-insensitive match is fine; equivalent phrasing in a "Regression Policy" section also counts). Record one of:
   - **per-commit** (default — no marker found): subagents run the regression bar at each commit boundary, as the plan specifies.
   - **deferred**: subagents run only inner-loop targeted tests at commits; the orchestrator runs the regression bar once at Step 5 (end of plan).

   This selection changes how the Step 3 subagent prompt and the Step 4 boy scout prompt are constructed, and how Step 5 is framed. If the marker phrasing is ambiguous, ask the user which policy applies.

6. Check if the plan has an "## Acceptance Criteria" section. If so, record the spec file paths listed there. These are **specification tests** — human-owned, read-only. They serve as acceptance gates for the implementation. Read the spec files to understand which scenarios they cover.

7. Read the plan's "## Review depth" section and capture the value. Acceptable values are `single` (default) or `extended`. If the section is missing, treat it as `single`. If it's set to anything else, ask the user to clarify before proceeding. This value gates whether Step 8b runs.

Then immediately proceed to Step 2. Do NOT read source code, types, components, or any other project files.

## Step 2: Create Task List

Create a task for each implementation step in the plan using TaskCreate. Each task should:
- Have a clear subject matching the plan step
- Use an activeForm that describes what's being done (e.g., "Implementing GET /api/tags endpoint")

## Step 3: TDD Implementation via Subagents

Work through each task in order. For each task (or group of closely related tasks):

1. Mark the task as `in_progress` using TaskUpdate. Then output a one-line user-facing announcement before launching the subagent, naming the step number/title (and `test_strategy` label if the plan is Stage 2). Format: `Step N/M — <title> [<strategy>]: launching implementation subagent (typical 5–20 min).` This gives the user something to anchor on during the silent gap until the subagent returns.

2. Launch an Agent with `model: sonnet` to implement the step. The agent prompt should tell it to:
   - Read the plan file at `<plan-file-path>` and implement step N (specify which step number(s))
   - Read the project's CLAUDE.md / AGENTS.md for conventions and patterns
   - **Strategy-specific shape.** Follow the TDD-cycle shape that matches this step's `test_strategy` (captured in Step 1, passed verbatim in the prompt). Plans without strategy labels default to `red-first` for every step. The orchestrator includes one of the four prompts below verbatim, chosen by the captured strategy:

     **`red-first`** (default; current strict TDD):

     > "Follow strict TDD: RED (write failing tests targeting the contract scenarios listed on this step's `Covers:` line, plus edge cases not in the contract; use the scenario-and-invariant test naming rule for the Covers-line items) → RUN (confirm failures for the expected reasons) → GREEN (minimum implementation) → RUN (confirm tests pass) → REFACTOR (if needed)."

     **`build-then-test`:**

     > "Follow build-then-test: IMPLEMENT the code first, following the pattern named in the step description (the step prose should name a specific anchor file or component). Then write TESTS that capture the new behavior as regression guards — tests must cover every scenario listed on this step's `Covers:` line, named per the scenario-and-invariant test naming rule (substring of canonical title).
     >
     > **Non-tautology safeguard (required).** For each test you write, you MUST verify the test would FAIL if the implementation body were deleted or replaced with a stub returning a hard-coded wrong value. Tests must assert SPECIFIC OUTPUT VALUES, not merely that no exception is raised, not merely that the function returns something. Demonstrate this in your summary: for one representative test, briefly state what mutation to the implementation would make the test fail. If you cannot identify such a mutation, your test is tautological and must be rewritten before proceeding.
     >
     > Run tests, verify all pass, then REFACTOR if needed. The test-first sequencing is deliberately not used for this step because the existing pattern named in the step prose provides the structural anchor; the non-tautology safeguard provides the collusion guard that would otherwise come from RED-first sequencing."

     **`property-based`:**

     > "Follow property-based TDD:
     >
     > 1. INVARIANTS — Reference the invariants from this step's `Covers:` line. Each invariant on the Covers line corresponds to a bolded entry in the verbatim Behavioral Contract `### Invariants` sub-section passed below — pre-dispatch validation already confirmed this. Read each referenced invariant's full text to understand the property to test.
     >
     > 2. PROPERTY TESTS — Write property-based tests using the project's property-testing framework (named in the step description). Each property test's name/description MUST contain the referenced invariant's bolded title as a substring.
     >
     > 3. EXAMPLE TESTS — Write 2–3 concrete example tests that cover the scenarios listed on this step's `Covers:` line (the non-invariant entries).
     >
     > 4. RUN — Verify both property tests and example tests fail.
     >
     > 5. GREEN — Implement.
     >
     > 6. RUN — Verify all tests pass.
     >
     > 7. REFACTOR if needed."

     **`integration-only`:**

     > "Follow integration-only: this step is wiring or declaration; do NOT add a new per-step test cycle.
     >
     > 1. IMPLEMENT — Build the wiring or declaration described in the step. The contract scenarios listed on this step's `Covers:` line are covered by Step `<parent-step-number>`'s test, NOT by a per-step test you write.
     >
     > 2. RUN — Run the project's existing test suite (or, if the regression policy is deferred, a targeted smoke check) to confirm no regressions in already-shipped tests. **Do NOT attempt to run Step `<parent-step-number>`'s test if Step `<parent-step-number>` has not yet executed in this plan** (the parent step may come later in the plan order; its test may not exist in the diff yet). The end-of-plan conformance audit will verify the parent's test exists, passes, and covers the scenarios listed on this step's Covers line.
     >
     > **Out-of-contract handling.** If, during IMPLEMENT, you discover a behavioral addition not in the contract (e.g., a missing middleware call that would change security or routing behavior), STOP before committing. Emit the OUT_OF_CONTRACT_BEHAVIOR sentinel per the rules below. If you have already written the wiring code (uncommitted), note the uncommitted changes in your summary so the orchestrator can decide whether to revert or build on them.
     >
     > **Grouped-step handling.** If this `integration-only` step is grouped with its parent step (per the explicit integration-only-with-parent grouping option), the wiring and the parent's test land together in a single commit. **Sequencing within the grouped subagent run is fixed:** first complete this integration-only step's IMPLEMENT (set up the wiring); only THEN begin the parent step's full TDD shape. Reversing the order would cause the parent's RED-phase tests to fail for the wrong reason (missing wiring rather than missing implementation)."

     **Contract-scope preflight** (applies to ALL four strategies before any IMPLEMENT or RED phase): "Compare the step's intended behavior — as expressed in the step prose, the `Covers:` line, and the verbatim Behavioral Contract passed below — against what's currently in the contract. If the step requires a new user-facing capability or distinct named failure mode NOT in the contract, STOP and emit the `OUT_OF_CONTRACT_BEHAVIOR: <description>` sentinel BEFORE writing any code or tests. Do not commit any work before emitting the sentinel."

     **Covers: list for this step** (passed verbatim from Step 1's parsed result):

     ```
     <verbatim Covers list for this step + incoming-coverage map entries if this step is a named integration-only parent>
     ```
   - Report back: what files were created/modified, what tests were added, whether all tests pass, and the exact test command output (exit code and any failures)
   - **Failing tests policy**: "Failing tests are NEVER acceptable. Do NOT dismiss any test failure as 'flaky', 'intermittent', or 'unrelated to my changes'. If ANY test fails, you must investigate and attempt to fix it. If you cannot fix it without changing application behavior or weakening the test, STOP and report the failure with the full test output. Never silently proceed past a failing test."
   - **Inner-loop test command**: "During RED/GREEN/REFACTOR, run targeted tests against the file(s) under change using the command captured from the plan (passed verbatim below). Do NOT run the project's full test suite for inner-loop verification."

     ```
     <verbatim inner-loop test command line captured in Step 1>
     ```
   - **Commit-boundary gate** — the wording you include here depends on the regression policy captured in Step 1:
     - If **per-commit policy** (default): "At the commit boundary, run the regression bar specified in the plan's 'Implementation Approach' section (passed verbatim below). If the plan tiers gates by phase or commit category, follow that tiering. Do NOT impose a stricter bar than the plan specifies."

       ```
       <verbatim regression-bar text captured in Step 1>
       ```
     - If **deferred policy**: "The full regression bar is DEFERRED to the orchestrator. After your inner-loop targeted tests pass green, commit and report back. Do NOT run the project's full test suite or any equivalent full-suite command at the commit boundary — the orchestrator will run the regression bar once at end-of-plan. The failing-tests policy still applies to your inner-loop runs: any failure during RED/GREEN/REFACTOR must be investigated, not dismissed."
   - **Grouping permission**: "If the plan's preamble explicitly permits grouping certain adjacent steps into a single commit (passed below), you may do so. Otherwise, one commit per step."

     ```
     <verbatim step-grouping allowance + any explicit groupings captured in Step 1>
     ```
   - **If acceptance criteria exist**: "The following files are SPECIFICATION TESTS — human-owned and read-only. Do NOT modify them under any circumstances: `<list spec file paths>`. If your implementation contradicts a spec test (the test fails and you believe the test is wrong), STOP and report the conflict. Do not modify the spec test to make it pass."
   - **Contract scope policy** (skip this clause if the plan is a legacy plan with no captured Behavioral Contract section): "The plan's `Behavioral Contract` section (and any spec files listed in `Acceptance Criteria`) defines the user-observable behavior this implementation step must deliver. The full text of the relevant scenarios and invariants is passed below verbatim. During implementation, if you discover a **new user-facing capability** or a **distinct named failure mode** that is not represented by any scenario or invariant in the contract, you must STOP and report this back to the orchestrator with an explicit sentinel in your summary — do NOT silently implement the new behavior. Sentinel format (these rules are strict; the orchestrator scans for them programmatically):

     - The sentinel MUST be `OUT_OF_CONTRACT_BEHAVIOR: <one-line description of the discovered behavior>` exactly.
     - The sentinel MUST appear on its **own line** in your final summary text, with **no leading whitespace** (column 0).
     - The sentinel MUST appear in the prose summary you return to the orchestrator, **not** inside a quoted code block, a fenced block, a literal string in code you wrote, or a quoted piece of test output. The orchestrator scans your summary prose only.
     - You MUST **not commit any work for the current step or group** before emitting the sentinel. The orchestrator's resolution path assumes the subagent stopped before making partial progress. If you have already committed work and then discover the out-of-contract behavior, your summary must (a) include the sentinel and (b) note in the same summary which commits were made so the orchestrator can decide whether to revert or build on them.

     Do NOT call `AskUserQuestion` from this subagent — the orchestrator handles user prompts. Your job is to stop, report, and wait. The orchestrator will pause when it sees the sentinel and ask the user how to proceed.

     **Threshold for halting:** the sentinel is for *new distinct user-facing capabilities or named failure modes*, not every implementation detail that happens to be observable. Sub-behaviors of an already-contracted scenario (e.g., a 400 response for a missing required field when the scenario already says 'valid input succeeds and invalid input is rejected') do NOT trigger the sentinel — they are part of delivering the contracted scenario. New top-level capabilities (e.g., 'add a forgot-password link', 'new admin-only export endpoint') and new named failure modes the user would discover (e.g., 'reject rate-limited requests with HTTP 429') DO trigger the sentinel. When in doubt, prefer to surface — false positives are cheap; silent contract expansion is not.

     **Verbatim contract scope follows.** Implement only what is in the contract. The contract is enforced by the `plan-conformance` audit after all steps complete.

     ```
     <verbatim Behavioral Contract section text captured in Step 1>
     ```"
   - **Scenario and invariant test naming**: "When you write a test that verifies a Behavioral Contract scenario (or an Acceptance Criteria spec scenario, or an invariant), name the test such that its name or description contains the canonical title as a **substring**. The canonical title for a scenario is the text after `Scenario:` in the Gherkin block. The canonical title for an invariant is the bolded title text (the text inside `**...**` at the start of the invariant's bullet, with the trailing period stripped). Use identifier-safe paraphrase only where the test framework requires it (snake_case in Python, dashes-to-spaces or quoted strings in BDD frameworks, plain string in JavaScript `it()`/`test()`). For parameterized or table-driven tests, the canonical title must appear in the compound test name (e.g., `test_login_valid_credentials[admin-user]` is acceptable for a scenario titled 'Login with valid credentials'). Tests for sub-behaviors, edge cases, and implementation details that are NOT a contract scenario or invariant can be named freely. The substring rule is what enables the post-implementation `plan-conformance` audit to mechanically map contract items to tests.

     This naming rule applies whenever the subagent writes new tests — `red-first`, `build-then-test`, and `property-based` strategies all write tests. For `integration-only` steps, no new tests are written; the parent step's tests carry the naming."

   Also include in the prompt:
   - A short list of files created/modified by previous steps (so the agent has context on what already exists)

3. When the agent completes, review its summary. Verify test results — do NOT accept claims that failures are "flaky" or "unrelated". If any test failed:
   - Try launching another Sonnet agent to fix the specific issue (include the full test output in its prompt)
   - If it fails after 2 attempts, stop and ask the user for guidance via AskUserQuestion — include the exact test failure output
   - Do NOT proceed to the next step while any test is failing, regardless of the agent's assessment of the failure's relevance

   **For `build-then-test` steps specifically (Stage 2):** also verify the subagent's summary includes the non-tautology demonstration (a statement of what mutation to the implementation would cause a representative test to fail). If the demonstration is missing, send the subagent a follow-up message: 'You did not include the non-tautology demonstration required for build-then-test steps. For one representative test, state what mutation to the implementation would cause it to fail.' Do NOT mark the step `completed` until the demonstration is present.

4. **Scan the subagent's summary prose for OUT_OF_CONTRACT_BEHAVIOR sentinels.** Scan the subagent's final prose reply (not tool output, not quoted code blocks) for any line matching the regex `^OUT_OF_CONTRACT_BEHAVIOR: .+$` (start of line, exact prefix, non-empty description). If one or more match, the subagent has paused on a possible contract-scope expansion. For each sentinel line, call `AskUserQuestion` (one question per sentinel; if multiple sentinels appear in one summary, handle them sequentially) to surface the discovery with these options:

   1. **Add to contract** — update the plan's `Behavioral Contract` section to include the discovered behavior (edit the plan file inline, adding the new scenario to the relevant Feature block or, if needed, a new `### Supplemental scenarios` block). Record the addition in the plan's `## Revision Notes` section noting whether it's a missed scenario (planning oversight) or a deliberate mid-implementation scope expansion. Then re-launch the implementation for the current step (see grouped-step note below) with the updated contract embedded in the subagent prompt and an explicit `resolved-decisions` block listing the just-decided sentinel so the subagent doesn't re-emit the same sentinel.
   2. **Defer** — mark the discovered behavior as explicitly out of scope for this plan (note the deferral in the plan's `## Revision Notes` section, including the sentinel description). Then re-launch the implementation for the current step with the same `resolved-decisions` block, instructing the subagent not to implement the deferred behavior. The contract itself is NOT updated; the resolved-decisions block tells the subagent to stop re-flagging this specific behavior.

   **Grouped-step handling.** If the sentinel was emitted during a subagent call covering grouped steps (per the step-grouping allowance), 'the current step' means **the entire group**. Before re-launching, check `git log` to see which steps in the group have already been committed and re-launch only the *remaining* steps in the group. The re-launch prompt must explicitly list which steps are already done and which remain.

   **Repeated sentinels.** The `resolved-decisions` block passed back into the re-launched subagent must list every sentinel the user has already resolved for the current step or group (typically one, but could be more if multiple discoveries happened in one subagent run). The subagent prompt must include: 'Do not re-emit any sentinel from the resolved-decisions block; act according to the decision (implement, defer) for each.' If the subagent emits a *new* sentinel (a different out-of-contract behavior the user has not yet resolved), handle it as normal. If a subagent re-emits a sentinel that is already in the resolved-decisions block, surface this to the user as a subagent-bug warning before deciding whether to retry or escalate.

   Do NOT proceed to the next step while any unresolved `OUT_OF_CONTRACT_BEHAVIOR` sentinel is pending. Resolve all sentinels from each subagent run before launching the next.

5. Mark the task as `completed`. Then output a one-line user-facing summary of what just finished: file count from the subagent's report (or `git diff --name-only` since launch), one or two key file names, and pass/fail of the inner-loop tests. Format: `Step N/M complete — <N files>, <key file>, tests green. Next: Step N+1 or '<next-phase-name>'.` Keep it terse — this is a heartbeat, not a report.

6. Move to the next task only after the previous step's tests are confirmed green AND all sentinels from the previous step's subagent runs are resolved

**Grouping steps:** Follow the grouping allowance and any explicit groupings the plan specifies in its "Implementation Approach" section. If the plan calls out specific steps as groupable, group them into a single agent call; otherwise, do one step per call.

## Step 4: Boy Scout Pass

Once all tasks are complete, improve the code around the implementation before final verification and review.

Before launching the boy scout subagent, output a one-line user-facing announcement: `Launching boy-scout pass over changed files (typical 3–10 min).`

1. Get the list of files changed by the implementation:
   ```
   git diff --name-only HEAD
   ```
   (or `git diff --name-only` if changes are unstaged)

2. Launch the `boyscout` agent with a prompt that includes:
   - The list of changed files
   - The test command — depends on the regression policy captured in Step 1:
     - **per-commit policy**: pass the project's full test command; the boy scout runs it after its changes.
     - **deferred policy**: pass only the inner-loop targeted test command, and tell the boy scout: "Run only targeted tests against the files you touch. Do NOT run the full project test suite — the orchestrator will run the full regression bar at end-of-plan."
   - Instruction to read the project's CLAUDE.md/AGENTS.md for conventions

3. When the agent completes, review its summary. If it reports test failures it couldn't resolve, launch a Sonnet agent to fix, or revert the problematic boy scout changes.

## Step 5: Verification

Run the full test suite yourself (via Bash) to confirm everything is green end-to-end. This catches any issues between steps — including any changes made by the boy scout pass.

Where the project's test runner supports verbose or reporter modes that emit per-test names with pass/fail status (e.g., `pytest -v`, `vitest --reporter=verbose`, `jest --verbose`, `cargo test -- --nocapture`), use that mode. Save the test-runner output to a file at `/tmp/plan-conformance-test-run.txt`. The conformance audit (Step 6) uses this file to verify scenario-promise tests actually ran and passed.

If the project's runner produces only summary output by default and verbose mode is not available without project-level configuration changes, save the summary output to the same file with this exact line as its first line:

```
# Per-test names unavailable from this runner — summary output only.
```

This is a *recognized degraded mode* — the conformance audit tolerates it and falls back to per-spec-file evidence rather than per-scenario evidence (see plan-conformance-criteria.md). Do NOT skip saving the file in degraded mode; the file path is part of the conformance audit's input contract.

If the project's regression policy is **deferred** (captured in Step 1), this is the SOLE full-regression run for the entire plan. It must pass before proceeding to Step 6 (Plan Conformance Audit).

**If acceptance criteria exist**: Also run the spec tests explicitly and report their status separately. All spec test scenarios must pass — this is the acceptance gate. If any spec test fails:
- Do NOT attempt to fix by modifying the spec test
- Check if the implementation is wrong (launch a Sonnet agent to investigate and fix the implementation)
- If the implementation appears correct but the spec test still fails, report the conflict to the user via AskUserQuestion — the user decides whether the spec needs revision

If tests fail, launch a Sonnet agent to investigate and fix, providing it with the test output and relevant file paths.

## Step 6: Plan Conformance Audit

Before code review, verify that every concrete behavior the plan promised is actually delivered in the diff. Reviewers focused on code quality have repeatedly missed missing-promise cases — this is a dedicated, single-responsibility gate that runs first.

Before launching the audit, output a one-line user-facing announcement: `Running plan-conformance audit on the diff (typical 2–5 min).`

1. Capture the full diff of all changes:

   ```bash
   git diff HEAD
   ```

   (or `git diff` if changes are unstaged)

2. Launch the `plan-conformance` agent with a prompt that includes:
   - The path to the plan file — tell it to read the file itself
   - The full git diff (the agent can't run git, so this must be in the prompt)
   - The path to the test-run output file saved in Step 5 (typically `/tmp/plan-conformance-test-run.txt`). If the file starts with the `# Per-test names unavailable from this runner — summary output only.` marker, note in the prompt that the audit must use its degraded-mode fallback per `plan-conformance-criteria.md` — this is a recognized mode, not a missing-input condition.
   - A reminder to read `~/workflows/planning/plan-conformance-criteria.md` for the output format
   - **Output instruction**: "Write your full audit (promise table, gaps, unpromised additions, verdict) to `/tmp/plan-conformance-audit.md`. In your final message back to the orchestrator, return ONLY: the verdict (`pass` / `gaps` / `unscorable`), the count of gaps by severity, and the file path. Do NOT paste the full table or analysis into your final message — the orchestrator will read the file. This avoids subagent-result truncation."

3. After the agent completes, read `/tmp/plan-conformance-audit.md` to get the full audit. If the file does not exist, or is clearly incomplete (e.g., no promise table, no verdict), the agent stopped early — use `SendMessage` to ping it back with: "You did not write the full audit to /tmp/plan-conformance-audit.md. Complete the audit per `plan-conformance-criteria.md` (including its Delivery Protocol) and write the file before returning." Then re-read the file. Examine the verdict:
   - **`pass`** — proceed to Step 7
   - **`gaps`** — see the malformed-plan marker routing below before deciding whether to auto-fix.
   - **`unscorable`** — the plan was too abstract to enumerate concrete promises. Note this in your end-of-step summary and proceed to Step 7; do not re-run.

   **Malformed-plan marker routing (Stage 2).** Before auto-launching a Sonnet fix subagent for `gaps`, scan the audit's `missing` and `partial` rows for any of the following malformed-plan markers in the Evidence/Gap column:

   - `malformed-chain` — `integration-only` step points at another `integration-only` step, or names a parent that doesn't exist
   - `planning-error: no step claims ownership` — a contract scenario is not listed on any step's `Covers:` line
   - `parent-Covers-not-superset` — `integration-only` step's Covers entry not on parent's Covers line

   If ANY such marker appears, do NOT auto-spawn a fix subagent — the fix is a planning revision, not a code change, and auto-fix would produce code that can't satisfy the audit. Instead, STOP and call `AskUserQuestion` summarising the malformed-plan rows with these options:

   1. **Revise the plan** — pause `/implement-plan`; the user fixes the plan manually (or via `/plan-review`); re-run `/implement-plan` afterwards.
   2. **Abort and review** — pause `/implement-plan`; treat as a planning failure requiring human attention.

   For `gaps` rows WITHOUT malformed-plan markers (regular missing-implementation or missing-test gaps), use the existing auto-fix flow: launch a Sonnet agent to deliver the missing behavior, then re-run the audit. The plan said this would happen, so closing the gap is the conservative move. Only stop and consult the user if (a) the implementation fix fails after one retry, or (b) the gap suggests the plan itself is wrong — e.g., delivering the promise would conflict with code that was deliberately added during implementation, or it would require scope changes the plan didn't anticipate. In the consult case, present the relevant gaps with your assessment and ask whether to implement, defer (mark the promise out of scope in the plan), or acknowledge and proceed.

   In legacy plans (no Stage 2 labels), malformed-plan markers cannot appear (no `Covers:` lines, no `integration-only` strategy); the existing auto-fix flow continues to apply unchanged.

   Do NOT proceed to Step 7 while the audit reports unresolved `gaps`.

4. "Unpromised Additions" listed by the audit are informational — note them in your end-of-step summary so the user sees them, but do not pause for input. They may indicate scope creep that belongs in a separate change; the user can flag any concerns.

5. Output a one-line user-facing summary of the audit result: `Conformance audit: <verdict> (<N gaps>). Next: code review.` (or `Next: pause on malformed-plan markers` if routing to user).

## Step 7: Code Review

Once the conformance audit passes (or its gaps have been resolved or accepted), launch adversarial code reviews.

CRITICAL: You MUST launch both reviews in the SAME message using multiple tool calls (one Agent for Step 7a, one Bash invoking the dispatched second-opinion CLI for Step 7b). Do NOT launch one, wait for it, then launch the other.

Before launching the reviews, output a one-line user-facing announcement: `Launching parallel code reviews — Claude + <reviewer-name> (typical 5–15 min each, running in parallel).`

Before launching, prepare the second-opinion prompt file (prerequisite for the Bash call).

### 7a: Claude Code Review Agent

Launch the `code-reviewer` agent with a prompt that includes:
- The path to the plan file — tell it to read the file itself
- The full git diff of all changes (`git diff` for unstaged, or `git diff HEAD` if staged) — the agent can't run git, so this must be included in the prompt
- **If acceptance criteria exist**: The spec file paths and a note: "These are specification tests (human-owned). Check that (1) they were not modified, and (2) the implementation semantically satisfies the behavior they describe — not just that the tests pass mechanically."
- **Output instruction**: "Write your full review to `/tmp/claude-code-review.md`. In your final message back to the orchestrator, return ONLY: an overall verdict, finding counts by severity (critical/major/minor/nit), and the file path. Do NOT paste the full review into your final message — the orchestrator will read the file. This avoids subagent-result truncation on long reviews."

Do NOT paste the plan contents into the agent prompt. The agent has read tools and should read the plan and CLAUDE.md/AGENTS.md directly.

After the agent finishes, read `/tmp/claude-code-review.md` to get the full review for consolidation in Step 8. If the file does not exist or is clearly incomplete (e.g., no findings sections), the agent stopped early — use `SendMessage` to ping it back with: "You did not write the full review to /tmp/claude-code-review.md. Complete the review per `code-review-criteria.md` (including its Delivery Protocol) and write the file before returning." Then re-read the file.

### 7b: Second-opinion Reviewer (configurable via `$CLAUDE_REVIEWER`)

The second-opinion CLI is selected at container build time and is one of `copilot` or `codex`. The wrong one is not installed — do NOT assume Copilot is available.

**Pre-dispatch — read the env var first.** Issue a Bash call to capture the value before doing anything else in this step:

```
echo "${CLAUDE_REVIEWER:-codex}"
```

Capture the result. Acceptable values are `copilot` or `codex`. If anything else, abort with: "CLAUDE_REVIEWER is set to an unsupported value. Run `bash setup-mac.sh --reconfigure-reviewers` on the Mac, then `dev <project> --rebuild`." Treat the captured string as a known constant for the rest of this step.

**Build the prompt file.** Write the review prompt to `/tmp/second-opinion-code-review-prompt.txt`. Include:
- The path to the plan file — instruct the reviewer to read it with its file-read tool
- The full git diff (the reviewer can't run git, so this must be in the prompt)
- The paths to CLAUDE.md and AGENTS.md — instruct the reviewer to read them with its file-read tool
- Instruct the reviewer to read `~/workflows/planning/code-review-criteria.md` for the full review checklist and output format

Do NOT paste the plan or CLAUDE.md/AGENTS.md contents into the prompt — the reviewer has its own file-read tools.

**Dispatch on the captured value.** Take exactly one of these branches:

- **`copilot` branch** — run in the background (`run_in_background: true`, Bash timeout 900000ms = 15 minutes). Pipe the prompt file on stdin to avoid argv-length limits on long reviews:

  ```
  cd /workspace && cat /tmp/second-opinion-code-review-prompt.txt | copilot \
    --model "$REVIEWER_COPILOT_MODEL" \
    --available-tools='view,glob,rg' \
    --no-ask-user
  ```

- **`codex` branch** — run in the background (same `run_in_background` and timeout). Pipe the prompt file on stdin:

  ```
  cd /workspace && cat /tmp/second-opinion-code-review-prompt.txt | codex exec \
    --sandbox read-only \
    --skip-git-repo-check
  ```

Notes (apply to both branches):
- If the Claude review (7a) finishes first and the second-opinion CLI is still running, inform the user. If it's been more than 5 minutes, note that it's taking longer than expected.
- If the second-opinion CLI times out after 15 minutes, ask the user whether to proceed with only the Claude review or retry.

## Step 8: Consolidate and Fix

Once BOTH reviews are complete, consolidate the feedback — group by severity, deduplicate, note consensus and disagreements — and present the summary to the user.

Then proceed without waiting for confirmation. Go through each piece of feedback:

- **Obviously valid**: Launch a Sonnet agent to fix it.
- **Obviously dismissible**: Dismiss it, briefly noting why.
- **Ambiguous at minor/nit severity**: Default to action without asking — apply if the fix is cheap and low-risk, dismiss otherwise. Note your call in the summary.
- **Ambiguous at critical/major severity**: Present it to the user with your assessment and ask.

Only stop and wait on ambiguous critical/major items. Do NOT pause for user approval before applying clear-cut fixes, dismissals, or low-severity judgment calls — the consolidated summary is informational, not a checkpoint.

After fixes, run the full test suite again to confirm nothing broke.

## Step 8b: Extended Round (only when Review depth is `extended`)

Skip this step entirely if the plan's `Review depth` field (captured in Step 1) is `single`. Otherwise, run one additional parallel code review on the post-fix diff. **Hard cap: one extra round only.** Even if round 2 surfaces new critical findings, do NOT run a round 3 — apply the Step 8 triage rule and proceed.

Before launching round 2, output a one-line user-facing announcement: `Launching extended-depth round 2 code reviews (typical 5–15 min each, running in parallel).`

Round 2 should be framed to look beyond what round 1 anchored on. Use the same parallel-launch mechanics as Step 7 (one Agent + one Bash invoking the dispatched second-opinion CLI, both in a single message), but with these differences:

- **Capture the post-fix diff freshly** with `git diff HEAD` (or `git diff` if unstaged) — round 2 reviews the current state, including round-1 fixes.
- **Output files use `-r2` suffixes** to avoid clobbering round 1: `/tmp/claude-code-review-r2.md` and `/tmp/second-opinion-code-review-prompt-r2.txt`.
- **Reviewer framing** — include this in both prompts:

  > This change has been through one round of adversarial review and revised in response. Round 1 already covered the obvious surface-level issues. Your job in this round is to surface what round 1 may have anchored away from: deeper architectural or functional concerns, second-order effects, security or correctness issues that weren't visible while the louder findings dominated the frame, and any new issues introduced by the round-1 fixes. Do not re-litigate items round 1 already raised and that the fixes addressed; focus on what's still latent.

- The reviewers should still read the plan and convention docs directly. They do NOT need round 1's findings — withholding them is intentional, to reduce anchoring.

After both round-2 reviews complete, run a compact version of Step 8 on the new findings: consolidate by severity, present to the user, then triage (obviously valid → Sonnet agent fixes; obviously dismissible → dismiss with note; ambiguous critical/major → ask user; ambiguous minor/nit → default to action without asking). After fixes, run the full test suite again.

Then proceed to Step 9.

## Step 9: Next Steps

All implementation and review is complete. Before presenting options, assess whether this implementation introduced decisions, patterns, or reasoning that would provide valuable context for future sessions (e.g., new architectural patterns, non-obvious trade-offs, convention changes). If so, suggest the `/finalize` option.

Note: `/finalize` itself now decides whether the implementation warrants an ADR (based on the plan's Motivation & Context section and the diff). Your assessment here is a hint — `/finalize` may second-guess it. Choosing `/finalize` doesn't commit you to producing an ADR; the skip path still ships the change with a richer commit message drawn from Motivation & Context.

Determine the current git state:
- What branch are we on?
- Is it `main` or a feature branch?
- Are there unstaged/staged changes?

Present options to the user, marking one as **(suggested)** based on your ADR assessment:

### If an ADR would be valuable:

1. Run `/finalize` — it will assess ADR worthiness, write one if warranted, and ship the change either way **(suggested)**
2. Remove plan file + commit and push to current branch
3. Remove plan file + create branch + push + create PR (if on main), or commit + push + create PR (if on branch)

### If an ADR is not needed:

1. Remove plan file + commit and push to current branch
2. Remove plan file + create branch + push + create PR (if on main), or commit + push + create PR (if on branch)
3. Run `/finalize` if you want it to decide the ADR question for you (it may agree no ADR is needed, in which case it ships with a richer commit message)

For options that remove the plan file, delete the plan file from `docs/plans/` and include that deletion in the commit.

When committing, stage all implementation changes plus the plan file deletion. Write a clear commit message summarizing what was implemented and why.

When creating a PR, include a summary of what was implemented, the test coverage, and any notable decisions.
