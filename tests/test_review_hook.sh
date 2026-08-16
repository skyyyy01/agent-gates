#!/usr/bin/env bash
# 审查闸门 hook 的回归测试：`bash tests/test_review_hook.sh`
#
# 为什么值得有：那个 hook 是「动了代码必须先审」的执行者，它假绿=未审代码直接进仓库，
# 假红=谁都提交不了。2026-07-31 改它时，真实仓库验证抓到一个单测漏掉的 bug
# （pathspec 指向无改动文件被当成"解析失败"回落全工作区 ⇒ 纯记档提交被别的代码文件 deny）。
#
# ⚠️ 被测对象是**本仓的** `hooks/review-before-commit.sh`，不是 `~/.claude/hooks/` 里
# 那份已安装的副本（2026-08-16 修）。原先默认指向 $HOME，于是改了本仓的 hook、跑测试
# 全绿——测的却是另一个文件。实测那两份当时**已经不一致**。这正是 `checkers/_common.py`
# 里 `repo_root()` 那段注释批的同一个错：一道悄悄什么都没检查的闸门，与全部通过同形。
# 要测已安装的那份（验证 install.sh 装对了没）：HOOK_OVERRIDE=~/.claude/hooks/... 显式指定。
#
# 变异自检见 `tests/mutations.sh` —— 它把这里的断言逐条破坏一次，证明它们不是摆设。
SP="$(cd "$(dirname "$0")" && pwd)"
HOOK="${HOOK_OVERRIDE:-$SP/../hooks/review-before-commit.sh}"
T="${TMPDIR:-/tmp}/review_hook_t_repo"
PASS=0; FAIL=0

setup() {
  rm -rf "$T"; mkdir -p "$T/.claude/hooks"; cd "$T" || exit 1
  git init -q .; git config user.email t@t; git config user.name t
  : >.claude/hooks/review-before-commit   # 启用开关
  : >.claude/hooks/review-required        # 闸门开关
  date +%s >.claude/hooks/.review-skill   # 插件窗口新鲜
  echo "print(1)" >base.py
  # loose.py 必须**已跟踪**才测得到 DEFAULT/ALL 的差别：untracked 文件 `git commit -a`
  # 本来就不提交、也从不进 `$code`，拿它当样本会让「2c 不含 loose.py」变成假绿。
  echo "print('loose v1')" >loose.py
  git add base.py loose.py && git commit -qm init
  # mine.py = 我的改动；theirs.py = 并行会话的改动（也已 staged，模拟真实情况）
  echo "print('mine')" >mine.py
  echo "print('theirs')" >theirs.py
  echo "doc" >notes.md
  git add mine.py theirs.py notes.md
  # 已跟踪 + 已修改 + 未 staged：裸 commit 不该带它，`commit -a` 该带它
  echo "print('loose v2')" >loose.py
}

run() {  # run <json>  -> stdout of hook
  # ⚠️ 必须显式钉死 CLAUDE_PROJECT_DIR：hook 里是 `repo="${CLAUDE_PROJECT_DIR:-$PWD}"`,
  # 而真实 PreToolUse 调用时 Claude Code **会**设这个变量。只靠 cd 到 t_repo 的话,
  # 在设了它的环境里跑本测试,hook 会去读**真实项目仓库**——20 条断言全部变成对另一个
  # 仓库的判断(假绿假红都可能),而表面上一切正常。
  printf '%s' "$1" | CLAUDE_PROJECT_DIR="$T" bash "$HOOK" 2>/dev/null
}

# ⚠️ 判「deny 点名了某文件」**必须先剥出 deny 理由**，不能拿整段输出去 grep 文件名
# （2026-08-16 被变异 M5 抓出来的假绿）：不 deny 时 hook 会走到最后的提醒分支，而提醒
# 文案 `🔍 这次 commit 动了 N 个代码文件（mine.py …）` **也含那个文件名**。于是
# 「闸门拦住了 mine.py」和「闸门放行、只提醒了一句」在断言眼里一模一样 —— 场景 8
# （审后又改必须重新 deny）当时就是这样：hash 判据被换成只比路径后它依然全绿。
# 非 deny 时返回空串 ⇒ 「应含 X」正确变红。
deny_reason() {  # deny_reason <hook输出> -> permissionDecisionReason；非 deny 则空
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    h = (json.load(sys.stdin).get("hookSpecificOutput") or {})
except Exception:
    sys.exit(0)
if h.get("permissionDecision") == "deny":
    print(h.get("permissionDecisionReason", ""))
' 2>/dev/null
}

