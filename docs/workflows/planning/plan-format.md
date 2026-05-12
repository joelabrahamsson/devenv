# Plan File Format

## File Location and Naming

Plans are written to `docs/plans/YYYY-MM-DD-short-description.md` — date plus a brief kebab-case summary (e.g., `2026-04-05-add-team-squad-view.md`). Create the `docs/plans/` directory if it doesn't exist.

## Required Sections

1. **Goal** — the original task description, including any refinements from user Q&A.

2. **Motivation & Context** — captures the *why* behind the plan. Required, but allows escape hatches for trivial changes. The four fields:

   - **Problem.** What's wrong or what need is being addressed. Synthesize from the user's request and conversation.
   - **Constraints.** Hard requirements, deadlines, compatibility boundaries, security boundaries, regulatory limits — anything non-negotiable that shaped the design.
   - **Alternatives considered.** Other approaches discussed (including ones the user dismissed) and the reason for rejecting each. If alternatives weren't surfaced in conversation and the change is non-trivial, ask the user before drafting this field.
   - **Decision rationale.** Why this approach was chosen given the problem, constraints, and alternatives.

   Each field is a bold inline label on its own paragraph. For trivial plans (typo fixes, mechanical renames, dependency bumps with no decision content), the entire section may be replaced by a single italicized line such as `*Trivial change — no significant motivation or alternatives.*` Each individual field may also be set to `n/a` with a one-line justification.

   This section is the primary input that `/finalize` uses to populate the ADR's Context and Decision sections, and to decide whether an ADR is warranted at all. Adversarial reviewers will critique the reasoning here as well as the steps — see `~/workflows/planning/review-criteria.md`.

   ### Rendered example of a populated Motivation & Context section

   ```markdown
   ## Motivation & Context

   **Problem.** The build pipeline rebuilds the full asset graph on every commit, which has grown from 30s to 6 minutes as the project has grown. Developers run the full build locally before every push, so the slowdown compounds across the team.

   **Constraints.** Cannot break the existing artifact paths — downstream deploy scripts hardcode them. Must keep the single-command entry point (`pnpm build`) for CI compatibility.

   **Alternatives considered.**
   1. *Switch bundlers entirely (esbuild → rspack).* Rejected: large migration, no measured wins for our specific shape of graph.
   2. *Cache the full bundler output by content hash.* Rejected: doesn't help local rebuilds where the cache is cold.
   3. *Incremental rebuilds keyed on changed entrypoints.* Chosen — addresses the actual slow path (most local rebuilds change 1-2 entrypoints) without changing tooling.

   **Decision rationale.** Incremental rebuilds match how developers actually iterate (small file changes), preserve all artifact paths and CI surface, and avoid a high-risk bundler swap. The only trade-off is a one-time stamp file in the repo cache directory.
   ```

3. **Review depth** — controls how many adversarial review rounds run during `/plan-review` and `/implement-plan`. One bold inline label and value on its own line, optionally followed by a short reason that ties back to Motivation & Context.

   - **`single`** (default) — one parallel review round in each skill.
   - **`extended`** — one additional parallel review round after the round-1 revision/fix, scoped to the new state and framed to surface deeper concerns that round 1 may have anchored away from.

   Choose `extended` when the change is substantial in *functionality or architecture*: introduces a new subsystem, alters architectural boundaries, changes data models or interfaces, modifies security/auth/permissions, or has cross-cutting effects across modules. **Do not choose `extended` based on size alone** — a 50-step mechanical refactor may be `single`; a 5-step auth change may be `extended`.

   The planner sets the value during plan generation; the user can override it before review begins. Maximum one extra round per skill — never run a third round, even if round 2 surfaces new findings.

   ### Rendered example

   ```markdown
   ## Review depth

   **extended** — introduces a new permissions subsystem with cross-cutting effects on the request pipeline.
   ```

