#!/usr/bin/env python3
"""Structural tests for the checkers. Run: python3 tests/test_checkers.py

These do not test what the checkers report — they test that the checkers are
still wired up to report anything at all. Every case here exists because the
thing it checks was once broken in a way that produced a green result.

No pytest on purpose: this project promises one-command install, and a test
suite that needs `pip install` is a second command.
"""

from __future__ import annotations

import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHECKERS = sorted((ROOT / "checkers").glob("*.py"))
FAILED: list[str] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    print(f"  {'✅' if ok else '❌'} {name}{'' if ok else '  ← ' + detail}")
    if not ok:
        FAILED.append(name)


# ── 1. Repo root must come from git, never from __file__ ────────────────────
# History: two of three checkers located the repo with
# `Path(__file__).resolve().parent.parent`. That is correct only while the
# script lives inside the repo it checks. Referenced from another repo, they
# inspected the agent-gates clone instead — found none of the user's files, and
# reported success. One was fixed; the other two were missed, because nothing
# forced a sweep for the same shape. This test is that force.
BAD_ROOT = re.compile(r"__file__.*parent\.parent|__file__.*parents\[1\]")
for f in CHECKERS:
    if f.name == "_common.py":
        continue
    src = f.read_text(encoding="utf-8")
    body = "\n".join(ln for ln in src.splitlines() if not ln.lstrip().startswith("#"))
    check(
        f"{f.name}: repo root not derived from __file__",
        not BAD_ROOT.search(body),
        "use repo_root() from _common",
    )
    check(
        f"{f.name}: imports repo_root",
        "from _common import repo_root" in src,
        "must share the single implementation",
    )

# ── 2. Every checker must be runnable as a script ───────────────────────────
for f in CHECKERS:
    if f.name == "_common.py":
        continue
    src = f.read_text(encoding="utf-8")
    check(f"{f.name}: has __main__ entry", "__main__" in src)

# ── 3. A checker with nothing to check must SAY SO, not exit 0 quietly ──────
# The budget checker with no config used to be the obvious place for this to go
# wrong: no targets configured looks exactly like all targets passing.
with tempfile.TemporaryDirectory() as td:
    subprocess.run(["git", "init", "-q", td], check=True)
    out = subprocess.run(
        [sys.executable, str(ROOT / "checkers" / "check_brain_budget.py")],
        cwd=td,
        capture_output=True,
        text=True,
    )
    check(
        "check_brain_budget: says nothing was checked when unconfigured",
        "什么都没检查" in out.stdout or "nothing was checked" in out.stdout.lower(),
        f"printed: {out.stdout.strip()[:80]!r}",
    )

# ── 4. KB→bytes must round, not truncate ────────────────────────────────────
# 4 of the 999 one-decimal values in 0.1–99.9 land a byte low under int(),
# which would flag a compliant file — a false red, the expensive kind.
budget_src = (ROOT / "checkers" / "check_brain_budget.py").read_text(encoding="utf-8")
check(
    "check_brain_budget: KB conversion uses round()",
    "round(v * 1000)" in budget_src and "int(v * 1000)" not in budget_src,
)

print()
if FAILED:
    print(f"════ {len(FAILED)} FAILED ════")
    sys.exit(1)
print("════ all structural checks passed ════")
