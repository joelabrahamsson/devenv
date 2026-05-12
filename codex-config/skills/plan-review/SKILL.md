---
name: plan-review
description: Create an implementation plan with adversarial review from both a Codex subagent and a configurable second-opinion CLI (Copilot or Claude), then revise and optionally implement. Invoke with $plan-review followed by a description of what to plan.
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

**Patterns section consultation.** If the agent doc (AGENTS.md or CLAUDE.md) contains a `## Patterns` heading, read the section. See `~/workflows/planning/patterns-format.md` for the section's purpose, format, and canonical citation phrase — entries map recurring problem-shapes to canonical exemplar files, and consulting the section here saves the downstream subagent grep-storm that would otherwise rediscover the same patterns from scratch. For each entry, verify the cited file path resolves (use the `shell` tool to check). If any entries are stale (cited file missing), surface them to the user as a numbered text prompt:

> The following Patterns entry has a stale exemplar path — the cited file no longer exists:
>
> **"<shape title>"** — Exemplar: `<stale path>`
>
> How would you like to handle this?
>
> 1) Type the corrected exemplar path, or `remove` to delete this entry from `## Patterns`, or `keep as-is` to leave it untouched and treat it as best-effort guidance for this plan only.
> 2) Leave it untouched (best-effort guidance for this plan only).

Wait for the user's reply. If the user responds with option 1 (typing a corrected path, `remove`, or `keep as-is`), apply the response verbatim by editing the agent doc, then continue plan design. If the user replies `2`, leave the entry untouched and proceed.

Consult the section before scanning the codebase for "the right pattern" — if a matching entry exists, use the cited exemplar directly. The matching entry (by shape title) is the input to sub-step 2c's per-step pattern citation. If the section is absent or empty, that's a graceful no-op — proceed without it and the steady-state curation paths (`$finalize` proposes incrementally, `$workflow-audit` back-fills in batch) will populate it over time.

**Coupling note with `$workflow-audit`.** `$plan-review` performing inline staleness fixes is a deliberate small expansion of plan-review's responsibilities (consume + maintain on detected staleness). `$workflow-audit`'s Stage A staleness check remains valuable for projects that haven't recently run `$plan-review`, and for batch fixes across many stale entries — `$plan-review` only sees the entries relevant to the current plan, not the full section. `$plan-review` does NOT propose new Patterns entries; that's `$finalize`'s job (incremental) and `$workflow-audit`'s job (batch).

### 2b: Derive Behavioral Contract

This sub-step derives the Gherkin scenarios that capture the user-observable behavior the implementation must deliver, presents them to the user, and gates on approval before plan design (sub-step 2c) begins. The contract becomes the high-leverage human checkpoint in a workflow the user otherwise trusts not to require code or test review.

If anything in this sub-step's prose contradicts the `Behavioral Contract` section spec in `~/workflows/planning/plan-format.md` (item 4 in Required Sections), the format spec wins — that is the authoritative reference.

Sub-step behavior:

1. **Spec file supplied with no additional behavioral scope.** Check whether Step 1's spec-file detection found a file with the `SPECIFICATION TEST` header AND whether the remaining `$ARGUMENTS` text contains additional scope. If a spec file was supplied AND the additional scope is empty or trivial (e.g., "just implement the spec"), skip derivation — the contract is the existing spec file, and the eventual plan's `Behavioral Contract` section will be the pointer form per plan-format.md. Tell the user: "Behavioral contract sourced from existing spec at `<path>` — no derivation needed."

2. **Spec file supplied WITH additional behavioral scope.** If a spec file was supplied AND the additional scope text describes extra user-observable behavior not covered by the spec (e.g., "also handle rate limiting and session expiry"), derive *supplemental* Gherkin scenarios for the additional scope only. The spec file remains the base. Present only the supplemental scenarios to the user for approval (the spec file content is assumed already user-approved from `$bdd-spec`). The plan's `Behavioral Contract` section becomes the pointer line plus a `### Supplemental scenarios` block.