# 与 deny_reason 对称：只取**提示**分支的正文。deny 走的是 permissionDecisionReason，
# 所以这个 helper 天然把 deny 排除在外 —— 判「提示里点了某文件」时不会被 deny 顶替。
notice() {  # notice <hook输出> -> additionalContext；没有则空
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    h = (json.load(sys.stdin).get("hookSpecificOutput") or {})
except Exception:
    sys.exit(0)
print(h.get("additionalContext", ""))
' 2>/dev/null
}

chk() {  # chk <name> <output> <should_contain|!should_contain>
  local name="$1" out="$2" pat="$3" neg=0
  case "$pat" in "!"*) neg=1; pat="${pat#!}" ;; esac
  # ⚠️ 用 printf 且**不回显 out**：out 是 JSON，按字节截断会切碎 UTF-8 → 输出里混进
  # 无效字节，既让失败信息显示成乱码，又让统计用的 grep 把整段当二进制处理（实测踩到）。
  if [ "$neg" = 1 ]; then
    case "$out" in *"$pat"*) printf '❌ %s（不该含 %s）\n' "$name" "$pat"; FAIL=$((FAIL+1)); return ;; esac
  else
    case "$out" in *"$pat"*) ;; *) printf '❌ %s（应含 %s）\n' "$name" "$pat"; FAIL=$((FAIL+1)); return ;; esac
  fi
  printf '✅ %s\n' "$name"; PASS=$((PASS+1))
}

setup

echo "── 场景 1：pathspec 收窄——只提交 mine.py，别人的 theirs.py 不该卡我 ──"
O=$(run '{"tool_name":"Bash","tool_input":{"command":"git commit -m msg -- mine.py"}}')
chk "1a deny 里点名 mine.py" "$(deny_reason "$O")" "mine.py"
chk "1b deny 里没有 theirs.py" "$(deny_reason "$O")" '!theirs.py'

echo "── 场景 2：DEFAULT 范围——裸 git commit 只看 staged，不该带 unstaged 的 loose.py ──"
O=$(run '{"tool_name":"Bash","tool_input":{"command":"git commit -m msg"}}')
chk "2a 含 staged 的 mine.py" "$(deny_reason "$O")" "mine.py"
chk "2b 含 staged 的 theirs.py" "$(deny_reason "$O")" "theirs.py"
chk "2c 不含 unstaged 的 loose.py" "$(deny_reason "$O")" '!loose.py'

echo "── 场景 3：-a 范围——git commit -a 应把 unstaged 的 loose.py 也算进来 ──"
O=$(run '{"tool_name":"Bash","tool_input":{"command":"git commit -am msg"}}')
chk "3 -am 带上 loose.py" "$(deny_reason "$O")" "loose.py"

echo "── 场景 4：逃生口生效（本次修复的核心） ──"
O=$(run '{"tool_name":"Bash","tool_input":{"command":"SKIP_REVIEW_GATE=1 git commit -m msg -- mine.py"}}')
chk "4 放行（无 deny）" "$O" '!"permissionDecision": "deny"'

echo "── 场景 5：自指污染——commit message 行首原样引用逃生口，仍须 deny ──"
O=$(run '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"审查说明:\nSKIP_REVIEW_GATE=1 git commit ... 是逃生口\n\" -- mine.py"}}')
chk "5 仍然 deny" "$O" "deny"

echo "── 场景 6：只提交 docs——不 deny 也不提示 ──"
O=$(run '{"tool_name":"Bash","tool_input":{"command":"git commit -m msg -- notes.md"}}')
chk "6 静默" "$O" '!deny'
chk "6b 无提醒文案" "$O" '!这次 commit 动了'

