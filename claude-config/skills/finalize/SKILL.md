---
name: finalize
description: Generate an ADR from a completed plan implementation, clean up the plan file, and commit/push or create a PR.
argument-hint: "[path to plan file]"
user-invocable: true
allowed-tools: "Write Edit Read Glob Grep Bash Agent AskUserQuestion"
effort: high
---

# Finalize Implementation

You are finalizing a completed plan implementation by creating an Architecture Decision Record (ADR), cleaning up, and shipping the changes.

IMPORTANT: This workflow is designed to flow without unnecessary permission prompts. The tools listed in `allowed-tools` above are pre-authorized — use them without hesitation.

## Step 1: Locate the Plan

Find the plan file:
1. If `$ARGUMENTS` contains a path, use it
2. If not, check if a plan path is known from the current conversation context
3. If neither, look in `docs/plans/` for the most recent plan file
4. If multiple plan files exist, ask the user which one

Read the plan file in full.

## Step 2: Gather Implementation Context

Understand what was implemented by examining:
- The plan file (goal, reasoning, decisions, revision notes)
- The git diff or recent commits (`git log --oneline -20` and `git diff` or `git diff HEAD`)
- Any CLAUDE.md or AGENTS.md for project conventions

## Step 3: Generate ADR

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
Draw from the plan's goal description and any refinements from user Q&A.>

## Decision

<What was decided? What approach was chosen and why?
Draw from the plan's implementation steps and revision notes.
Focus on the reasoning — why this approach over alternatives.>

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

## Step 4: Remove Plan File

Delete the plan file from `docs/plans/`.

## Step 5: Ship

Determine the current git state:
- What branch are we on?
- Is it `main` or a feature branch?
- Are changes staged or unstaged?

Stage all changes (implementation + ADR + plan file deletion).

Present options based on git state:

### If on main:
1. **Commit and push to main**
2. **Create a new branch, commit, push, and create PR**

### If on a feature branch:
1. **Commit and push to current branch**
2. **Commit, push, and create PR** (if one doesn't already exist for this branch)

When committing, write a clear commit message summarizing what was implemented and why. Include the ADR reference.

When creating a PR:
- Use a concise title (under 70 characters)
- Include a summary of what was implemented
- Reference the ADR
- Note test coverage
- Use the standard PR format with `## Summary` and `## Test plan` sections
