# Contributing

## Requirements

| | |
|---|---|
| **bash** | 4.x or the macOS 3.2 that ships with the system — both are tested in CI |
| **git** | any recent version |
| **Python 3.11+** | `check_brain_budget.py` reads `gates.toml` with the stdlib `tomllib`, which landed in 3.11. The checker says so and exits rather than failing obscurely. |

Nothing else. No package manager, no virtualenv, no dependencies — deliberately,
because a gate that needs an install step is a gate that gets skipped.

## Running the tests

```bash
bash   tests/test_review_hook.sh        # 23 — gate scenarios
bash   tests/test_truncation_cases.sh   # 19 — truncation corpus
python3 tests/test_checkers.py          # 15 — structural checks on the checkers
bash   tests/e2e.sh                     # 15 — install onto a clean machine, end to end
bash   tests/mutations.sh               #  8 — break the hook, demand the right test goes red
```

All five run in CI on Linux and macOS. `e2e.sh` builds its own `$HOME` and repo
in a tempdir and touches nothing real — that claim is worth verifying before you
believe it; every path in it derives from `$T`.

## If you change `hooks/review-before-commit.sh`

**Run `tests/mutations.sh`.** Not as a formality. It breaks the hook eight
specific ways and requires a *named* assertion to go red each time. If your
change makes a mutation stop being caught, an assertion somewhere has quietly
stopped testing what it claims to.

It also refuses to run at all when the baseline suites aren't green, because
"went red under mutation" means nothing if it was already red.

Two failure modes it is built to tell apart:

- **A mutation that doesn't inject.** After a refactor, `sed` can match nothing
  and silently produce an identical copy — the tests then pass, and that reads
  like the mutation failed to fool them. `mutations.sh` compares the mutant
  against the original and reports "变异没注入" instead.
- **An assertion that can't distinguish deny from remind.** The hook prints the
  changed filenames in *both* its denial and its reminder. An assertion that
  greps the whole output for a filename is satisfied by either. Use the
  `deny_reason` / `notice` helpers in `test_review_hook.sh`, which parse the JSON
  and return only the branch you meant. Mutation M5 exists because scenario 8
  was green for exactly this reason.

## Comments are in Chinese

The hooks and checkers are commented densely, in Chinese, and those comments are
mostly incident records — why a branch is ordered the way it is, which "obvious"
simplification was tried and reverted, what broke on which date. Please keep
that style when you touch them; a patch that adds a branch without saying what
went wrong to earn it is losing the expensive half.

English is fine for new comments if Chinese isn't comfortable. Prose that
records *why* beats prose in the right language that only records *what*.

## Scope

This is a small tool with one idea. Things that fit:

- A gate that stops a failure you actually hit, with the incident in the comment
- A false positive fixed, with a test case added to the corpus that reproduces it
- Portability fixes (GNU vs BSD `sed`/`grep`/`xargs` differences)

Things that don't:

- Support for other agents (Cursor, Copilot, …) — this is built on Claude Code's
  hook mechanism and there is nothing generic underneath it
- Making the gates enabled by default. A tool that starts blocking on install
  gets uninstalled.
- Closing the [known bypasses](README.md#known-bypasses) that are listed as
  unfixable. If you can actually close one, that's a different and very welcome
  conversation — open an issue first.