4. **Behavioral Contract** — captures the user-observable behaviors the implementation must deliver, expressed in Gherkin (`Feature` / `Scenario` / `Given` / `When` / `Then`). This is the human-reviewed contract that the `plan-conformance` audit verifies the implementation against. It is approved by the user during `/plan-review` sub-step 2b, before plan design begins, so the steps can be designed against approved behavior rather than the other way around.

   **Placement.** Required in every new plan. Insert between `Acceptance Criteria` (when present) and `Implementation Approach`. When no `Acceptance Criteria` section exists (the common case), `Behavioral Contract` follows `Review depth` directly.

   Required ordering: Goal → Motivation & Context → Review depth → [Acceptance Criteria — only if spec files were supplied] → **Behavioral Contract** → Implementation Approach → Implementation Steps.

   **Acceptable forms.**

   1. **Full Gherkin scenarios.** Used when the change has user-observable behavior. One `Scenario` per distinct behavior, not per input variation. Each scenario has a title plus Given/When/Then body. Scenarios MUST be wrapped in a single fenced ` ```gherkin ` block (or one block per Feature); `Feature:` lines live *inside* the fence with their scenarios, not as Markdown headings outside it. This keeps the contract parseable by tools that expect Gherkin.

   2. **Pointer to existing spec file.** Used when an `Acceptance Criteria` section lists spec files produced by `/bdd-spec` AND the spec covers the full user-observable scope (no additional behavioral scope was supplied alongside the spec). The section content is a single italicized line:

      ```markdown
      *See acceptance criteria spec — file path listed in the Acceptance Criteria section above.*
      ```

      **Constraint:** the pointer form may *only* be used when an `## Acceptance Criteria` section is also present in the plan. The conformance audit and `/finalize` both resolve the pointer by reading the file paths from `Acceptance Criteria`. If a plan uses the pointer form without an `Acceptance Criteria` section, this is a malformed plan — the `/plan-review` pre-launch gate will treat it as a missing/incomplete section.

   3. **Pointer plus supplemental scenarios.** Used when a spec file is supplied AND additional behavioral scope was passed alongside it. Begin with the pointer line, then a `### Supplemental scenarios` sub-heading containing the Gherkin block for the additional scope. The conformance audit treats the spec scenarios and supplemental scenarios as a combined promise set.

   4. **Optional Invariants sub-section.** For property-shaped logic that doesn't fit Gherkin (round-trip identity, idempotence, ordering invariants, schema-level constraints). Rendered as a `### Invariants` sub-heading under `## Behavioral Contract`, with one bullet per invariant. Each invariant SHOULD use a short bolded title (e.g., `**Round-trip identity.** ...`) so that test-naming rules (plan-conformance-criteria.md, implement-plan SKILL.md) can use the bolded title as the canonical reference for traceability. May appear alongside Gherkin scenarios or alone.

   5. **Escape line.** Used for changes with no user-observable behavior — pure refactors, mechanical renames, dep bumps, pure declarative additions where no downstream code path changes behavior as a result, pure infra/config, exploratory spikes. Replaces the entire section content with a single italicized line. Acceptable forms:

      - *No behavioral change — internal refactor.*
      - *No behavioral change — mechanical rename.*
      - *No behavioral change — dependency bump.*
      - *No behavioral change — declarative-only (schema/types/fixtures), no downstream behavioral change.*
      - *No behavioral change — infra/config.*
      - *Exploratory — contract intentionally skipped.*

      **Declarative-only escape caveat.** Many schema, type, or fixture additions DO have user-observable behavioral implications — a new required column changes validation; a type change alters an API shape; a fixture supports a new test scenario. The declarative-only escape is valid *only* when the change is genuinely additive and provably introduces no downstream behavioral change in any user-facing code path. When in doubt, write scenarios — do not escape.

   **Anti-inflation guidance.** One scenario per distinct behavior or decision, NOT per distinct input variation. If two cases share the same observable outcome (e.g., wrong password and non-existent email both produce 'invalid credentials' error), they are one scenario, not two. As a soft target, aim for 5–7 scenarios per feature. If the natural count exceeds 10, pause and check whether the plan should be split into multiple plans.

   **Constraint on canonical titles** (load-bearing for Stage 2's `Covers:` line parsing). Scenario titles (the text after `Scenario:` in a Gherkin block) and invariant titles (the bolded text at the start of each invariant bullet) MUST NOT contain double-quote characters (`"`) or the comma-space sequence (`, `). If a scenario semantically needs to reference a quoted phrase (e.g., user sees a literal `"Access denied"` message), use single quotes or paraphrase the title (e.g., `Scenario: Access denied error appears` plus Given/When/Then bodies that name the literal text). If a title would naturally read with a comma followed by a space, restructure it (e.g., `Scenario: Tags created, updated, and deleted` becomes `Scenario: Tags CRUD lifecycle is round-trippable`). These constraints exist so the Stage 2 per-step `Covers:` line parser (which uses comma-space as token separator and double quotes as scenario-title delimiters) can unambiguously identify each token.

   **Back-compat.** Plans authored before this section was introduced may not contain a `Behavioral Contract` section. Such plans remain valid; the `plan-conformance` audit treats their absence as a documented exemption and continues with only the existing concrete-promise audit.

   ### Rendered examples of populated Behavioral Contract sections

   These examples are illustrative. If anything in any example conflicts with the spec text above, the spec text wins.

   **Full Gherkin example (the common case):**

   ````markdown
   ## Behavioral Contract

   ```gherkin
   Feature: Saved facet filter views

     Scenario: Save current filters as a named view
       Given the user has filters applied to the venue list
       When the user clicks "Save view"
       And enters a name and confirms
       Then the named view appears in the saved views menu
       And selecting it re-applies the current filter set

     Scenario: Apply a saved view
       Given the user has at least one saved view
       When the user opens the saved views menu
       And selects a view
       Then the venue list updates to show only matching venues

     Scenario: Rename a saved view
       Given the user has at least one saved view
       When the user opens the saved view's menu
       And chooses Rename and provides a new name
       Then the new name appears in the saved views menu

     Scenario: Delete a saved view
       Given the user has at least one saved view
       When the user opens the saved view's menu
       And chooses Delete and confirms
       Then the view is removed from the saved views menu
   ```

   ### Invariants

   - **Per-user ownership.** Saved views are scoped to the creating user; no user sees another user's views.
   - **URL round-trip identity.** Applying a saved view, serialising the URL, and re-parsing the URL yields the same filter state.
   ````

   **Pointer-only example (when the spec file covers full scope):**

   ````markdown
   ## Acceptance Criteria
   - test/specs/auth/user-login.spec.ts (all scenarios must pass)

   ## Behavioral Contract

   *See acceptance criteria spec — file path listed in the Acceptance Criteria section above.*
   ````

   **Pointer-plus-supplemental example (spec file + additional scope):**

   ````markdown
   ## Acceptance Criteria
   - test/specs/auth/user-login.spec.ts (all scenarios must pass)

   ## Behavioral Contract

   *See acceptance criteria spec — file path listed in the Acceptance Criteria section above.*

   ### Supplemental scenarios

   ```gherkin
   Feature: Rate-limited login attempts

     Scenario: Login attempt after rate limit reached
       Given the user has failed login five times in the last minute
       When they attempt to log in again
       Then they see "Too many attempts; please wait"
       And the form is disabled for one minute
   ```
   ````

   **Escape-line example:**

   ````markdown
   ## Behavioral Contract

   *No behavioral change — internal refactor.*
   ````

5. **Implementation Approach** — must include all four items below (a–d). The planner is responsible for filling in the project-specific text for items b and c, and for identifying any grouping candidates in item d.

   **a. TDD reminder** (include this exact text):
   > Each step declares a `test_strategy` (one of `red-first`, `build-then-test`, `property-based`, `integration-only`; see TDD Step Structure section below). The implementer follows the shape that matches each step's strategy. Plans authored before Stage 2 (no strategy labels on any step) default to `red-first` for every step. Regardless of strategy, every step's contract-scenario coverage is verified by the post-implementation conformance audit.

   **b. Regression bar — inherited from the project.**
   - If the project's `AGENTS.md` / `CLAUDE.md` documents a regression-testing convention (tiered gates per phase or per commit category, or a strict "run everything" rule), paraphrase or quote the relevant section verbatim into this plan. If tiering is documented, reflect it verbatim — do not flatten it into a stricter bar.
   - If the project documents no convention, write: *"No project-level regression convention found; defaulting to running the full project test suite at every commit boundary."*

   **c. Inner-loop test command** (project-agnostic phrasing, with a concrete command filled in by the planner):
   > Inner-loop test command — during RED/GREEN/REFACTOR, run a targeted test command for the file(s) under change, not the project's full test suite. Reserve the full gate for the commit boundary.
   >
   > For this project, the targeted command is: `<concrete command, e.g. pnpm vitest run <path>, pytest <path>, cargo test --test <name>>`

   The planner infers the concrete command from project tooling (`package.json` scripts, `pyproject.toml`, `Cargo.toml`, project convention docs).

   **d. Step grouping allowance** (include this exact text):
   > Step grouping — adjacent steps that share a single edit surface and can be implemented as one TDD cycle may be combined into one commit (one gate run instead of two or three). Group only when the steps share a coherent commit message; don't group across phases or unrelated decisions.

   The planner identifies candidate groupings during plan generation and lists them explicitly at the end of the Implementation Approach section, e.g. *"Steps 5a–5d may be grouped into one commit."* If no groupings apply, write *"No step groupings identified."*

   ### Rendered example of a fully populated Implementation Approach section

   ```markdown
   ## Implementation Approach

   This plan follows a strict TDD workflow. For each step: write failing tests first, verify they fail, implement the minimum code to pass, verify they pass, then refactor if needed. Never skip ahead to implementation without a failing test.

   **Regression bar (inherited from AGENTS.md §"Test tiers"):**
   > Run component tests on every commit. Run flow tests at the end of each phase. Run e2e only before opening the PR.

   **Inner-loop test command** — during RED/GREEN/REFACTOR, run a targeted test command for the file(s) under change, not the project's full test suite. Reserve the full gate for the commit boundary.
   For this project, the targeted command is: `pnpm vitest run <path>`

   **Step grouping** — adjacent steps that share a single edit surface and can be implemented as one TDD cycle may be combined into one commit (one gate run instead of two or three). Group only when the steps share a coherent commit message; don't group across phases or unrelated decisions.

   Candidate groupings: Steps 2a–2c (single new module, one TDD cycle).
   ```

6. **Implementation Steps** — each step that involves code changes MUST follow the TDD structure below.

## TDD Step Structure

### Per-step strategy (opt-in)

Each implementation step MAY declare a `test_strategy` field inline on the step heading. Accepted values:

- `red-first` (the default; current strict TDD — assumed when no label is present)
- `build-then-test`
- `property-based`
- `integration-only`

Declaration format: `### Step N: Title — strategy: <value>`.

Strategy labels are **opt-in, not mandatory**. A plan with NO strategy labels on any step is interpreted as all `red-first` (current behavior, unchanged from pre-Stage-2). A plan with labels on any step MUST label every step — mixing labeled and unlabeled steps in the same plan is malformed and is caught by both the `/plan-review` pre-launch gate and the `/implement-plan` pre-dispatch validation.

Plans authored by `/plan-review` (claude-config) and `$plan-review` (codex-config) both opt in by labeling every step — both planners are configured to do so. Plans authored outside these skills (hand-written, legacy, pre-Stage-2, or via external tooling) without `test_strategy` labels remain valid and are interpreted as all-`red-first`. All paths are valid; all are backward compatible.

### Step shapes (one per strategy)

The TDD-cycle shape that each step follows depends on its `test_strategy`. Plans without labels (legacy / opt-out) use the `red-first` shape for every step (the historical default).

**`red-first` shape (default; five sub-steps):**

1. **`N.1 RED`**: Write the test(s) first. Describe what test file, test name, and assertions to create.
2. **`N.2 RUN`**: Run the tests and verify they fail for the expected reason.
3. **`N.3 GREEN`**: Write the minimum implementation code to make the tests pass.
4. **`N.4 RUN`**: Run the tests and verify they pass.
5. **`N.5 REFACTOR`** (if needed): Clean up the implementation while keeping tests green.

**`build-then-test` shape (four sub-steps):**

1. **`N.1 IMPLEMENT`**: Build the code following the pattern named in the step description (the step prose MUST name a specific anchor file or component).
2. **`N.2 TESTS`**: Write tests that capture the new behavior as regression guards. Tests must cover every contract scenario this step delivers (named per the scenario-and-invariant test naming rule). Each test must assert specific output values, not merely that no exception is raised. **Non-tautology requirement:** for each test, verify the test would FAIL if the implementation body were deleted or replaced with a stub returning a hard-coded wrong value. If you can't identify such a mutation, the test is tautological and must be rewritten.
3. **`N.3 RUN`**: Run tests, verify all pass.
4. **`N.4 REFACTOR`** (if needed): Clean up.

The test-first sequencing is deliberately not used because the existing pattern named in the step prose provides the structural anchor; the non-tautology requirement provides the collusion guard that would otherwise come from RED-first sequencing.

**`property-based` shape (seven sub-steps):**

1. **`N.1 INVARIANTS`**: Name the invariants the implementation must satisfy. Each invariant MUST exist as a bolded entry in the Behavioral Contract's `### Invariants` sub-section — step-local properties drawn only from step prose are not durable contract-level commitments and won't be enumerated as `[invariant]` promises by the conformance audit. If the contract has no relevant Invariants entry, choose a different strategy or revise the contract.
2. **`N.2 PROPERTY TESTS`**: Write property-based tests using the project's property-testing framework (e.g., `fast-check` for TypeScript, `hypothesis` for Python). Each property test name MUST contain the referenced invariant's bolded title as a substring.
3. **`N.3 EXAMPLE TESTS`**: Write 2–3 concrete example tests that cover the contract scenarios this step delivers.
4. **`N.4 RUN`**: Verify both property tests and example tests fail.
5. **`N.5 GREEN`**: Implement.
6. **`N.6 RUN`**: Verify all tests pass.
7. **`N.7 REFACTOR`** (if needed): Clean up.

**`integration-only` shape (two sub-steps):**

1. **`N.1 IMPLEMENT`**: Build the wiring or declaration described in the step.
2. **`N.2 RUN`**: Run a smoke check that the existing test suite still passes (no regression in already-shipped tests). Do **NOT** attempt to run the named parent step's test if the parent has not yet executed — by definition, a parent step that comes later in execution order has no test in the repository yet. The parent's test runs when the parent step itself executes; the post-implementation conformance audit verifies the parent test exists and passes end-to-end.

**Parent-step relationship requirement for `integration-only`.** Every `integration-only` step MUST name the parent step that ultimately covers its contract scenarios, on the same line as the strategy declaration: `### Step N: Title — strategy: integration-only (covered by Step M)`. The named parent must exist in the same plan and must NOT itself be `integration-only` (chained `integration-only` is malformed). The conformance audit verifies the parent-step relationship resolves and that the parent's tests pass.

**Execution-order constraint.** The named parent step MAY come *after* the integration-only step in execution order — this is normal (you typically wire something up, then test it via an integration test that exercises the wiring). The integration-only step does NOT block on the parent test passing at the time it executes; it only commits its wiring. The parent's test passing is verified later, either at the parent's own RUN or by the conformance audit at end-of-plan.

**Grouping option.** Alternatively, an `integration-only` step MAY be grouped with its parent step into a single commit (per the step-grouping allowance in Implementation Approach), in which case both the wiring and the test land together. When grouped, sequencing within the grouped subagent run is fixed: first complete the integration-only IMPLEMENT (set up the wiring); only THEN begin the parent's full TDD shape (starting at RED or IMPLEMENT depending on the parent's strategy). Reversing the order would cause the parent's RED-phase tests to fail for the wrong reason (missing wiring rather than missing implementation).

