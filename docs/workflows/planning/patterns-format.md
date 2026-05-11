# `## Patterns` Section Format

## Purpose

The `## Patterns` section is a curated, project-local index that maps recurring problem-shapes to their canonical exemplar files. Its purpose is to short-circuit the most common form of subagent overhead during `/implement-plan`: re-greping the codebase for "the right pattern" every time a similar piece of work is implemented.

Without the section, each implementation subagent starts cold and runs 20–30 read/grep tool calls to figure out which existing file best represents the convention for the kind of work it's been asked to do. With the section in the project's agent doc (CLAUDE.md or AGENTS.md, auto-loaded by Claude Code for every subagent), a cold subagent reads the entry once and can begin work directly against the named exemplar.

The section is consumed by `/plan-review` (at plan-design time, to reference matching entries by name in generated plan steps), populated by `/finalize` (incrementally, when a feature implementation mirrors an existing file), and populated/validated by `/workflow-audit` (in batch, for adoption back-fill and periodic drift checks).

## Location

A single Markdown heading — `## Patterns` — in whichever agent doc the project already uses. Most projects have either `CLAUDE.md` or `AGENTS.md`; place the section there. If a project has both, write to the one the project's existing skills consult first (typically the one named in convention docs or referenced by `/plan-review` instructions). If neither convention is clear, ask the user. Do not impose a preference between CLAUDE.md and AGENTS.md — the section works in either.

The section is read into every Claude Code conversation in the project automatically, including subagents spawned by `/implement-plan`. No skill needs to load it explicitly — every consumer sees it as part of standard project context.

## Entry format

Each entry is 3–5 lines. Keep entries scannable: a developer reading the section should be able to identify the right exemplar in seconds, not minutes.

- **Shape** (required, one bolded line). A short noun-phrase describing what kind of work this entry applies to. The shape is the entry's **canonical identifier** — other tooling and prose refer to entries by their shape title. Examples: `New CRUD resource (API)`, `Optimistic CRUD hook`, `Tag-style chip component`, `Background job worker`.
- **Exemplar** (required, one line). The file path to the canonical example in the repo. Pick the cleanest representative — recent, well-named, free of deprecated code paths, minimal special-case logic.
- **What to mirror** (required, 1–2 lines). The specific elements of the exemplar to copy. Examples: "error envelope shape, pagination params, validation order"; "useState + useMutation pattern, optimistic update + rollback on error"; "ARIA roles, focus management on dismiss".
- **Anti-pattern** (optional, one line). Anything in the exemplar that should NOT be copied. Examples: "don't copy the deprecated `legacyFormat` adapter at the bottom"; "ignore the `// TODO remove after migration` block — that's transitional code".

## Canonical citation phrase

When `/plan-review` produces a plan that references a Patterns entry, and when `/finalize` detects a Patterns reference in plan prose, both use the **same literal phrase** to ensure the signal is reliable rather than heuristic:

```
per Patterns: "<shape title>"
```

Literal: the text `per Patterns:`, a single space, then the entry's shape title in **double quotes**. The shape title inside the quotes MUST match the entry's shape line verbatim (including capitalization, punctuation, and parenthetical disambiguators).

Example, as it would appear in a plan step:

```
Step 3: Add the GET /api/tags endpoint
- Mirror src/api/categories.ts per Patterns: "New CRUD resource (API)"
- Same error envelope, pagination params, validation order.
```

`/plan-review` produces this phrase when designing steps; `/finalize` searches the plan file for this phrase (and for plain `mirror <path>` references) when deciding whether to propose a new Patterns entry. Because the phrase is exact-match rather than fuzzy, both skills can rely on each other without ambiguity.

## Length target

5–15 entries per project. A scannable index, not an exhaustive catalogue.

- Fewer than 5: the section is probably too young to be useful; let it grow naturally via `/finalize` proposals as features ship.
- 5–15: the sweet spot. Each entry earns its place by being a real recurring shape with at least 3 representatives in the codebase.
- More than 15: the section is being asked to do too much. Consider splitting by domain (e.g., a sibling `## Patterns: API`, `## Patterns: UI` — though most projects shouldn't need this). When `/workflow-audit` or `/finalize` would push the section past 15 entries, both skills surface that fact to the user and offer merge-or-skip rather than blindly appending.

The length cap is a forcing function for curation. If a shape doesn't recur enough to deserve a slot in the top 15, it isn't yet canonical enough to belong here.

## Maintenance

The section is human-maintained, like `CLAUDE.md` itself. Three skills propose changes (the human decides):

- **`/finalize`** — incremental. At commit time, if the implementation mirrored an existing file (plan said `mirror <path>` or used the canonical citation phrase), `/finalize` proposes a new entry and adds it to the section in the same commit when the user accepts. This is the steady-state curation path.
- **`/workflow-audit`** — batch. On user invocation, scans the codebase for recurring shapes not yet in the section, proposes entries (capped at 5 per run, ranked by confidence), validates that existing entries cite real files, and writes accepted proposals. This is the adoption back-fill and periodic drift-check path.
- **`/plan-review`** — inline staleness fix. During plan design, if any cited entry's exemplar file no longer exists, `/plan-review` surfaces the staleness and offers an inline free-text fix (corrected path, `remove`, or `keep as-is`). This is the smallest amount of doc-maintenance that lives in `/plan-review`; broader hygiene stays with `/workflow-audit`.

Entries do not have versions or timestamps. If an entry drifts, fix or remove it. If a section needs reorganization, do it in a regular commit.

## Rendered example

A small, fully-formed section showing distinct shape categories:

```markdown
## Patterns

**New CRUD resource (API)**
Exemplar: `src/api/categories.ts`
Mirror: error envelope shape (`{ error: { code, message } }`), pagination params (`limit`/`offset`/`total`), Zod-validation-before-handler order.
Anti-pattern: don't copy the deprecated `legacyFormat` adapter at the bottom — it's transitional.

**Optimistic CRUD hook**
Exemplar: `src/hooks/useFacets.ts`
Mirror: useState + useMutation pattern, optimistic update on dispatch, rollback on error, `invalidateQueries` on success.

**Tag-style chip component**
Exemplar: `src/components/TagChip.tsx`
Mirror: variant prop typing, dismissible affordance, ARIA roles, focus management on dismiss.

**Background job worker**
Exemplar: `src/workers/email-digest.ts`
Mirror: BullMQ queue registration, idempotency key derivation, structured-logging context fields, retry policy.
```

When `/plan-review` references one of these entries in a plan step, the citation reads:

```
- Mirror src/api/categories.ts per Patterns: "New CRUD resource (API)"
```

This phrase is what `/finalize` looks for when deciding to propose a new entry after commit, and what subagents implementing the step see in their context.
