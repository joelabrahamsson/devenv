---
name: workflow-audit
description: Audit a project for conformance with the planning workflow. Proposes back-fill for missing Patterns entries and BDD spec gaps; verifies existing Patterns entries cite real files. Read-only proposal phase; writes only user-accepted entries. Invoke with $workflow-audit.
---

# Workflow Audit

You are auditing a project for conformance with the planning workflow's expected artifacts. The skill produces a grouped report of candidate changes (Patterns entries to add, stale Patterns entries to fix, BDD spec gaps to fill) and writes only what the user explicitly accepts.

The skill is structured as **two phases**:

1. **Proposal phase (read-only).** Scan the project, validate existing artifacts, and produce a single grouped report. No file writes during this phase.
2. **Apply phase (writes only on user Accept).** For each proposal the user accepts, apply the change — append Patterns entries to the agent doc, surface stale entries for free-text correction. Rejected/skipped items are left untouched.

The proposal phase uses read-only operations only (`shell` with read-only commands such as `grep`, `find`, `ls`). The apply phase is the only place file writes occur, and only for items the user has explicitly accepted.

## Scope boundary

`$workflow-audit` covers **project-level planning-workflow artifacts only**. It must NEVER absorb:

- **Code quality** — that's `$review` (or equivalent review skill).
- **Security review** — that's `$security-review` (or equivalent security skill).
- **PR-level concerns** — that's a review skill run on a PR.
- **Implementation conformance to a plan** — that's the conformance audit inside `$implement-plan`.
- **Feature-specific planning** — that's `$plan-review`.

If a candidate concern is per-feature, per-PR, or per-commit, it belongs in a different skill. Future stages added here must remain at the project-workflow-artifact level (e.g., new sections in AGENTS.md, plan-format additions, workflow-doc consistency checks). The scope boundary is what prevents this skill from becoming a kitchen sink.

## Out of scope for v1

- Persistent ignore list for re-rejection (re-proposals on rerun are expected — re-rejection is cheap).
- Auto-launching `$bdd-spec` (audit proposes; user invokes).
- Auto-fixing stale Patterns entries beyond surfacing them to the user for free-text correction.
- Scoping arguments (`--patterns-only` etc.) — always run all stages.
- Splitting per-artifact into separate skills — the meta-skill factoring is deliberate; see Scope boundary.

## Pre-amble

Read `~/workflows/planning/patterns-format.md` and `~/workflows/planning/spec-format.md` so you understand the formats this skill operates on. Then read the project's `AGENTS.md` and/or `CLAUDE.md` to understand project conventions (test directory locations, language, naming). Read AGENTS.md first if both exist.

## Stage A: Patterns audit (read-only proposal)

### A.1 Parse the existing `## Patterns` section

Locate the project's primary agent doc:

- If only `AGENTS.md` exists, use it.
- If only `CLAUDE.md` exists, use it.
- If both exist, use whichever already contains a `## Patterns` section.
- If both exist and neither contains a `## Patterns` section, ask the user which doc to use as the destination for any accepted proposals via a numbered text prompt:

```
Which agent doc should receive accepted Patterns proposals?

1) AGENTS.md
2) CLAUDE.md

Reply with the number of your choice.
```

Wait for the user's reply before continuing.

Read the chosen agent doc and parse the `## Patterns` section, if present. Capture each entry's shape title and exemplar path. If the section is absent, note that — Stage A still proposes new entries; on accept, the section is created.

### A.2 Verify existing entries

For each existing entry, verify the cited exemplar file resolves. Use `shell` (e.g., `ls <path>` or a targeted read attempt) to confirm the file is present at the path stated in the entry. Mark any entry whose exemplar is missing as **stale**.

### A.3 Detect recurring shapes

Scan the codebase for shapes that recur. Heuristic for v1: **at least 3 files** with substantial structural similarity (same top-level exports, similar file layout, similar import surface) **and** the same naming convention (e.g., `src/api/<resource>.ts` files; `src/components/<name>Chip.tsx` files; `hooks/use<Name>.ts` files). Use `shell` with `find` or `grep` to enumerate candidate files; read enough of each to verify structural similarity, not just naming.