### When to choose each strategy (classification heuristics)

Choose **`red-first`** when:
- The step implements novel logic not closely modeled on existing code in the project.
- The test catches a hard-to-spot invariant (e.g., a composite foreign key, a non-trivial validation rule, a security check).
- The step orchestrates multiple pieces of state with non-obvious interactions (save / undo / error / apply flows; multi-step wizards).
- The step fixes a bug (the test is the repro).

Choose **`build-then-test`** when:
- The step follows an existing pattern in the codebase that is well-understood and well-tested (e.g., another CRUD endpoint of the same shape; another component using the same UI primitives).
- The implementation is mechanical given the pattern; the test would mostly mirror the implementation.
- Tests are still required — write them after the implementation to capture behavior as regression guards.

Choose **`property-based`** when:
- The step implements a pure transformation (serialise / parse, encode / decode, normalise).
- There are extractable invariants: round-trip identity, idempotence, ordering, commutativity, monotonicity. **At least one invariant must already exist as a bolded entry in the Behavioral Contract's `### Invariants` sub-section** — `property-based` is the strategy for delivering contract invariants. If the relevant invariant is not in the contract, either add it via revision of the Behavioral Contract, or choose `red-first` and cover the scenarios with example tests instead.
- **The project already has a property-testing framework configured.** If not configured, choose a different strategy. Introducing a new property-testing framework is out of scope; file a separate prerequisite plan if needed.

