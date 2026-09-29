---
name: visual-work
description: >-
  Agent-only contract for visual work intake and execution.
  Load before scaffolding any task whose output has a designed visual surface, and follow the generated contract before making design decisions or completing the editor pass.
user-invocable: false
metadata:
  internal: true
---

# Visual work

Load this skill before scaffolding any task whose output has a designed visual surface, including a deck, Scout screen, website, or email.
Visual work deliberately spends more time on intent, interaction quality, and artistry.

## Intake

Scaffold visual ship or scout work with `bin/fm-brief.sh --visual --surface <surface>` in addition to its ordinary mode or scout arguments.
The supported surface and point-of-view document pairs are:

| Surface | Point-of-view and quality-bar document |
| --- | --- |
| `decks` | `<project>/docs/design/point-of-view.md` |
| `scout` | `<project>/docs/design-system/point-of-view.md` |
| `website` | `<project>/sites/tomasmeulenberg/design-concepts/POINT-OF-VIEW.md` |
| `email` | `$FM_HOME/data/standards/mindshake-outbound-point-of-view.md` |

`<project>` is the target project directory passed as the scaffold's second argument, and email lives under the firstmate home.
When the bound document does not exist, the scaffold warns with the expected path and the brief tells the worker to create it from the ratified point-of-view report before designing.

Do not substitute `--design` for `--visual`.
The former adds generic front-end defaults, while the latter binds the surface point of view and the editor pass.
`bin/fm-brief.sh` and its help own exact flag mechanics, refusals, and rendered wording.

## Execution standard

The generated `# Visual work contract` is the worker-facing execution contract.
Before any design decision, the worker reads the selected surface's point-of-view document and carries that point of view rather than merely matching an existing style.
Apply this direction: carry the point of view; one deliberate better-than-the-pattern idea is welcome, named as such.

The worker uses the project's existing design-system templates, interaction patterns, and flows, not only its colours and fonts.
The worker checks `BRAND.md`, `docs/design-system/`, `design-system/`, and the templates, components, and user-flow definitions nearest the affected surface.
The worker does not invent a component when the system already provides one.

Copy must be professional, warm, human and direct, in the captain's own voice, and never AI-sounding.
Where the task writes copy, the worker uses the copywriting skill.

Before the done line, the worker performs an editor pass by walking the finished surface end to end as its user in a real browser.
The worker records that walk in the PR body for PR work, the report for scout work, or the ready-branch summary for local-only work, and names the one surprising detail added and why.
The reviewer applies this rejection rule: "satisfies every rule and still dead is a reject".