**Exclusions — do not count these toward the threshold:**

- Generated files: anything matching `*.generated.*`, files under `dist/`, `build/`, `.next/`, `out/`, `node_modules/`, etc.
- Vendored / third-party: `vendor/`, `third_party/`, anything pulled from a package manager.
- Test fixtures: `fixtures/`, `__fixtures__/`, files under `tests/data/`.
- Test files themselves: `*.test.*`, `*.spec.*` (these are tests of the pattern, not instances of it).
- Migrations: `migrations/`, `db/migrations/`.
- Type-only declaration files: `*.d.ts`.

Only count files that represent a **reusable implementation shape** — the kind of file a developer would copy as a starting point for the next instance.

**Conservative override.** Even at 3+ files, propose only when the user would plausibly say "yes, this is canonical here." Indicators of a real recurring shape: stable naming convention, reusable implementation structure, clear future-use case. If two of three representatives are near-duplicates and the third is a clear outlier, skip the proposal. False positives train users to reject proposals reflexively, which then leads to real proposals being missed; bias toward under-proposing.

### A.4 Duplicate / overlap check

For each detected recurring shape that does NOT yet have an entry in `## Patterns`:

- Compare against existing entries by **shape title** (case-insensitive substring match) and by **exemplar path** (exact match). If either matches, do NOT propose as a new entry — instead surface as a potential update/merge with the existing entry (Stage C presents this as an "update existing entry?" item rather than "add new entry?").
- If accepting the proposal would push the total entry count past 15 (per `~/workflows/planning/patterns-format.md` § Length target), surface that fact in the proposal so the user can decide to skip, merge with a related entry, or accept and grow past the soft cap. Do not silently grow the section past 15.

### A.5 Draft proposed entries

For each non-duplicate, non-overlapping recurring shape, draft an entry per `~/workflows/planning/patterns-format.md` § Entry format:

- **Shape** — short noun-phrase identifying what kind of work this applies to.
- **Exemplar** — the cleanest representative file (most recent, fewest deprecated comments, simplest dependencies).
- **What to mirror** — 1–2 lines naming specific elements (error envelope shape, validation order, state management pattern, etc.).
- **Anti-pattern** (optional) — only include if the exemplar has clearly-deprecated code that should not be copied.

Draft each entry as it would appear in the agent doc; the user will see the rendered text before deciding.

## Stage B: BDD spec gap audit (read-only proposal)

### B.1 Identify the project's spec infrastructure

Read `~/workflows/planning/spec-format.md` to understand the spec file identification convention (the `SPECIFICATION TEST` header comment marker, the directory placement conventions). Then scan the project's test directory roots for files containing the marker:

```bash
# Run from the project root. Adapt --include filters to the project's languages.
grep -r --include='*.ts' --include='*.tsx' --include='*.js' --include='*.py' --include='*.rb' \
  -l 'SPECIFICATION TEST' test tests spec 2>/dev/null
```

Use `shell` to run this command. If no spec files are found anywhere in the project's test directory tree, note that the project has no spec infrastructure and **skip the rest of Stage B with that explanation** — do not propose creating spec infrastructure here (that's a separate adoption decision).

If spec files exist, infer the project's spec directory from their location (e.g., `test/specs/`, `tests/acceptance/`, `spec/acceptance/`). This becomes the search root for B.3 below.

### B.2 Identify candidate "major feature" areas

Scan the project for directories whose contents look user-facing. Prefer:

- Route handlers (`src/routes/`, `pages/`, `app/`, `api/`).
- Domain modules with mixed implementation + UI (`src/billing/`, `src/checkout/`, `src/auth/`).
- Controllers and request handlers (anything that names HTTP verbs or REST resources).

**Exclude:**