3. **Trivially behavior-free change.** If the task description on its face is a refactor, mechanical rename, dependency bump, declarative-only addition, infra/config change, or exploratory spike, present the following numbered prompt to the user:

   > This task appears to have no user-observable behavioral change. Would you like to skip the contract step and use an escape line instead?
   >
   > 1) Yes — use the recommended escape line: `*No behavioral change — internal refactor.*` (or the appropriate canonical form from plan-format.md for this kind of change)
   > 2) No — derive scenarios anyway

   Wait for the user's reply. If the user confirms skip (replies `1`), record the chosen escape line for use in the plan's `Behavioral Contract` section.

4. **Derive scenarios (the normal case).** Otherwise, derive Gherkin scenarios from the original task description, conversation history, and codebase exploration from sub-step 2a. Apply the anti-inflation heuristic explicitly:

   > One scenario per distinct behavior or decision, NOT per distinct input variation. If two cases share the same observable outcome (e.g., wrong password and non-existent email both produce 'invalid credentials' error), they are one scenario, not two. As a soft target, aim for 5–7 scenarios per feature. If the natural count exceeds 10, pause and check whether the plan should be split into multiple plans.

5. **Identify property-shaped invariants.** If the change implies any property-shaped logic (round-trip identity, idempotence, ordering, schema-level constraints), draft them as bullets for the optional Invariants sub-section. Each invariant gets a short bolded title (e.g., `**Round-trip identity.** ...`) so that downstream test-naming rules (plan-conformance-criteria.md, $implement-plan SKILL.md) can use the bolded title as the canonical reference.

