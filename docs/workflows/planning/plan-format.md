# Plan File Format

## File Location and Naming

Plans are written to `docs/plans/YYYY-MM-DD-short-description.md` — date plus a brief kebab-case summary (e.g., `2026-04-05-add-team-squad-view.md`). Create the `docs/plans/` directory if it doesn't exist.

## Required Sections

1. **Goal** — the original task description, including any refinements from user Q&A.

2. **Implementation Approach** — must include all four items below (a–d). The planner is responsible for filling in the project-specific text for items b and c, and for identifying any grouping candidates in item d.

   **a. TDD reminder** (include this exact text):
   > This plan follows a strict TDD workflow. For each step: write failing tests first, verify they fail, implement the minimum code to pass, verify they pass, then refactor if needed. Never skip ahead to implementation without a failing test.

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

3. **Implementation Steps** — each step that involves code changes MUST follow the TDD structure below.

## TDD Step Structure

Every implementation step MUST be structured as a red-green-refactor cycle:

1. **Red**: Write the test(s) first. Describe what test file, test name, and assertions to create.
2. **Run**: Run the tests and verify they fail for the expected reason.
3. **Green**: Write the minimum implementation code to make the tests pass.
4. **Run**: Run the tests and verify they pass.
5. **Refactor** (if needed): Clean up the implementation while keeping tests green.

### Example

Instead of:
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

## Acceptance Criteria (Optional)

When a plan is derived from specification tests (produced by `/bdd-spec`), include this section after the Goal:

```markdown
## Acceptance Criteria
- path/to/spec-file.spec.ts (all scenarios must pass)
```

List each spec file that the implementation must satisfy. These files are human-owned and read-only — agents must not modify them.

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