- Build config (`vite.config.*`, `webpack.config.*`, `tsconfig.json`, package manifests).
- Adapters and generated clients (`*-client.ts`, `*-sdk.ts`, anything explicitly marked as auto-generated).
- Migrations-only folders (`migrations/`, `db/migrations/`).
- Pure utility libraries (`lib/`, `utils/`, `helpers/`) UNLESS they expose user-facing behavior (e.g., a `lib/auth.ts` that implements user-visible login behavior counts; a `lib/array.ts` of array helpers does not).
- Infrastructure / DI wiring directories.

### B.3 Determine spec coverage by cross-reference

For each candidate feature directory from B.2, determine whether any spec file under the spec directory (from B.1) references modules in this feature area. Cross-reference by:

- **Import-path match.** Does any spec file `import`/`require`/`from` a module path that lives under the candidate feature directory?
- **Scenario-subject match.** Do any spec scenarios mention the feature's domain language (resource names, controller names)?

Treat the entire spec directory as the search space, NOT just a same-named subdirectory. A spec file at `test/specs/checkout/subscription-flow.spec.ts` that imports from `src/billing/` counts as spec coverage for `src/billing/` — the spec directory's internal organization may not mirror source layout.

A feature is flagged as a **gap** only when *no* spec file anywhere in the spec dir references its modules.

### B.4 Apply the substantial-feature heuristic

A flagged gap qualifies as a proposal only if:

- The feature directory contains **≥3 files of user-facing implementation code** (per the inclusion rules in B.2).
- No cross-referencing spec was found in B.3.

**The spec layer is layer 1 (human-owned), per `~/workflows/planning/spec-format.md`.** Existing unit or integration tests do NOT satisfy the spec layer. Therefore: absence of any spec file referencing the feature **IS** a gap, regardless of whether unit or integration tests exist for that feature. Do not treat unit-test coverage as a substitute for the human-owned spec layer.

### B.5 Format gap proposals

For each flagged gap, draft a one-line proposal:

> Feature `<directory>` has no BDD spec coverage. Suggest running `$bdd-spec <feature-name>` to address.

Stage B does NOT auto-launch `$bdd-spec`. The user invokes it themselves after the audit completes.

## Stage C: Per-stage cap and grouped report

### C.1 Per-stage cap

Each of the following proposal categories proposes **at most 5 items per audit run**:

- A.5 — New Patterns proposals.
- A.4 (merge surface) — Update-existing-entry proposals.
- A.2 — Stale Patterns entries.
- B.5 — BDD spec gaps.

Rank candidates by confidence:

- **A.5 / A.4:** rank by number of representatives (more = higher confidence), then by structural cleanness of the exemplar.
- **A.2:** rank by recency of the stale exemplar's removal (more recent = more likely the user remembers and can fix quickly). If recency is unknown, alphabetize.
- **B.5:** rank by feature size (more files = higher signal) and centrality (a top-level `src/routes/` directory ranks higher than a nested `src/internal/admin/`).

If more candidates exist than the cap, surface the count in the final summary ("12 total candidates; showing top 5 by confidence — rerun the audit to see the next batch after curating the first").

### C.2 Grouped report

Produce the report grouped by category:

1. **New Patterns entries to add** (A.5).
2. **Existing Patterns entries to update / merge** (A.4 merge surface).
3. **Stale Patterns entries to fix** (A.2).
4. **BDD spec gaps to address** (B.5).

**Default interaction model — one item at a time.** For each item, render it as a numbered text prompt and wait for the user's single-digit reply before moving to the next item:

```
[Category: New Patterns entry] Shape: "<shape title>"
Exemplar: <path>
What to mirror: <brief description>

1) Accept
2) Reject
3) Skip (decide later)

Reply with a single digit.
```

Wait for the user's reply. Move to the next item only after receiving a valid response. On an invalid reply (anything other than 1, 2, or 3), display "Please reply with 1, 2, or 3." and re-prompt for this item.

**Opt-in batch mode for categories with 3+ candidates.** At the start of a category that has 3 or more items, offer the batch option:

```
There are N candidates in this category. Type `batch` to respond to all at once
with a comma-separated list, or press Enter to go one at a time.
```

