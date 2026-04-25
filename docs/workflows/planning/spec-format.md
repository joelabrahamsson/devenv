# Specification Test Format

## Purpose

Specification tests are human-owned BDD-style tests that capture the intended behavior of features from the user's perspective. They form a durable layer of tests that agents must not modify without explicit human approval.

## Key Principle

Specification tests are owned by humans. Agents must never modify them without explicit user approval. If an agent's implementation contradicts a spec test, the agent must stop and report the conflict to the user rather than modifying the test.

## File Location

Spec tests live in the project's test directory under a `specs/` or `acceptance/` subdirectory, organized by feature area. The exact path depends on the project's test conventions. Examples:

```
test/specs/authentication/user-login.spec.ts
tests/acceptance/checkout/cart-management.py
spec/acceptance/billing/subscription_renewal_spec.rb
```

The `/bdd-spec` skill detects the project's test directory structure and places specs accordingly. If no convention exists, use `test/specs/` as the default.

## File Header

Every specification test file MUST begin with a header comment identifying it as human-owned. Use the appropriate comment syntax for the language:

```javascript
// SPECIFICATION TEST — Human-owned, do not modify without user approval
// Created: 2026-04-23 via /bdd-spec
// Feature: User login
```

```python
# SPECIFICATION TEST — Human-owned, do not modify without user approval
# Created: 2026-04-23 via /bdd-spec
# Feature: User login
```

```ruby
# SPECIFICATION TEST — Human-owned, do not modify without user approval
# Created: 2026-04-23 via /bdd-spec
# Feature: User login
```

This header serves as a machine-readable marker that agents and review tools check before modifying the file.

## Scenario Structure

**One file per feature**, with multiple scenarios inside. Use Given/When/Then structure, either through a BDD framework (Cucumber, pytest-bdd, RSpec, etc.) or as descriptive test structure in the project's test framework.

### Granularity: One Scenario Per Behavior

Each scenario tests one distinct behavior or decision — not one per input variation.

**Good** — one scenario per behavior:
- "Successful login with valid credentials"
- "Login with invalid credentials" (covers wrong password AND non-existent email — same behavior: show error)
- "Login with locked account" (distinct behavior: different error, different remediation)

**Bad** — one scenario per input:
- "Login with wrong password"
- "Login with non-existent email"
- "Login with empty password"
- "Login with password under 8 characters"

The test for "invalid credentials" can use parameterized inputs internally, but it's one scenario because the system behavior is the same.

### Steps Describe Observable Behavior

Steps must describe what a user observes, not how the system is implemented.

**Good**: `When they submit the login form with valid credentials`
**Bad**: `When AuthService.login() is called with the user's credentials`

**Good**: `Then they see an error message saying "Invalid credentials"`
**Bad**: `Then the LoginController returns a 401 status code`

## Relationship to Other Tests

Specification tests sit at the top of a three-layer test strategy:

1. **Specification tests** (this format) — human-owned, capture intent, small in number, durable
2. **Integration tests** — agent-written and human-reviewed, cover component interactions
3. **Unit tests** — agent-written, disposable scaffolding, cover implementation details

Agents may freely create, modify, and delete tests in layers 2 and 3. Layer 1 requires explicit human approval for any modification.

## Relationship to Plans

When a plan references specification tests in its "Acceptance Criteria" section:
- The spec tests serve as pre-written failing tests for the RED phase of TDD
- Implementation steps that satisfy spec scenarios should run the existing spec test to confirm failure, then implement to make it pass
- Additional tests (integration, unit) are still written per normal TDD for edge cases and implementation details not covered by the spec
