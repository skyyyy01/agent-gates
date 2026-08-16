#!/usr/bin/env bash
# End-to-end: clean machine -> install -> new repo -> gates actually fire.
#
#   bash tests/e2e.sh
#
# Runs entirely inside a temp HOME and a temp repo. Touches nothing real —
# verify that claim before believing it: every path below derives from $T.
#
# This exists because the unit suites test the hook and the checkers in
# isolation. What they cannot tell you is whether a person following the README
# ends up with a working gate. That is a different question, and it is the one
# users actually care about.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
chk() {  # chk <name> <actual> <expected-substring>   ('!' prefix = must NOT contain)
  local name="$1" got="$2" want="$3"
  if [[ "$want" == '!'* ]]; then
    if [[ "$got" != *"${want:1}"* ]]; then echo "  ✅ $name"; ((PASS++));
    else echo "  ❌ $name — should not contain '${want:1}'"; ((FAIL++)); fi
  else
    if [[ "$got" == *"$want"* ]]; then echo "  ✅ $name"; ((PASS++));
    else echo "  ❌ $name — expected '$want', got: ${got:0:120}"; ((FAIL++)); fi
  fi
}

export HOME="$T/home"
mkdir -p "$HOME"

echo "── 1. Install onto a clean machine ────────────────────────────"
out="$(bash "$REPO_ROOT/install.sh" 2>&1)"
chk "installer completes"            "$out" "装好了"
chk "registers three events"         "$out" "新增 3 项"
chk "warns about missing ocr"        "$out" "未检测到 open-code-review"
chk "hook file landed"               "$(ls "$HOME/.claude/hooks/" 2>&1)" "review-before-commit.sh"
chk "settings.json written"          "$(cat "$HOME/.claude/settings.json" 2>&1)" "Bash|Skill"

echo
echo "── 2. A fresh project, gates not yet enabled ──────────────────"
P="$T/proj"; mkdir -p "$P"; cd "$P"
git init -q; git config user.email e@e; git config user.name e
echo "print(1)" > app.py; git add app.py
payload() { printf '{"tool_name":"Bash","tool_input":{"command":%s},"cwd":"%s"}' "$1" "$P"; }
out="$(printf '%s' "$(payload '"git commit -m x"')" | bash "$HOME/.claude/hooks/review-before-commit.sh" 2>&1)"
chk "silent until a project opts in" "$out" "!deny"

echo
echo "── 3. Enable the hard gate ────────────────────────────────────"
mkdir -p .claude/hooks
: > .claude/hooks/review-before-commit
: > .claude/hooks/review-required
out="$(printf '%s' "$(payload '"git commit -m x"')" | bash "$HOME/.claude/hooks/review-before-commit.sh" 2>&1)"
chk "unreviewed commit is denied"    "$out" "deny"
chk "denial names the file"          "$out" "app.py"

echo
echo "── 4. Escape hatch still works ────────────────────────────────"
out="$(printf '%s' "$(payload '"SKIP_REVIEW_GATE=1 git commit -m x"')" | bash "$HOME/.claude/hooks/review-before-commit.sh" 2>&1)"
chk "escape hatch passes"            "$out" "!\"deny\""

echo
echo "── 5. Truncation gate ─────────────────────────────────────────"
out="$(printf '%s' "$(payload '"ocr delegate rule app.py | head -20"')" | bash "$HOME/.claude/hooks/review-before-commit.sh" 2>&1)"
chk "piped review command denied"    "$out" "deny"

echo
echo "── 6. Budget checker on a fresh repo ──────────────────────────"
out="$(python3 "$REPO_ROOT/checkers/check_brain_budget.py" 2>&1)"
chk "unconfigured says so"           "$out" "什么都没检查"
cp "$REPO_ROOT/templates/gates.toml.example" gates.toml
python3 - <<'PY'
import io, pathlib
p = pathlib.Path("gates.toml")
p.write_text('[[budget]]\npath = "CLAUDE.md"\nmax_file_kb = 1\nfile_hint = "trim it"\n')
PY
printf 'x%.0s' $(seq 1 2000) > CLAUDE.md          # 2 KB against a 1 KB cap
out="$(python3 "$REPO_ROOT/checkers/check_brain_budget.py" 2>&1)"; rc=$?
chk "over-budget file is flagged"    "$out" "超出读取预算"
chk "exit code is failure"           "$rc"  "1"
printf 'x%.0s' $(seq 1 500) > CLAUDE.md           # now compliant
out="$(python3 "$REPO_ROOT/checkers/check_brain_budget.py" 2>&1)"
chk "compliant file passes"          "$out" "✅"

echo
echo "── 7. Templates are usable as shipped ─────────────────────────"
cp -R "$REPO_ROOT/templates/brain" .brain
out="$(python3 "$REPO_ROOT/checkers/gen_brain_index.py" --check 2>&1)"
chk "index checker runs on skeleton" "$out" ".brain"

echo
echo "════ e2e PASS=$PASS FAIL=$FAIL ════"
[ "$FAIL" -eq 0 ] || exit 1
