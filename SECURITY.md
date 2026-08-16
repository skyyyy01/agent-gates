# Security

## What this is not

**agent-gates is not a security boundary.** It is a discipline mechanism for an
agent you already trust, running on a machine you already control. Every gate
here can be removed by anything that can write to your filesystem — including
the agent the gates are pointed at.

The [known bypasses](README.md#known-bypasses) in the README are the honest
version of this. Four of them have no mitigation:

- **Subagent tool calls don't fire the parent session's hooks.** If you fan out
  to subagents, the gates simply are not there.
- **The model can edit `settings.json` and the hook scripts themselves.**
  Version-control your hooks; that turns a silent edit into a visible diff, which
  is the most this layer can offer.
- **A hook that errors does not reliably block.** The truncation detector
  self-reports its own failure; the rest do not yet.
- **Ran ≠ read.** The gate can confirm a review command executed over a file. It
  cannot confirm a human or a model read the output.

Upstream's own summary, from the RFC this design descends from
([anthropics/claude-code#45427](https://github.com/anthropics/claude-code/issues/45427),
closed as `not planned`): *hooks are necessary but insufficient for governance
enforcement*. Treat the gates as friction that makes the right thing the default
path, not as enforcement against an adversary.

## What this tool touches on your machine

Worth knowing before you install:

| Path | What happens |
|---|---|
| `~/.claude/hooks/*.sh` | The two hook scripts are copied here |
| `~/.claude/settings.json` | Three hook registrations added, **idempotently**; the file is backed up to `settings.json.agent-gates.bak` first, and installation aborts rather than proceeding if the existing file isn't valid JSON |
| `~/.claude/hooks/.reminded/` | One state file per project, holding the last-reminded commit hash |
| `<project>/.claude/hooks/.review-ok` | The review snapshot: content hashes of reviewed files. **Gitignored on purpose** — committing it lets one machine's stamps pass another machine's gate |

The installer runs `curl … | bash` in the README's one-liner. If you'd rather
read it first — a reasonable instinct for something that edits `settings.json`:

```bash
git clone https://github.com/skyyyy01/agent-gates
cd agent-gates
less install.sh
bash install.sh          # uses the local hooks/, does not hit the network
```

The hooks run on **every** `Bash` and `Skill` tool call in every project, so they
exit early and cheaply — the first thing `review-before-commit.sh` does is a
substring test on the raw input, before any `git` or `python3` call, and the
second is checking for a per-project opt-in flag file.

## The escape hatch is deliberately visible

`SKIP_REVIEW_GATE=1 git commit …` bypasses the review gate. It must start the
command line, and it stays in your shell history — that's the point. A bypass
you can't audit afterwards is worse than no bypass.

## Reporting a vulnerability

For anything that lets the gates be bypassed *silently* — a case where the hook
reports success while checking nothing, or a denial that can be suppressed
without a trace — please open a
[GitHub issue](https://github.com/skyyyy01/agent-gates/issues). Silent failures
are the failure mode this project exists to fight, and they're worth more as
public test cases than as private reports.

If you'd rather not open a public issue, use GitHub's
[private vulnerability reporting](https://github.com/skyyyy01/agent-gates/security/advisories/new).

There is no bug bounty, and no SLA beyond "a hobbyist's attention".
