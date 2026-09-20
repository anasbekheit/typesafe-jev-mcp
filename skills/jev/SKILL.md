---
name: jev
license: MIT
description: >
  Call the evaluate MCP tool (TypeSafe Jev) for typed judgments with
  probabilities, not prose. Use when classifying, routing, ranking, verifying
  claims, scoring severity, or screening text — wherever a yes/no, pick-one,
  or rubric decision would otherwise be eyeballed, regexed, or parsed from
  generated text.
---

# Jev via evaluate

Jev is a System One model: state plus typed questions in; noul, choice, or score
out. The MCP tool is `evaluate`. There is one tool. Do not invent classify,
check, or rank wrappers.

**Live docs are the source of truth.** Start at
<https://docs.typesafe.ai/llms.txt> and append `.md` to any page path. Do not
snapshot cookbooks or thresholds.

- Put every independent question over the same state in **one** call, including
  speculative ones. They run in parallel; ignore unused answers. A second call
  only when the first answer is needed to fetch evidence or build the next
  options.
- State is observed evidence, not your verdict. Prefer named JSON fields;
  reference nested paths in backticks.
- Question ids are not sent to Jev. Put the full meaning in `instructions`.
  One narrow judgment per question.
- **noul**: probability a condition holds (near 0.5 is uncertain, not medium).
  **choice**: one option from a map; include no-match when nothing may fit.
  **score**: ordered levels that describe concrete situations.
- Compose answers in this turn. Thresholds are yours; cookbook numbers are
  examples. Pin a versioned model (e.g. `jev-x.y.z`) after tuning.

If you are building TypeSafe into the user's application, use TypeSafe's
official skill (`typesafe-ai`) and the SDK, not this tool as a runtime
dependency.
