# Project Brain

Persistent project memory that survives across agent sessions.

## Why

A project runs for months; a single agent session does not. Without a written
memory, every new session re-reads the code from zero and silently loses the
history of *why* things are the way they are — which is the expensive half.

## Layout

| Directory | Holds | Written |
|---|---|---|
| `state/` | Current snapshot — small enough to read in seconds | Every session |
| `journal/` | Timeline, one file per day (append within the day) | Every session |
| `decisions/` | ADR-style records of decisions that were hard to make | On decisions |
| `gotchas/` | Traps already stepped in, and what actually fixed them | On stepping in one |
| `contracts/` | Signatures of interfaces that must not drift | When an interface settles |

## Protocol

**Session start** — read these and you are caught up:
`state/current.md` → `state/phase.md` → `state/blockers.md` → newest journal entry.

**Session end** — before committing:
1. Update `state/current.md` (newest on top, keep it short)
2. Append to today's `journal/YYYY-MM-DD.md`
3. New decision → `decisions/NNNN-slug.md`
4. New trap → `gotchas/slug.md`
5. Changed a key interface → update `contracts/`

## The one rule that makes this work

**Write cost differs by carrier, so the bar differs by carrier.**

| Tier | Carrier | Read cost | Bar to write here |
|---|---|---|---|
| 1 | `journal/` `gotchas/` `decisions/` | Grepped on demand ≈ 0 | **None. Write anything.** This is the floor that keeps things from being lost |
| 2 | Long-lived notes outside the repo | Paid once when read | "A future session will need this and the repo does not already say it" |
| 3 | `CLAUDE.md`, `state/current.md` | **Every session pays** | Any one of: happened ≥2 times independently · single occurrence but irreversible · the only source of truth for current config |

The bar is about *where* something goes, never about *whether* to write it down.
Tier 1 has no bar precisely so that nothing gets dropped for being too small.

**Every tier-3 rule carries its provenance** (a date, a commit, "user decided on
X"). A rule without provenance cannot be judged stale, and cannot be ranked when
two rules conflict.

## Budget

`state/current.md` grows without bound if nothing pushes back. Give it a size
budget in `gates.toml` and archive the oldest entries when it trips — archiving
is *lowering resolution*, not cutting the link: leave a one-line summary and a
pointer to the archive file.

⚠️ Budget by **size**, not entry count. Entry count is a proxy and proxies get
gamed: a file can sit at exactly the allowed number of entries and still be
three times over budget, because flattened rows and mixed heading formats do not
match whatever pattern the counter uses.
