# Troubleshooting

Every entry here is a real failure, most of them silent. They're written as
symptom → cause, because the symptom is all you get.

## Every commit is denied, even after reviewing

**Cause: `PreToolUse` is registered for `Bash` but not `Skill`.**

The gate opens on a timestamp written when the review skill is invoked. That
invocation is a `Skill` tool call, not `Bash`. With a `Bash`-only matcher the
hook never fires for it, the timestamp is never written, the window is always
expired — and every commit is denied forever.

```jsonc
// ~/.claude/settings.json — the matcher must be both
{"matcher": "Bash|Skill", "hooks": [{"type": "command", "command": "bash \"$HOME/.claude/hooks/review-before-commit.sh\""}]}
```

`install.sh` gets this right. Hand-editing is where it goes wrong.

## Every commit is denied, and the review skill isn't installed

**Cause: `review-required` is on without [open-code-review](https://github.com/alibaba/open-code-review).**

There's no way to record a review, so nothing ever passes.

```bash
# in Claude Code
/plugin marketplace add alibaba/open-code-review
/plugin install open-code-review
```

Or turn the hard gate off (`rm .claude/hooks/review-required`) and keep the
reminder. Immediate escape: `SKIP_REVIEW_GATE=1 git commit …` — **must start the
line**, because the hook reads the command string, not the environment.

## Reviewed everything, still denied on some files

**Cause: the review command's output was piped.**

The command prints which files it covered; the snapshot is written from that
list. `| head`, `| tail`, `| grep`, `> file` — anything that cuts the output cuts
the list, and files that scrolled off never get stamped.

The truncation gate denies this outright now. If you're hitting it, the fix is
not to filter differently — it's to run the command **alone on its line with
nothing after it** and read the hook's own summary for what got stamped.

## Stamped some files, now the earlier ones are denied

**Cause: the snapshot is overwrite, not append.**

Stamping in batches invalidates each previous batch. Pass **every file this
commit will touch** in one invocation.

## The hook clearly ran, but the agent never saw its message

**Cause: the hook printed to stdout and exited 0.**

Bare stdout goes to the transcript. It does **not** enter the model's context.
To reach the agent the hook must emit JSON:

```json
{"decision": "block", "reason": "…"}
```

Measured the hard way: 16 triggers, 0 received. If you write a hook meant to
talk to the agent, verify once that it actually arrives — the failure mode is
completely silent.

## `PostToolUse` handler sees no `tool_response`

The docs say `PostToolUse` has no `tool_response`. **Measured: it does.**

Don't "fix" a branch that reads it just because the documentation disagrees.
Check what your version actually delivers.

## Gate passes but nothing was checked

Two shapes, both silent:

- **Budget checker with no `gates.toml`** — prints *nothing was checked* and
  exits 0. That message is the feature. If you see it in CI, your config isn't
  where the checker looks.
- **A glob matching zero files** — reported as an error, not a pass. A glob that
  matches nothing is a gate that doesn't exist, and it looks identical to a gate
  where everything complies.

## Checker inspects the wrong repository

**Cause: fixed, but worth knowing the shape.**

The checkers locate the repo with `git rev-parse --show-toplevel`, not with
`__file__`. An earlier version used `__file__`, which meant that when referenced
from another repo (a pre-commit `entry:` pointing at a clone) they inspected the
agent-gates clone instead — found none of your files, and reported success.

`tests/test_checkers.py` fails the build if any checker regresses to `__file__`.

## Hooks fire twice

**Cause: registered at both user and project level.**

These hooks are designed to live at user level (`~/.claude/hooks/`) and be
enabled per project by a flag file. If you also copied them into a project's
`.claude/hooks/` and registered them there, both copies run.

## Nothing happens at all

Expected, until a project opts in:

```bash
ls .claude/hooks/review-before-commit    # reminder
ls .claude/hooks/review-required         # hard gate
```

No flag file, no gate. That's deliberate — see the install notes.
