# Plan File Format

## File Location and Naming

Plans are written to `docs/plans/YYYY-MM-DD-short-description.md` — date plus a brief kebab-case summary (e.g., `2026-04-05-add-team-squad-view.md`). Create the `docs/plans/` directory if it doesn't exist.

## Required Sections

1. **Goal** — the original task description, including any refinements from user Q&A.

2. **Implementation Approach** — include this exact reminder:
   > This plan follows a strict TDD workflow. For each step: write failing tests first, verify they fail, implement the minimum code to pass, verify they pass, then refactor if needed. Never skip ahead to implementation without a failing test.

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
