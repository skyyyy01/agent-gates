# Project hooks — the three switches

Everything here is **opt-in per project**. Installing agent-gates changes
nothing until you create these files in your project's `.claude/hooks/`.

They are empty marker files; only their existence matters.

```bash
mkdir -p .claude/hooks
touch .claude/hooks/review-before-commit    # 1 — reminder
touch .claude/hooks/review-required         # 2 — hard gate
touch .claude/hooks/review-includes-tests   # 3 — widen scope

# Not optional — see below
printf '%s\n' '.claude/hooks/.review-ok' '.claude/hooks/.review-skill' >> .gitignore
```

## ⚠️ Before anything else: ignore the runtime artifacts

The gate writes two files next to those markers:

```
.claude/hooks/.review-ok      # content hashes of files you reviewed
.claude/hooks/.review-skill   # timestamp of the last review invocation
```

**Commit them and the gate starts lying.** `.review-ok` holds hashes of what
*you* reviewed. Push it, a teammate clones, the gate consults it — and the
hashes match, because the file contents match. It finds evidence, opens, and
lets through code nobody on that machine ever looked at. The failure is silent
and looks exactly like a passing gate.

```bash
printf '%s\n' '.claude/hooks/.review-ok' '.claude/hooks/.review-skill' >> .gitignore
```

Commit the three marker files below — they declare that this project gates its
commits, and a teammate cloning should inherit that. Never the two artifacts
above. Both regenerate locally on demand, so ignoring them costs nothing.

## 1. `review-before-commit` — reminder

Before a `git commit` that touches code, the agent gets one line: *you changed
N code files, review them first*. **It does not block.**

Start here. Live with it for a few days before turning on the hard gate.

## 2. `review-required` — hard gate

Now the commit is **denied** until the changed files have actually been through
a review. The pass condition is a content hash of every file this commit would
touch, matched against a snapshot written when the review ran.

Consequences worth understanding before you switch it on:

- **Content hash, not mtime.** `touch` and `checkout` change mtime, not content.
  Reviewing and then editing again invalidates the stamp — as it should.
- **Needs [open-code-review](https://github.com/alibaba/open-code-review).**
  Without that plugin there is no way to record a review, so every commit is
  denied. Escape hatch: `SKIP_REVIEW_GATE=1 git commit …` — and it must start
  the line, since the hook reads the command string, not the environment.
- **Scope is only what this commit would actually commit.** A bare commit uses
  the index; `-a` adds tracked changes; `-- <pathspec>` uses those paths. If the
  command cannot be parsed, it falls back to the whole tree — fail-closed.

## 3. `review-includes-tests` — widen scope

By default `tests/` is excluded, which is right for most projects.

Turn this on if your real defects live in the tests themselves. The case for it:
a test that runs a routine twice but never asserts on the resulting count is
green and worthless, and only a review of the *test* catches that.

## Additional exclusions

`review-exclude.txt` (see the `.example` next to this file) adds project-specific
paths. It is additive — the built-in exclusions stay.