echo "── 场景 7：覆盖谁记谁——rule 只传 mine.py，应给它盖章并提示 theirs 未审 ──"
O=$(run '{"tool_name":"Bash","tool_input":{"command":"ocr delegate rule mine.py"},"tool_response":{"stdout":"### Rule Group 1\nApplies to:\n- mine.py\n#### Content\n- x\n"}}')
# 这条锚定的是 PostToolUse 的**提醒**文案（不是 deny）。拆成两条：先确认走的是
# 「另有未审文件」那个分支，再确认清单里点了 theirs.py。合成一条会把顺序也钉死，
# 而未审清单的顺序取决于工作区里还剩什么，不该被断言绑住。
chk "7a 提示走的是「另有未审文件」分支" "$(notice "$O")" "未审**文件:"
chk "7a2 未审清单点名 theirs.py" "$(notice "$O")" "theirs.py"
chk "7b 快照已记 mine.py" "$(cat .claude/hooks/.review-ok 2>/dev/null)" "mine.py"
chk "7c 快照没记 theirs.py" "$(cat .claude/hooks/.review-ok 2>/dev/null)" '!theirs.py'
O=$(run '{"tool_name":"Bash","tool_input":{"command":"git commit -m msg -- mine.py"}}')
chk "7d 盖章后 mine.py 放行" "$O" '!deny'
O=$(run '{"tool_name":"Bash","tool_input":{"command":"git commit -m msg -- theirs.py"}}')
chk "7e 未盖章的 theirs.py 仍 deny" "$(deny_reason "$O")" "theirs.py"

echo "── 场景 8：审后又改内容 → 必须重新 deny（hash 判据不回归） ──"
# ⚠️ 这里必须判 deny **理由**里有 mine.py，不能判整段输出里有它：mine.py 刚在场景 7
# 盖过章，判据若从内容 hash 塌成只比路径就会放行，而放行路径上的提醒文案照样含
# "mine.py" ⇒ 断言全绿、闸门已空。变异 M5 就是复现这一条的。
echo "print('mine v2')" >mine.py
O=$(run '{"tool_name":"Bash","tool_input":{"command":"git commit -m msg -- mine.py"}}')
chk "8 改动后重新 deny" "$(deny_reason "$O")" "mine.py"

echo "── 场景 10：pathspec 指向**无改动**的文件 → 什么都不提交，不该回落全工作区 ──"
# 真实仓库验证时踩到的 bug：`git commit -- CLAUDE.md`（无改动）被当成"范围解析失败"
# 回落全量，于是纯 docs 提交被别的代码文件 deny 掉。base.py 自 init 后从未改过。
O=$(run '{"tool_name":"Bash","tool_input":{"command":"git commit -m msg -- base.py"}}')
chk "10a 不 deny" "$O" '!deny'
chk "10b 也不提示" "$O" '!这次 commit 动了'

echo "── 场景 11：真·docs-only 提交（notes.md 有改动）→ 静默 ──"
O=$(run '{"tool_name":"Bash","tool_input":{"command":"git commit -m msg -- notes.md"}}')
chk "11 静默" "$O" '!deny'

echo "── 场景 12：**新增**文件（untracked → add）必须能盖章、能提交，不能死锁 ──"
# 实测踩到的死锁：`git diff --cached`/`git diff` 都看不见 untracked，于是新文件
# 未 add 时拿不到章、add 后又被要求有章 ⇒ 永远 deny。修法是 files 并入 ls-files --others。
echo "print('brand new')" >fresh.py
O=$(run '{"tool_name":"Bash","tool_input":{"command":"ocr delegate rule fresh.py"},"tool_response":{"stdout":"### Rule Group 1\nApplies to:\n- fresh.py\n"}}')
chk "12a untracked 时就能盖章" "$(cat .claude/hooks/.review-ok 2>/dev/null)" "fresh.py"
git add fresh.py
O=$(run '{"tool_name":"Bash","tool_input":{"command":"git commit -m msg -- fresh.py"}}')
chk "12b add 之后放行（不死锁）" "$O" '!deny'

echo "── 场景 9：认不出的复合命令 → 回落全工作区（fail-CLOSED） ──"
O=$(run '{"tool_name":"Bash","tool_input":{"command":"cd /tmp && git commit -m msg -- mine.py && echo done"}}')
chk "9 回落后连 theirs.py 也拦（宁可多拦）" "$(deny_reason "$O")" "theirs.py"

echo
echo "════ PASS=$PASS  FAIL=$FAIL ════"
[ "$FAIL" = 0 ]