6. **Tag uncertainty.** For each scenario, tag it `confident` or `uncertain` (borrowed from `$bdd-spec`'s Stage 2 convention). Uncertain scenarios are ones the agent is guessing about — the user's judgment is needed. Tag scenarios uncertain conservatively; false-positive uncertainty is cheaper than silently asserting wrong behavior.

7. **Present and gate.** Render the proposed scenarios (and invariants, if any) to the user in full Gherkin format — `Feature:` lines INSIDE a fenced ` ```gherkin ` block, not as Markdown headings outside — with uncertain ones flagged. Then present the following numbered prompt:

   > Please review the proposed Behavioral Contract above. Choose one of the following:
   >
   > 1) **Approve** — proceed to plan design with these scenarios as the contract.
   > 2) **Edit** — type your redlines or revised scenarios as free-form text in your reply; the agent will revise and re-present for another approval round.
   > 3) **Abort** — cancel the planning workflow.

   Wait for the user's reply. Do NOT proceed to sub-step 2c without an `Approve` response (reply `1`). On `Edit` (reply `2`), accept the user's free-form redlines, revise the scenarios, re-present the revised Gherkin block, and re-gate with the same numbered prompt.

8. **Codebase-terminology cross-check (after Approve, before recording).** Before recording the final contract, briefly cross-check scenario terminology and preconditions against the codebase knowledge from sub-step 2a. If the contract uses a term that the codebase names differently (e.g., contract says "admin" but the codebase calls the same concept "superuser"), surface the discrepancy to the user as a single short note. Do NOT halt and do NOT re-gate. If the user wants the contract changed in response, revise and re-present scenarios at step 7 — but do NOT loop back to step 7 more than one additional time for terminology reasons; if a second round of terminology issues surfaces, record the contract as approved and continue, leaving the remaining adjustments for the user to make directly in the plan file. This is a soft check; its purpose is to prevent the contract from baking in stale or inconsistent terminology that propagates into tests and code.

9. **Record the result.** Capture the approved contract — full Gherkin scenarios + Invariants sub-section; or pointer + supplemental scenarios; or pointer-only; or escape line — for inclusion in the plan's `Behavioral Contract` section when sub-step 2c writes the plan file.

### 2c: Design the plan

- Ask the user clarifying questions as needed. **Constraint:** clarifying questions in 2c are limited to **design and implementation choices** (e.g., "which library?", "should this be a separate module?", "is the existing `FooHelper` the right place to extend?"). If a clarifying question would change *user-observable behavior* (e.g., "should we also handle rate limiting?", "should this be admin-only?"), abort the current 2c question and loop back to sub-step 2b to derive the additional behavioral scope and re-gate the contract. This preserves the "approval precedes design" invariant: the user always sees and approves behavioral scope before steps are designed around it.
- Before drafting the step-by-step plan, populate the plan's **Motivation & Context** section (see `~/workflows/planning/plan-format.md` for the field structure). Draw the content from the user's original request, conversation history, and clarifying-question answers. The four fields are:
  - **Problem** — synthesize from what the user described.
  - **Constraints** — extract hard requirements surfaced in conversation or in convention docs.
  - **Alternatives considered** — list approaches discussed (including ones the user dismissed) and the reason for rejecting each. If alternatives weren't surfaced and the change is non-trivial, ask the user directly what other approaches they considered before drafting this field.
  - **Decision rationale** — articulate why the chosen approach is correct given the problem, constraints, and alternatives.
  If the change is genuinely trivial (typo, mechanical rename, dependency bump), the section may be a single italicized line per `plan-format.md`. Both adversarial reviewers will read the entire plan including this section, and **may critique the reasoning** as well as the steps — `~/workflows/planning/review-criteria.md` includes a dedicated Motivation & Context checklist.
- Set the plan's **Review depth** field (see `~/workflows/planning/plan-format.md`). Use the Motivation & Context content as the input signal:
  - Default to `single`.
  - Choose `extended` only when the change is substantial in *functionality or architecture* — new subsystem, altered architectural boundaries, data-model or interface changes, security/auth/permissions changes, or cross-cutting effects across modules. Size alone is not a reason; a large mechanical refactor stays `single`.
  - Include a one-line reason that ties back to Motivation & Context (e.g., "introduces new permissions subsystem with cross-cutting request-pipeline effects").
- Design a step-by-step implementation plan
- **Classify each step's `test_strategy` field during design.** For every implementation step, assign exactly one of the four strategies (`red-first`, `build-then-test`, `property-based`, `integration-only`) per the classification heuristics in `~/workflows/planning/plan-format.md` § TDD Step Structure. Write the strategy inline on the step heading: `### Step N: Title — strategy: <value>`. For `integration-only` steps, also name the parent step: `### Step N: Title — strategy: integration-only (covered by Step M)`. Strategy labels are opt-in by spec but Codex's `$plan-review` always opts in — every new plan produced through this skill labels every step.

  **Heuristics summary** (the authoritative version lives in plan-format.md):
  - Novel logic, schema invariants, multi-state orchestration, bug fixes → `red-first`
  - Pattern-following CRUD, mechanical scaffolding from existing components → `build-then-test`
  - Pure transformation with extractable invariants (round-trip, idempotence, ordering) → `property-based`
  - Pure wiring or declaration (route registration, schema definitions, type-only changes, fixtures) → `integration-only`, with an explicit named parent step

  **Default when uncertain.** Choose `red-first`. False positives cost wall-clock; false negatives cost correctness. The contract gate from sub-step 2b is a safety net, but it's a coarse one — strategy classification is the finer-grained discipline.

  **Same strategy within grouped steps.** Adjacent steps that share a single edit surface can be grouped into one commit (per the step-grouping allowance), but only if they share the same `test_strategy`. Exception: an `integration-only` step grouped with its named parent is allowed.

  **Property-based framework prerequisite.** If you choose `property-based` for a step, verify the project already has a property-testing framework configured (e.g., `fast-check` in `package.json`, `hypothesis` in `pyproject.toml`). If not configured, choose a different strategy. Do NOT silently introduce a new dependency. Introducing a property-testing framework requires a separate prerequisite plan.

  **Property-based requires a contract Invariant.** `property-based` steps deliver invariants. The contract's `### Invariants` sub-section MUST contain at least one entry the step references via its `Covers:` line. If the contract has no relevant Invariants entry, either revise the contract during sub-step 2b's edit-and-re-gate loop to add one, or choose `red-first` and cover the scenarios with example tests instead. Step-local properties not anchored in the contract are not durable promises and won't be audited.

  **Spec-test interaction.** Steps that satisfy scenarios listed in the plan's `## Acceptance Criteria` section MUST use `red-first` strategy with the existing spec test as the RED phase. The other three strategies are not permitted for spec-satisfying steps. If a planner needs a different shape for such a step, revise the Acceptance Criteria to remove that scenario from the spec, or split the step.

- **Write the `Covers:` line on every contract-bearing step.** When the plan has a populated (non-escape) Behavioral Contract, for each step that delivers contract scenarios or invariants, add a `**Covers:**` line directly below the step heading listing the canonical titles per the parsing rules in plan-format.md. For `integration-only` steps, the Covers line names what the parent step's test must cover; the parent step's own Covers line MUST be a superset (include all the same canonical titles, no paraphrasing). Verify this superset rule before completing plan design — the pre-launch gate (Step 3) and `$implement-plan` validation will both check it, so catching mismatches here saves a round-trip.

- **Cite matching Patterns entries in step prose.** When sub-step 2a found a `## Patterns` section in the agent doc, check each step against the entries. If an entry's shape matches the work the step will implement, cite it inline using the **canonical citation phrase** from `~/workflows/planning/patterns-format.md`:

  ```
  per Patterns: "<shape title>"
  ```

  Literal: the text `per Patterns:`, a single space, then the entry's shape title verbatim in **double quotes** (matching the entry's bolded shape line exactly). Place the citation alongside a `mirror <path>` reference so the step reads as a coherent instruction. Example step prose:

  > 3.1 IMPLEMENT — Add `src/api/tags.ts`. Mirror `src/api/categories.ts` per Patterns: "New CRUD resource (API)" — same error envelope shape, pagination params, validation order.

  This phrase is what `$implement-plan` subagents see when reading the step, and what `$finalize` searches for at commit time when deciding whether to propose a new Patterns entry. Because the citation is exact-match rather than fuzzy, the downstream skills can rely on it without ambiguity. Use the exemplar file path from the entry as the step's structural anchor — subagents don't need to re-scan to find the right file.

