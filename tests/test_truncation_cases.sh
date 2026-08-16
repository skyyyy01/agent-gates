#!/usr/bin/env bash
# 截断闸门的 19 个场景回归：`bash tests/test_truncation_cases.sh`
#
# 语料在 `tests/testcases-commit-truncation/`，期望值在同目录 `expect.json`
# （true = 必须 deny）。两批的来历与三个容易写错的期望，见那个目录的 README。
#
# ⚠️ 这个 runner 是 2026-08-16 补的。在此之前那 19 个用例是**孤儿** —— 没有任何脚本
# 跑它们，唯一的跑法是目录 README 里一段要人手动粘贴的 Python，而那段代码里的路径
# 还停留在作者机器上的旧位置（`.claude/hooks/testcases-commit-truncation`），照抄必红。
# 一个主张「机制优于纪律」的项目，有 19 个测试靠「记得手动粘贴文档里的代码」来跑。
#
# ── 为什么必须自建一个**干净**仓库，不能复用 test_review_hook.sh 的那个 ──────────
# 那边的样本仓库里躺着未审的 mine.py/theirs.py，而 `03_ok_clean` 这类用例本身是
# `git commit -m "x" -- a.py` —— 它会被**审查闸门**（不是截断闸门）deny，于是期望
# 「放行」的用例全部变红，红得还很有道理。这里只开 `review-before-commit` 一个开关、
# 不开 `review-required`，让 deny **只可能**来自截断闸门。
#
# ⚠️ 数据必须**从文件喂给 stdin**，不能 `echo "$(cat f)"` 转一道：用例里的 `\n` 是
# JSON 字符串里的两字符转义，被 echo/printf 解释成真换行就变成了另一条命令，
# heredoc 那几条（t9/t11/t12）的判据整个失效。

set -uo pipefail

SP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_OVERRIDE:-$SP/../hooks/review-before-commit.sh}"
TC="$SP/testcases-commit-truncation"

[ -f "$HOOK" ] || { echo "❌ 找不到被测 hook：$HOOK"; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/.claude/hooks"
git -C "$T" init -q
: >"$T/.claude/hooks/review-before-commit"   # 只开提醒；不开 review-required

PASS=0; FAIL=0

# 判据要的是「**截断**闸门 deny 了」，不是「有 deny」—— 后者会把别的闸门的 deny
# 算成自己的功劳（假绿）。两条截断分支的文案都含「后面跟了」，用它当指纹。
run_case() {  # run_case <name> <want_deny:0|1>
  local name="$1" want="$2" out denied=0
  out=$(CLAUDE_PROJECT_DIR="$T" bash "$HOOK" <"$TC/$name.json" 2>/dev/null)
  case "$out" in *'"permissionDecision": "deny"'*) case "$out" in *后面跟了*) denied=1 ;; esac ;; esac
  if [ "$denied" = "$want" ]; then
    printf '  ✅ %s\n' "$name"; PASS=$((PASS+1))
  else
    printf '  ❌ %s（期望 deny=%s，实际 deny=%s）\n' "$name" "$want" "$denied"; FAIL=$((FAIL+1))
  fi
}

# ⚠️ `${HOOK}` 的花括号不能省：紧跟其后的是全角「）」，bash 会把它当成变量名的一部分
# ⇒ `set -u` 下报 unbound variable。中文注释密集的脚本里这是个反复出现的坑。
echo "── 截断闸门 19 场景（被测：${HOOK}）──"
while IFS=' ' read -r name want; do
  [ -z "$name" ] && continue
  [ -f "$TC/$name.json" ] || { printf '  ❌ %s（expect.json 点名了它，语料却不在）\n' "$name"; FAIL=$((FAIL+1)); continue; }
  run_case "$name" "$want"
done < <(python3 -c '
import json, pathlib, sys
# ⚠️ 反过来也要查：语料在、expect.json 里没有 ⇒ 那条用例等于没人跑，
# 而目录看上去仍然很充实。孤儿语料是这个 runner 存在的理由本身。
d = pathlib.Path(sys.argv[1])
exp = json.loads((d / "expect.json").read_text(encoding="utf-8"))
have = {p.stem for p in d.glob("*.json") if p.name != "expect.json"}
orphan = sorted(have - set(exp))
if orphan:
    print("__ORPHAN__ " + ",".join(orphan), file=sys.stderr)
for name, want in exp.items():
    print(name, 1 if want else 0)
' "$TC" 2> >(grep '__ORPHAN__' >&2))

echo
echo "════ truncation PASS=$PASS FAIL=$FAIL ════"
[ "$FAIL" -eq 0 ] || exit 1
