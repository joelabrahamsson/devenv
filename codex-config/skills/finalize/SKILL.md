---
name: finalize
description: Assess whether the implementation warrants an ADR (when warranted, generate one drawing on the plan's Motivation & Context); draw on Motivation & Context to write a richer commit message either way; clean up the plan file; then commit/push or create a PR. Invoke with $finalize optionally followed by the path to the plan file.
---

# Finalize Implementation

You are finalizing a completed plan implementation: assess whether the work warrants an Architecture Decision Record (ADR), generate one if so, then clean up and ship the changes. The plan's Motivation & Context section drives both the worthiness assessment and the ADR content when one is produced.

## Step 1: Locate the Plan

Find the plan file:
1. If `$ARGUMENTS` contains a path, use it
2. If not, check if a plan path is known from the current conversation context
3. If neither, look in `docs/plans/` for the most recent plan file
4. If multiple plan files exist, ask the user which one

Read the plan file in full.

## Step 2: Gather Implementation Context

Understand what was implemented by examining:
- The plan file — pay specific attention to the **Motivation & Context** section (problem, constraints, alternatives considered, decision rationale). This is the primary source of "why"; the rest of the plan is "what" and "how". *If the plan predates this requirement and has no Motivation & Context section, fall back to the Goal section and Revision Notes for "why" content, and note the missing motivation in the Step 3 assessment.*
- The git diff or recent commits (`git log --oneline -20` and `git diff` or `git diff HEAD`) — used to verify what was actually shipped versus what the plan promised.
- Any AGENTS.md or CLAUDE.md for project conventions.

## Step 3: ADR Worthiness Decision

Not every implementation warrants an ADR. Decide based on the Motivation & Context section and the actual diff:

**An ADR is warranted when at least one is true:**
- A meaningful alternative was considered and rejected (the rationale for the rejection is non-obvious from the code).
- A non-trivial constraint shaped the design and isn't visible in the code (e.g., regulatory, performance, compatibility, security trade-off).
- A new architectural pattern, convention, or boundary was introduced.
- The adversarial reviews materially changed the approach (Revision Notes show real pivots, not just polish).

**An ADR is NOT warranted when:**
- Motivation & Context is replaced by `*Trivial change …*` or all four fields are `n/a`.
- The change is mechanical (typo fixes, dependency bumps, formatting) or obvious from the diff.
- There were no real alternatives — the chosen approach was the only sensible one.

**Tiebreaker (when in doubt):** lean toward warranted if the Motivation & Context section has non-empty, non-`n/a` content in **Alternatives considered** OR **Decision rationale**. Lean against if those two fields are both `n/a` or trivial. This anchors the call to the plan's actual reasoning rather than free-floating judgment.

Form your assessment, then ask the user directly to confirm: present *"My read: ADR [warranted | not warranted] because [one-sentence reason]. Proceed?"* and list three options the user can choose by number — `1) Yes — generate ADR`, `2) No — skip ADR`, `3) Override — let me explain`. Wait for the user's answer before proceeding. Do NOT auto-proceed.

If the user chooses **skip ADR**, jump to Step 5 (Remove Plan File). The commit message in Step 6 still draws on Motivation & Context to explain the *why*.

## Step 4: Generate ADR

Create an ADR file at `docs/adrs/NNNN-<title>.md` where:
- `NNNN` is the next sequential number (check existing files in `docs/adrs/`, start at `0001` if none exist)
- `<title>` is a kebab-case summary of the decision

Create the `docs/adrs/` directory if it doesn't exist.

Use this template:

```markdown
# NNNN. <Title>

Date: YYYY-MM-DD

## Status

Accepted

## Context

<What was the situation? What problem needed solving? What constraints existed?
Draw primarily from the plan's **Motivation & Context** section — specifically Problem and Constraints. The Goal section gives the surface task; Motivation & Context gives the underlying reasoning.>

## Decision

<What was decided? What approach was chosen and why?
Draw primarily from Motivation & Context's **Alternatives considered** and **Decision rationale**. Use Implementation Approach and Revision Notes only to ground the discussion in what was concretely built.>

## Consequences

### Positive
<What benefits does this decision bring?>

### Negative
<What trade-offs or downsides were accepted?>

### Risks
<What could go wrong? What should be watched?>
```

The ADR should capture the *reasoning* behind decisions, not just describe what was built. Focus on:
- Why this approach was chosen over alternatives
- What trade-offs were made and why
- What constraints influenced the design
- What the adversarial reviews caught and how it changed the approach (from the plan's revision notes)
- Anything non-obvious that a future developer (or AI assistant) should know

## Step 5: Remove Plan File

Delete the plan file from `docs/plans/`.

## Step 6: Ship

Determine the current git state:
- What branch are we on?
- Is it `main` or a feature branch?
- Are changes staged or unstaged?

Stage all changes: implementation + plan file deletion + ADR if one was generated in Step 4.

Present options based on git state:

### If on main:
1. **Commit and push to main**
2. **Create a new branch, commit, push, and create PR**

### If on a feature branch:
1. **Commit and push to current branch**
2. **Commit, push, and create PR** (if one doesn't already exist for this branch)

When committing, write a clear commit message summarizing what was implemented and why. If an ADR was generated, include the ADR reference. If no ADR was generated (skip path), draw on the plan's Motivation & Context section to write a richer commit message — surface the why, not just the what.

When creating a PR:
- Use a concise title (under 70 characters)
- Include a summary of what was implemented
- Reference the ADR if one was generated; otherwise, summarize the why in the PR body, drawing from the plan's Motivation & Context.
- Note test coverage
- Use the standard PR format with `## Summary` and `## Test plan` sections