Choose **`integration-only`** when:
- The step is pure wiring or declaration: route registration, module imports, Drizzle schema definitions, type definitions, JSON fixtures, configuration changes.
- The step's correctness is observed through a parent step's integration test, not by anything testable in isolation.
- The parent step must be named explicitly on the step heading (see Parent-step relationship requirement above).
- **Disambiguating gate (use this when uncertain between `integration-only` and a test-producing strategy):** Does the step have any downstream behavioral implication if implemented incorrectly that the named parent step's test would NOT catch? Examples: middleware order, schema constraints not exercised by the parent test, configuration values consumed by code paths the parent doesn't cover. If yes, the step is not `integration-only` — choose `red-first` and write a per-step test that catches the specific downstream implication.
- **Never use `integration-only` for behavior-bearing code.** A misclassified `integration-only` step removes the per-step verification gate; reviewers flag this as a Critical issue.

**Default when uncertain.** When in doubt, choose `red-first`. False positives (overly cautious TDD on a step that didn't need it) cost wall-clock; false negatives (skipping verification on a step that needed it) cost correctness.

### Step grouping interaction

Grouped steps (per the step-grouping allowance in Implementation Approach) MUST share the same `test_strategy`. Grouping steps with different strategies into one commit would conflate different TDD shapes; if multiple steps share an edit surface but need different strategies, do not group them. **Exception:** an `integration-only` step grouped with its named parent step is allowed even though their strategies differ — this is the explicit `integration-only`-with-parent grouping option.

### Per-step `Covers:` line for contract-scenario and invariant mapping

When the plan has a populated Behavioral Contract section (any non-escape form) AND any step in the plan is labeled with `test_strategy` (opt-in), each implementation step that delivers contract scenarios or invariants MUST include a `**Covers:**` line **immediately below** the step heading, listing the canonical titles of every scenario and invariant that step is responsible for delivering.

**Format and parsing rules** (load-bearing for the conformance audit; specified here so the orchestrator parser and the conformance auditor agree on syntax):

- The line is a single Markdown line starting with `**Covers:**` (literal, no whitespace before).
- After the colon, a space, then a comma-space (`, `) separated list of tokens.
- Each token is one of:
  - **A scenario reference**: a double-quoted string. Example: `"Save current filters as a named view"`. The token starts and ends with `"`. Outer quotes are stripped to obtain the canonical title.
  - **An invariant reference**: a Markdown bold marker. Example: `**Round-trip identity**`. The token starts with `**` and ends with `**`. Outer markers are stripped to obtain the canonical title.
- Empty list (`**Covers:** `) is NOT allowed; if a step has no contract obligations, omit the line entirely.
- **Constraint on canonical titles.** To make `Covers:` lines unambiguously parseable, scenario and invariant canonical titles in the Behavioral Contract section MUST NOT contain double-quote characters or the comma-space (`, `) sequence. (The Behavioral Contract section spec, item 4 above, is updated to add this constraint.) If a scenario semantically needs to reference a quoted phrase (e.g., user sees a literal `"Access denied"` message), use single quotes or paraphrase the title.
- **Trailing period normalization.** Invariant titles in the Behavioral Contract may carry a trailing period (e.g., `**Round-trip identity.**`). The `Covers:` line MAY omit the trailing period in the bold token (`**Round-trip identity**`). The conformance auditor strips trailing periods when comparing canonical titles.
- **Parse failure handling.** If a `Covers:` line cannot be parsed under these rules, the `/implement-plan` pre-dispatch validation STOPs and reports the parse failure to the user. It does NOT silently default to no coverage.

This mapping enables the conformance audit to know which step owns which promise, which is required for evidence rules and the `integration-only` parent-coverage rule.

The `Covers:` line is REQUIRED on every labeled step (strategy `red-first`, `build-then-test`, or `property-based`) whose work delivers at least one contract scenario or invariant. It is REQUIRED on every labeled `integration-only` step whose contract scenarios are covered by its parent. It is OPTIONAL on steps that don't deliver contract scenarios (e.g., a refactor step inside a feature plan with an escape-line contract). It is NOT EXPECTED on unlabeled plans (which are interpreted as legacy / all-`red-first`; the conformance audit falls back to global enumeration without per-step ownership).

**Parent-superset rule for `integration-only`.** When step N is `integration-only (covered by Step M)`, step N's `Covers:` line lists the contract scenarios/invariants step N delegates to step M's test. Step M's `Covers:` line MUST be a SUPERSET of every integration-only step that names step M as parent — that is, M's `Covers:` line must include every scenario/invariant title that appears on any child step's `Covers:` line, using identical canonical titles (no paraphrasing). The `/plan-review` pre-launch gate and `/implement-plan` pre-dispatch validation both enforce this. Reviewers also check it. Rationale: the conformance audit uses M's tests as evidence for N's scenarios; if M's tests don't actually assert N's scenarios (because the planner forgot to add them to M's Covers and the tests didn't cover them), the audit would emit a misleading `done` from a substring coincidence. The superset rule prevents this.

### Rendered examples of each strategy

The following examples are illustrative. If anything in any example conflicts with the spec text above, the spec text wins.

**`build-then-test` example:**

````markdown
### Step 3: Add GET /api/tags endpoint — strategy: build-then-test
**Covers:** "User can fetch all tags", "Empty tag list returns 200 with empty array"

3.1 IMPLEMENT — Following the pattern in `src/routes/api/categories.ts`:
- Create `src/routes/api/tags.ts`
- Add GET handler querying tags table via Drizzle
- Register route in `src/routes/index.ts`

3.2 TESTS — Write `test/routes/api/tags.spec.ts`:
- Test: "User can fetch all tags" (Covers line entry)
- Test: "Empty tag list returns 200 with empty array" (Covers line entry)
- Test: response shape matches `tagSchema`
- For each test: verify it would FAIL if the implementation body were deleted (non-tautology assertion check).

3.3 RUN — Verify all tests pass.

3.4 REFACTOR — (if needed)
````

**`red-first` example:**

````markdown
### Step 4: Implement composite-FK invariant on team_membership — strategy: red-first
**Covers:** "Composite FK preserves cross-team membership cleanup", **No orphaned membership rows**

4.1 RED — Write `test/migrations/team-membership-fk.spec.ts`:
- Test: "Composite FK preserves cross-team membership cleanup" (Covers line entry)
- Test: "**No orphaned membership rows**" (Covers line entry, invariant)

4.2 RUN — Verify tests fail (FK constraint not yet present).

4.3 GREEN — Add migration with composite FK.

4.4 RUN — Verify tests pass.

4.5 REFACTOR — (if needed)
````

**`property-based` example:**

````markdown
### Step 5: Implement URL filter-state round-trip — strategy: property-based
**Covers:** **Round-trip identity**, **URL-safe encoding**, "Empty filter state round-trips losslessly"

5.1 INVARIANTS — Reference the contract's Invariants:
- **Round-trip identity** (from contract): `deepEqual(parseFilters(serializeFilters(s)), s)` for all valid `s`.
- **URL-safe encoding** (from contract): output contains only URL-safe characters.

5.2 PROPERTY TESTS — `test/url/filter-state.property.spec.ts` using `fast-check`:
- Property: "Round-trip identity over arbitrary `FilterState`" (substring match on invariant title)
- Property: "URL-safe encoding output matches regex" (substring match)

5.3 EXAMPLE TESTS — `test/url/filter-state.spec.ts`:
- Test: "Empty filter state round-trips losslessly" (Covers line entry)
- Test: known fixture matches expected encoding

5.4 RUN — Verify properties and examples fail.

5.5 GREEN — Implement `serializeFilters` and `parseFilters`.

5.6 RUN — Verify all tests pass.

5.7 REFACTOR — (if needed)
````

**`integration-only` example** (note: the integration-only step comes EARLIER in execution order than its parent; the parent's test is written later and exercises this step's wiring):

````markdown
### Step 1: Add Drizzle schema for `tags` table — strategy: integration-only (covered by Step 3)
**Covers:** "User can fetch all tags", "Empty tag list returns 200 with empty array"

1.1 IMPLEMENT — In `src/db/schema/tags.ts`, declare the `tags` table with columns per the migration plan. Add the new schema to `src/db/schema/index.ts` exports.

1.2 RUN — Run the project's existing test suite to confirm no regressions in already-shipped tests (the schema declaration shouldn't break anything that previously passed). Do NOT attempt to run Step 3's tests yet — Step 3 hasn't executed; its tests don't exist in the diff yet. The end-of-plan conformance audit will verify Step 3's test passes and covers the scenarios listed on this step's `Covers:` line.
````

