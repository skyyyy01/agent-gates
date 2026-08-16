"""Shared helpers for the checkers.

Exists for exactly one reason: `repo_root()` was wrong in three places and got
fixed in one. Keeping a single copy is the mechanism that stops the next fix
from missing two.
"""

from __future__ import annotations

import subprocess
from pathlib import Path


def repo_root() -> Path:
    """The repository being checked.

    ⚠️ **Not `Path(__file__).resolve().parents[1]`.** That only holds while the
    script lives inside the repo it checks. These checkers are referenced *by*
    other repositories (a pre-commit `entry:` pointing at a clone), so
    `__file__` resolves to the agent-gates clone — the checker would look for
    the user's files inside agent-gates, find none, and report success.

    A gate that silently checks nothing is the exact failure this whole project
    exists to prevent, and it shipped inside two of the three checkers.

    ⚠️ **Not `Path.cwd()` either.** Globs resolved from an unrelated cwd match
    zero files, and zero matches gets reported as "the gate is idle" — a false
    red. Measured: running from `/tmp` reproduced it.

    ⇒ Ask git. Fall back to cwd only when git has no answer (not a repo, or git
    is unavailable), which is the least-wrong option left.
    """
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=True,
        )
        return Path(out.stdout.strip())
    except Exception:
        return Path.cwd()
