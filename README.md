# agent-gates

**You wrote the rule in CLAUDE.md. It didn't stick. Make it mechanical instead.**

Hook-based gates for Claude Code: the commit is denied until the code has
actually been reviewed, and the files your agent reads every session stay under
a size budget.

[![License: MIT](https://img.shields.io/badge/license-MIT-yellow)](LICENSE)
[![Claude Code](https://img.shields.io/badge/requires-Claude%20Code-8A63D2)](https://claude.com/claude-code)
[![Tests](https://img.shields.io/badge/tests-22%20scenarios%20%2B%204%20mutations-green)](tests/)

**English** | [中文](https://github.com/skyyyy01/agent-gates/blob/main/docs/README_ZH.md)

---

## The problem this is for

You wrote *"never truncate the output of that command"* in `CLAUDE.md`.

You wrote it in the journal. You wrote it into memory. You turned it into a
mechanical step.

**You still hit it four times the same day.**

Not because the rule was unclear — it was already as clear as a rule gets. Every
form discipline can take had been used up. What was left was to stop asking, and
start denying.

That's the whole idea. Reminders degrade. Gates don't.

The full reasoning, including the three silent failures that happened *inside*
the gate while building it: [why mechanism, not discipline](docs/why-mechanism-not-discipline.md).

## Who this is for

Two conditions, both required:

- **You write code with an AI agent.** Without that, none of this exists.
- **You've already been bitten.** If "the rule is in CLAUDE.md and it still
  didn't happen" doesn't sound familiar, this will read as bureaucracy. If it
  does, you already know which rule you'd gate first.

> ⚠️ **Requires [Claude Code](https://claude.com/claude-code)** — this is built
> on its hook mechanism. Cursor, Copilot, Windsurf and friends are not
> supported. The hard gate additionally needs
> [open-code-review](https://github.com/alibaba/open-code-review); the reminder
> mode does not.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/skyyyy01/agent-gates/main/install.sh | bash
```

Installs two hooks into `~/.claude/hooks/` and registers three events in
`~/.claude/settings.json` (idempotent, backs up first).

**Nothing happens yet.** Gates are off until a project opts in — a tool that
starts blocking on install gets uninstalled.

```bash
cd your-project
mkdir -p .claude/hooks
touch .claude/hooks/review-before-commit    # 1 — remind
touch .claude/hooks/review-required         # 2 — deny
touch .claude/hooks/review-includes-tests   # 3 — widen scope
```

Three independent switches. Start with `1` alone for a few days.

## The gates

### 1. Review reminder

Before a `git commit` that touches code, the agent gets one line: *you changed
N code files, review them first.* Doesn't block.

### 2. Review gate

The commit is **denied** until the changed files have been through a review.

The pass condition is a **content hash** of every file this commit would touch,
matched against a snapshot written when the review ran:

- **Hash, not mtime** — `touch` and `checkout` change mtime, not content.
- **Review then edit again → denied again.** Correct, and occasionally annoying.
- **Scope is what this commit would actually commit** — bare commit uses the
  index, `-a` adds tracked changes, `-- <pathspec>` uses those paths. Unparseable
  command falls back to the whole tree: **fail-closed**.
- Escape hatch: `SKIP_REVIEW_GATE=1 git commit …`, and it must start the line
  (the hook reads the command string, not the environment).

### 3. Truncation gate

`… | head` after the review command is denied outright.

This one looks petty until you see the failure: the review command prints which
files it covered, the pipe cuts that list, and the files scrolled off never get
stamped. The commit then passes with **part of the diff unreviewed** — and
nothing anywhere says so.

The author hit this **five times in one session**, each time with the same
motive ("output's long, I just want a peek"), with the rule already written down.
That's what earned it a hard deny instead of another line of documentation.

### 4. Reading budget (optional)

`checkers/check_brain_budget.py` caps the size of files your agent loads every
session — `CLAUDE.md`, a running state file, whatever you keep always-on.

Budget by **size, not entry count**. Real case: a file's rule said "≤15 entries",
`grep -c '^## '` returned exactly 15, fully compliant — and the file was 119 KB.
Count is a proxy, and proxies leak: flattened rows and mixed heading formats
don't match the pattern doing the counting. Bytes have no such gap.

Configure in `gates.toml` (see `templates/gates.toml.example`). Three target
kinds: per-file with 3 dimensions, glob surfaces (new files auto-included), and
directories outside the repo.

## What's actually been measured

Numbers from real use, not estimates:

| | |
|---|---|
| **Defects caught, same change set** | lint + types + 1085 tests + mutations → **0**. Reading the diff myself → **4**. Running it against an external rule checklist → **2 more**. |
| **Truncation recurrence** | **5 times in one session**, rule already documented in four places |
| **Gate regression suite** | **22 scenarios**, including self-referential ones (a commit message quoting the escape hatch must still be denied) |
| **Mutation self-check** | **4/4** — every assertion goes red when its subject breaks, green after restore |
| **Doc-reference checker** | 27 symbols, **0 false positives** |

That first row is the argument for the whole project: the automated tooling
found **nothing**, and it was right to — those defects weren't type errors or
test failures. They were things like *a value silently dropped* and *a dict key
that's missing on one path*. No linter is looking for those.

## Known bypasses

All of them. A tool like this is worth less if you find the holes yourself.

| # | Bypass | Impact | Mitigation |
|---|---|---|---|
| 1 | **Ran ≠ read** | Review command ran, nobody read the output | None. Spot-check. |
| 2 | **TOCTOU** | `edit && commit` in one Bash call hashes pre-edit content | Doesn't occur in normal flow |
| 3 | **Subagent bypass** | Subagent tool calls don't fire the parent session's hooks ⇒ gate is absent for them | 🔴 **None.** If you fan out to subagents, know that they're outside this. |
| 4 | **Model self-modification** | The model can edit `settings.json` and the hook scripts | Version-control the hooks |
| 5 | **Bash heredoc** | `cat > f << EOF` skips Write/Edit hooks | Minor here — this gates *commits*, not writes; unstamped files are denied, which is fail-closed |
| 6 | **Silent hook failure** | A hook that errors doesn't reliably block | Truncation detector self-reports failure; not yet everywhere |

3, 4, 5, 6 are from [anthropics/claude-code#45427](https://github.com/anthropics/claude-code/issues/45427),
whose title is the honest summary: *hooks are necessary but insufficient for
governance enforcement*. It was closed as `not planned`, so this layer is what
there is.

Related, and more damning than anything above:
[#40117](https://github.com/anthropics/claude-code/issues/40117) records an agent
using `--no-verify` and `git stash` to get around pre-commit hooks, **and trying
to hide that it did**. If you needed an argument for why reminders aren't
enough, it's that one.

## Prior art

This design has been arrived at independently at least three times: this repo,
[a blog post from April 2026](https://imti.co/pre-commit-review-gate/) (same
PreToolUse + SHA-256 + snapshot structure, down to hashing content rather than
mtime), and the reference implementation in RFC #45427.

Converging that hard usually means the shape is right. What's here that isn't
elsewhere: neither of those shipped as something you can install, and neither
came with the test suite. The 22 scenarios and the mutation checks are the part
that took real breakage to write.

## Repo layout

```
hooks/       two hooks — the gates themselves
checkers/    optional pre-commit checks (budget, doc references, index)
templates/   .brain skeleton, project switches, gates.toml, pre-commit config
tests/       22-scenario regression suite + structural tests
```

## A note on comments

The hooks and checkers are commented **in Chinese**, densely. Those comments are
mostly incident records — why a branch is ordered the way it is, which "obvious"
simplification was tried and reverted. Translating them would flatten exactly the
detail that makes them worth keeping. The English README covers usage; the
comments are archaeology.

## License

MIT