While designing the plan, also:
- Determine the project's targeted (inner-loop) test command by inspecting tooling — `package.json` scripts, `pyproject.toml`, `Cargo.toml`, project convention docs, etc. This concrete command goes into the "Inner-loop test command" line of the Implementation Approach section.
- Identify any adjacent steps that share a single edit surface and could be implemented as one TDD cycle / one commit. List them explicitly at the end of the Implementation Approach section (e.g., *"Steps 5a–5d may be grouped into one commit."*). If none, say so.

The plan should be detailed enough that someone unfamiliar with the conversation could implement it. Include specific file paths, function names, test descriptions, and implementation details.

### When Acceptance Criteria Exist

If spec files were identified in Step 1:
1. Read the spec files to understand the required behavior
2. Include an "## Acceptance Criteria" section in the plan listing the spec file paths (see plan-format.md for the format)
3. For implementation steps that satisfy spec scenarios, the RED phase is "run the existing spec test and confirm it fails" rather than "write a new test" — the spec IS the failing test
4. Additional tests (integration, unit) should still be written per normal TDD for implementation details, edge cases, and any additional scope beyond the spec

The plan covers ALL the work needed — both satisfying the spec and any additional scope the user described. The spec provides the acceptance criteria, not the complete plan.

### Plan Format and TDD Structure

Read `~/workflows/planning/plan-format.md` for the required plan file format, TDD structure, and naming convention. Follow it exactly.

The Implementation Approach section is required to include the regression bar (inherited from project convention docs or the documented strict default), the inner-loop test command, and the step-grouping allowance — see plan-format.md for the exact wording.

When sub-step 2c writes the plan file, it MUST include the `## Behavioral Contract` section using the contract approved in sub-step 2b. The form depends on what 2b recorded:
- Full Gherkin scenarios (+ optional Invariants sub-section) — write inside a fenced ` ```gherkin ` block per plan-format.md.
- Pointer to spec file — single italicized line; `Acceptance Criteria` section must also be present in the plan.
- Pointer plus supplemental — pointer line + `### Supplemental scenarios` sub-heading + fenced Gherkin block for the supplements; `Acceptance Criteria` section must also be present.
- Escape line — single italicized line per the canonical forms in plan-format.md.

Once the plan is complete, write it to the location and format specified in plan-format.md.

⚠️ CRITICAL: Do NOT ask the user to review the plan. Do NOT present the plan for approval. You MUST complete Steps 3, 4, and 5 (adversarial reviews, consolidation, and revision) BEFORE presenting anything to the user. Tell the user the plan is written and you're now sending it for adversarial review, then immediately proceed to Step 3.