### Legacy example (pre-Stage-2 / opt-out)

For plans without strategy labels (the historical default), every step follows the `red-first` shape:

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

### Back-compat for legacy plans

Plans authored before Stage 2 don't have `test_strategy` labels on any step. Such plans remain valid; the workflow treats every step as `red-first`, the conformance audit falls back to its existing global scenario-enumeration rules (no per-step ownership), and no `Covers:` lines are required.

## Acceptance Criteria (Optional)

When a plan is derived from specification tests (produced by `/bdd-spec`), include this section after the Review depth section and *before* the Behavioral Contract section. The full ordering is: Goal → Motivation & Context → Review depth → Acceptance Criteria → Behavioral Contract → Implementation Approach → Implementation Steps.

```markdown
## Acceptance Criteria
- path/to/spec-file.spec.ts (all scenarios must pass)
```

List each spec file that the implementation must satisfy. These files are human-owned and read-only — agents must not modify them.

When `Acceptance Criteria` is present, the plan's `Behavioral Contract` section typically uses the **pointer form** (a single italicized line referencing the spec file) or the **pointer-plus-supplemental form** (pointer line plus a `### Supplemental scenarios` block for additional scope passed alongside the spec). See item 4 (Behavioral Contract) above for the full spec of these forms.

When acceptance criteria exist, implementation steps that satisfy spec scenarios should use the existing spec test as the RED phase:

```
Step 2: Implement login endpoint (satisfies spec: user-login.spec.ts scenarios 1-3)

2.1 RED - Run existing spec test, confirm it fails (endpoint doesn't exist yet)

2.2 GREEN - Implement:
- Create src/routes/auth/login.ts
- Add POST handler for /auth/login
- Wire up to auth service

2.3 RUN - Verify spec test passes

2.4 REFACTOR - (if needed)
```

Additional tests (integration, unit) are still written per normal TDD for edge cases and implementation details not covered by the spec.

## Detail Level

Plans should be detailed enough that someone unfamiliar with the conversation could implement them. Include specific file paths, function names, test descriptions, and implementation details.
