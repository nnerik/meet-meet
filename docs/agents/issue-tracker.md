# Issue tracker: GitHub

Issues and specs live in this repo's GitHub Issues. Use the `gh` CLI;
infer the repository from the Git remote.

## Operations

- Publish: `gh issue create --title "..." --body-file <file>`
- Fetch: `gh issue view <number> --comments`
- List: `gh issue list --state open --json number,title,body,labels,comments`
- Comment: `gh issue comment <number> --body "..."`
- Label: `gh issue edit <number> --add-label "..." --remove-label "..."`
- Close: `gh issue close <number> --comment "..."`

## Pull requests as a triage surface

**PRs as a request surface: no.**

## Wayfinding operations

- Map: one issue labelled `wayfinder:map`, containing Notes,
  Decisions-so-far, and Fog.
- Children: link tickets as GitHub sub-issues. If unavailable, use a
  task list in the map and `Part of #<map>` in each child.
- Ticket labels: `wayfinder:<type>` where type is research, prototype,
  grilling, or task.
- Blocking: use GitHub native issue dependencies. If unavailable,
  record `Blocked by: #<number>` in the child.
- Frontier: first open, unassigned child in map order with no open blockers.
- Claim: assign the ticket to `@me` before other writes.
- Resolve: comment with the result, close the ticket, and add a short
  summary and link to the map's Decisions-so-far.