## Step 3: Parallel Adversarial Reviews

**Pre-launch gate:** Before launching reviews, confirm the plan file contains:

1. A populated `## Motivation & Context` section. Acceptable states: (a) all four fields populated with substantive content, (b) the section replaced with a single italicized "trivial change" line, or (c) individual fields marked `n/a` with a one-line justification. If the section is missing entirely, or any field is left as a placeholder/empty, return to sub-step 2c and complete it.
2. A populated `## Review depth` section with value `single` or `extended`. If missing or set to anything else, return to sub-step 2c and set it.
3. A populated `## Behavioral Contract` section in one of the acceptable forms per `~/workflows/planning/plan-format.md` (full Gherkin scenarios, pointer to spec file, pointer plus supplemental scenarios, or escape line). If the section is missing entirely, return to sub-step 2c (which sources the section content from 2b's captured result) and complete it. If the section uses the **pointer** form but no `## Acceptance Criteria` section is present, the plan is malformed — treat as a missing-section failure and return to sub-step 2c. Back-compat note: this gate runs only when generating a new plan, so legacy plans without the section are never seen here.
4. **Strategy labels and `Covers:` lines** (Stage 2 — only enforced when this plan-review skill produced the plan, since Codex's `$plan-review` always opts in by labeling). Verify every implementation step heading carries a `— strategy: <value>` suffix with one of the four accepted values (`red-first`, `build-then-test`, `property-based`, `integration-only`). Mixed labeled/unlabeled steps is malformed. For each `integration-only` step, verify the named parent step exists, isn't itself `integration-only`, and that this step's `Covers:` line entries appear identically on the parent's `Covers:` line (parent-superset rule). Verify every step that delivers contract scenarios carries a `**Covers:**` line directly below its heading, parseable per the format spec (comma-space separator; tokens are `"quoted scenario"` or `**bold invariant**`; no embedded double quotes in titles). Verify grouped steps share a strategy (except the integration-only-with-parent grouping). Verify `property-based` steps' Covers entries (invariant titles) exist as bolded entries in the Behavioral Contract's `### Invariants` sub-section. If any check fails, return to sub-step 2c and correct before launching reviews. This gate and `$implement-plan` Step 1's pre-dispatch validation are functionally duplicated for defense in depth and MUST stay in sync — when adding a check to one, mirror it in the other.

Do NOT launch the parallel reviews until all four gates pass.

CRITICAL: You MUST launch both reviews simultaneously. Use `spawn_agent` for the Codex adversarial review and `shell` for the second-opinion CLI in the same turn.

Before launching, write the second-opinion review prompt to a temporary file (prerequisite for the shell call).

### 3a: Codex Adversarial Subagent Review

Read `references/adversarial-reviewer.md` for the subagent instructions template. Use `spawn_agent` with a prompt that includes:
- The instructions from the reference file
- The original goal/task description
- The path to the plan file

### 3b: Second-opinion Reviewer (configurable via `$CODEX_REVIEWER`)

The second-opinion CLI is selected at container build time and is one of `copilot` or `claude`. The wrong one may not be installed — do NOT assume Copilot is available.

**Pre-dispatch — read the env var first.** Use the `shell` tool to capture the value before doing anything else in this step:

```
echo "${CODEX_REVIEWER:-claude}"
```

Capture the result. Acceptable values are `copilot` or `claude`. If anything else, abort with: "CODEX_REVIEWER is set to an unsupported value. Run `bash setup-mac.sh --reconfigure-reviewers` on the Mac, then `dev <project> --rebuild`." Treat the captured string as a known constant for the rest of this step.

**Build the prompt file.** Write the review prompt to `/tmp/second-opinion-plan-review-prompt.txt`. The prompt content is reviewer-agnostic and should contain:
- The original goal/task description (refined version after user Q&A)
- The path to the plan file — instruct the reviewer to read it directly with its file-read tool
- The paths to AGENTS.md and CLAUDE.md (if they exist) — instruct the reviewer to read them directly
- Instruction to read `~/workflows/planning/review-criteria.md` for the full review checklist and output format

Do NOT paste file contents into the prompt — the reviewer has its own file-read tools.

**Dispatch on the captured value.** Take exactly one of these branches:

- **`copilot` branch** — run in the background with a 15-minute timeout:

  ```
  cd /workspace && copilot -p "$(cat /tmp/second-opinion-plan-review-prompt.txt)" \
    --model "$REVIEWER_COPILOT_MODEL" \
    --available-tools='view,glob,rg' \
    --no-ask-user
  ```

  `$REVIEWER_COPILOT_MODEL` expands at exec time from the container env. Note: this differs from the previous behaviour, which hardcoded `--model sonnet` regardless of user preference; the configured model now applies.

- **`claude` branch** — run in the background with a 15-minute timeout:

  ```
  cd /workspace && claude -p "$(cat /tmp/second-opinion-plan-review-prompt.txt)" \
    --output-format text \
    --dangerously-skip-permissions \
    --no-session-persistence \
    --allowedTools "Read Glob Grep"
  ```

  `--no-session-persistence` keeps the inner Claude from writing a session file that could collide with an outer Codex session. `--allowedTools "Read Glob Grep"` constrains the inner Claude to read-only tools. `--output-format text` ensures plain-text stdout suitable for capture.

Notes (apply to both branches):
- If the Codex subagent review (3a) finishes first and the second-opinion CLI is still running, inform the user.
- If the second-opinion CLI times out after 15 minutes, inform the user and ask whether to proceed with only the Codex review or retry.

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

## Step 5b: Extended Round (only when Review depth is `extended`)

Skip this step entirely if the plan's `Review depth` field is `single`. Otherwise, run one additional parallel review on the revised plan. **Hard cap: one extra round only.** Even if round 2 surfaces new critical findings, do NOT run a round 3 — apply the Step 5 triage rule and proceed.

Round 2 should be framed to look beyond what round 1 anchored on. Use the same parallel-launch mechanics as Step 3 (`spawn_agent` for the Codex adversarial review and `shell` for the second-opinion CLI in the same turn), but with these differences:

- **Output files use `-r2` suffixes** to avoid clobbering round 1: write the second-opinion prompt to `/tmp/second-opinion-plan-review-prompt-r2.txt`.
- **Reviewer framing** — include this in both prompts:

  > This plan has been through one round of adversarial review and revised in response. Round 1 already covered the obvious surface-level issues. Your job in this round is to surface what round 1 may have anchored away from: deeper architectural or functional concerns, second-order effects, and issues that would have been visible if round 1's findings hadn't dominated the frame. You may also raise new issues introduced by the revisions. Do not re-litigate items that round 1 already raised and that the revisions addressed; focus on what's still latent.

- The reviewers should still read the plan file directly (don't paste it). They do NOT need round 1's findings — withholding them is intentional, to reduce anchoring.

After both round-2 reviews complete, run a compact version of Steps 4 and 5 on the new findings: consolidate by severity, present to the user, then triage (obviously valid → revise; obviously dismissible → dismiss with note; ambiguous critical/major → ask user; ambiguous minor/nit → default to action without asking). Append the further revisions to the same `## Revision Notes` section in the plan, marked as round 2.

Then proceed to Step 6.

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

When implementing the plan (Options 1 or 3), follow each step's declared `test_strategy` per the shape defined in `~/workflows/planning/plan-format.md` § TDD Step Structure:

- **`red-first`** uses strict RED → RUN → GREEN → RUN → REFACTOR (the prior default).
- **`build-then-test`** uses IMPLEMENT → TESTS (with non-tautology assertion check) → RUN → REFACTOR.
- **`property-based`** uses INVARIANTS → PROPERTY TESTS → EXAMPLE TESTS → RUN → GREEN → RUN → REFACTOR.
- **`integration-only`** uses IMPLEMENT → smoke-check existing tests (do not run the named parent step's test if the parent hasn't executed yet).

For plans authored before Stage 2 (no strategy suffixes on any step heading), default every step to `red-first`. Move to the next step only after the current step's tests are green for strategies that produce per-step tests. For `integration-only` steps, move on after the wiring is committed and the smoke-check shows no regressions; the parent step's test verifies coverage when the parent executes (or at end-of-plan via the conformance audit).