If the user types `batch`, render all items in the category numbered (1 through N), then present this prompt:

```
Reply with your decisions in this exact format:
  1=accept, 2=reject, 3=skip, 4=accept, ...
(digit=accept|reject|skip for each item, comma-separated, in order)
```

Parse the reply by splitting on `,`, trimming each token, and expecting `<digit>=<accept|reject|skip>` per token. On malformed input (missing digits, wrong separators, unknown tags, digit out of range), display a clear error message identifying which token failed and re-prompt for the full batch reply. Do not partially apply a malformed batch.

If the user presses Enter (empty reply), proceed one at a time for that category.

## Apply phase

Run only on user Accept for each item. This is the only phase where file writes occur.

### Accepted: New Patterns entry (A.5)

Append the entry to `## Patterns` in the chosen agent doc. If the section does not yet exist, create it at the end of the doc and append the entry as the first item.

### Accepted: Update/merge existing entry (A.4 merge surface)

Present the existing entry text and the proposed update text to the user via a follow-up numbered text prompt:

```
Existing entry:
<existing entry text>

Proposed update:
<proposed entry text>

How would you like to proceed?

1) Replace verbatim with the proposed text (recommended when the proposal is strictly better)
2) Open for free-text edit — type the merged entry text directly in your reply
3) Skip (keep existing)

Reply with 1, 3, or type your revised entry text directly (option 2).
```

If the user replies with `2` or types entry text directly, apply it verbatim to the agent doc. If `1`, apply the proposed text. If `3`, leave the existing entry untouched.

### Accepted: Stale Patterns entry (A.2)

Present the stale entry text to the user via a follow-up numbered text prompt:

```
Stale entry (exemplar file not found):
<stale entry text>

How would you like to resolve this? Type your response directly:

- A file path → updates the entry's Exemplar line to that path.
- `remove` → deletes the entry from `## Patterns`.
- `keep as-is` → leaves the entry untouched (accept the staleness as historical guidance).
```

Apply the response verbatim:
- A file path → edit the entry's Exemplar line to use the new path.
- The literal text `remove` → delete the entry from the section.
- The literal text `keep as-is` → leave the entry untouched.

Out of scope for v1: agent-side codebase search to auto-resolve the new path.

### Accepted: BDD spec gap (B.5)

Leave a one-line note in the final summary: `Run $bdd-spec <feature-name> to address the gap in <feature-directory>.` No file write — `$bdd-spec` is a separate user-driven flow.

## Stage D: Summary

Print a final summary covering:

- **Counts per category** — proposed, accepted, rejected, skipped.
- **Files written** — explicit list of file paths modified.
- **Outstanding items** — BDD spec gaps the user accepted (which require a follow-up `$bdd-spec` run); cap overflows (categories with more candidates than the per-stage cap); any items the user skipped that are worth remembering for next run.
- **Suggested follow-up** — concrete next actions, e.g., "run `$bdd-spec auth` for the auth spec gap"; "consider re-running this audit after the next feature ships to back-fill the cap-overflow items".

The summary should be scannable. Don't repeat the full proposal text — reference items by their category and shape title / feature name.

## Recovery and error handling

- **Missing agent doc:** if neither `AGENTS.md` nor `CLAUDE.md` exists, ask the user via a numbered text prompt whether to create one (with just the `## Patterns` section) on accept, or to abort the audit:

  ```
  No AGENTS.md or CLAUDE.md found in this project.

  1) Create AGENTS.md with an empty Patterns section and continue
  2) Abort the audit

  Reply with a single digit.
  ```

  Do not silently create files. If the user chooses 1, create the file with a `## Patterns` heading and no entries, then proceed with the audit.

- **Malformed `## Patterns` section:** if the section exists but contains entries that don't match the format spec (missing exemplar, missing shape line, etc.), report them in Stage A as stale-or-malformed and offer the same free-text correction path as for stale entries.

- **No project test infrastructure:** Stage B explicitly skips with a one-line note if no spec files are found anywhere. Do not propose setting up spec infrastructure from this skill.
