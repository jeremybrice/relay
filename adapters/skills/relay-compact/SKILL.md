---
name: relay-compact
description: Consolidate Relay knowledge — sweep empties, archive stale, merge duplicates (human-gated)
---

Run the Relay knowledge consolidation cycle. Mechanical fixes first, then a
human-gated semantic pass. Use `"$PWD/.relay/relay.sh"` as `R` and
`--dir "$PWD/.session-log"` as `D` below.

1. Mechanical pass. Show each dry run to the user, then apply:

   ```bash
   R knowledge compact D
   R knowledge compact --yes D
   R knowledge prune D
   R knowledge prune --yes D
   ```

2. Read the full surviving corpus: `R knowledge export D`.
3. Build a consolidation plan:
   - Merge groups: duplicate/overlapping entries → one entry per group. Keep
     the most descriptive existing slug, rewrite the body to capture the union,
     name the absorbed ids.
   - Rewrites: bodies stale against the current codebase → corrected body.
     VERIFY against the repo before declaring anything stale — never from
     memory alone.
   - Graduations: lessons with sessions >= 3 that are durable repo rules →
     propose `knowledge graduate <id>`.
   - Deletions: entries that no longer reflect the codebase with no merge
     target → propose `knowledge supersede <id>`.
4. Present the plan to the user. Apply NOTHING until approved. Graduations
   additionally need per-item user OK.
5. Apply only through existing primitives:
   - merge/rewrite: `R knowledge add --fact|--lesson --id <kept-slug> '<rewritten body>' D`
   - absorbed/deleted ids: `R knowledge supersede <id> D`
   - approved graduations: `R knowledge graduate <id> D`
6. Report final counts: `R knowledge list D`. The next session picks up the
   compacted store when it reads `.session-log/`. No snapshot refresh.

Invariants:
- Never invent knowledge — merges only reword existing bodies.
- Never merge across kinds (facts = durable truths; lessons = behavioral patterns).
- Prefer reinforcing the oldest entry in a merge group (keeps first_seen).
