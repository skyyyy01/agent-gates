#!/usr/bin/env bash
# 变异自检：`bash tests/mutations.sh`
#
# 回答的是「那些断言真的在测东西吗」。做法：把 hook 复制一份、注入一个**已知的坏改动**，
# 跑对应的测试，要求**指定的那条断言**变红；恢复后必须全绿。
#
# 为什么需要它：一条永远绿的断言与一条正确的断言长得一模一样。这个项目自己就出过
# 一次假绿——某条断言的被测对象根本没被执行到，是靠破坏**锚点**（而不是被测对象）
# 才照出来的。所以下面每条变异都指名道姓「哪一条必须变红」，而不是只要求「有红就行」：
# 后者会被任何一个无关的破坏满足，等于没测。
#
# ⚠️ 2026-08-16 之前这 8 条只是 `test_review_hook.sh` 头部注释里的手动步骤，
# README 徽章却已经在写 "8 mutations" —— 说的是一件没有脚本执行的事。

set -uo pipefail

SP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SP/../hooks/review-before-commit.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0

# mutate <编号> <说明> <sed 表达式> <哪个 runner> <必须变红的断言名>
mutate() {
  local id="$1" desc="$2" expr="$3" runner="$4" want_red="$5"
  local mut="$T/$id.sh" out

  sed "$expr" "$SRC" >"$mut"

  # ⚠️ 先证明变异**真的注入进去了**。hook 被重构后 sed 会安静地一个字都不改，
  # 于是跑的其实是原版、测试自然全绿 —— 而那会被读成「这条变异没能骗过测试」。
  # 一条注入失败的变异与一条被抓住的变异，在输出上必须长得不一样。
  if cmp -s "$mut" "$SRC"; then
    printf '  ❌ %s %s —— **变异没注入**（sed 未匹配，hook 大概被改过了；这条自检当前形同虚设）\n' "$id" "$desc"
    FAIL=$((FAIL+1)); return
  fi

  out=$(HOOK_OVERRIDE="$mut" bash "$SP/$runner" 2>&1)
  if printf '%s' "$out" | grep -qF "❌ $want_red"; then
    printf '  ✅ %s %s → 「%s」如期变红\n' "$id" "$desc" "$want_red"
    PASS=$((PASS+1))
  else
    printf '  ❌ %s %s → 「%s」**仍然绿** —— 这条断言测不到它声称测的东西\n' "$id" "$desc" "$want_red"
    FAIL=$((FAIL+1))
  fi
}

echo "── 0. 未变异时必须全绿（否则下面的「变红」说明不了任何事）──"
for r in test_review_hook.sh test_truncation_cases.sh; do
  if bash "$SP/$r" >/dev/null 2>&1; then
    printf '  ✅ %s 基线全绿\n' "$r"; PASS=$((PASS+1))
  else
    printf '  ❌ %s 基线就是红的 —— 先修它，变异自检在此之前没有意义\n' "$r"
    FAIL=$((FAIL+1)); echo; echo "════ mutations PASS=$PASS FAIL=$FAIL ════"; exit 1
  fi
done

echo
echo "── 1. 审查闸门的六条判据 ──"

# 逃生口用 re.match（整条命令最开头）而不是 re.search：写记档/commit message 时会
# 在**行首**原样引用这行字，用 search 就把「说明它」当成「执行它」。
mutate M1 "逃生口锚点 re.match→re.search" \
  's/^if re\.match(r"\\s\*SKIP_REVIEW_GATE/if re.search(r"\\s*SKIP_REVIEW_GATE/' \
  test_review_hook.sh "5 仍然 deny"

# pathspec 范围塌回 DEFAULT ⇒ 别人的未审文件又会卡住我的定向提交。
mutate M2 "pathspec 范围塌成 DEFAULT" \
  's/print("PATHSPEC")/print("DEFAULT")/' \
  test_review_hook.sh "1b deny 里没有 theirs.py"

# 「覆盖谁记谁」塌成「一起盖章」＝ 给没读过的代码盖章，这是最贵的那种假绿。
mutate M3 "盖章范围塌成「全部盖」" \
  's/^stamped = \[f for f in todo if covered(f)\]/stamped = list(todo)/' \
  test_review_hook.sh "7c 快照没记 theirs.py"

# 「范围解析出来了但里面没改动」被混成「解析失败」⇒ 纯记档提交被别的代码文件 deny。
mutate M4 "空范围与解析失败混为一谈" \
  's/^if \[ "\$_scoped" = 1 \]; then/if false; then/' \
  test_review_hook.sh "10a 不 deny"

# 判据从内容 hash 塌成只比路径 ⇒ 审完再改也照样放行，闸门只剩个空壳。
mutate M5 "hash 判据塌成只比路径" \
  's/grep -qxF "\$_h \$f"/grep -qF " \$f"/' \
  test_review_hook.sh "8 改动后重新 deny"

# untracked 不并入 ⇒ 新文件未 add 拿不到章、add 后又被要求有章 = 死锁。
mutate M6 "untracked 文件不并入待审集" \
  's/git -c core\.quotepath=false ls-files --others --exclude-standard/true/' \
  test_review_hook.sh "12a untracked 时就能盖章"

echo
echo "── 2. 截断闸门的两条判据 ──"

# 退回第一版：只判「| head 在行末」，不判「git commit 在命令位置」。
# 历史上这一版把 `grep -n "git commit" hook.sh | head -20` 也 deny 了 —— 它甚至挡住了
# 作者读源码来修这个 bug。
mutate M7 "丢掉「命令位置」判据（退回首版）" \
  's/if SEG_HEAD\.match(seg) and re\.search/if re.search/' \
  test_truncation_cases.sh "t5_fp_grep"

# 不剥 heredoc 正文 ⇒ `| tail` 落在不含 git commit 的那一行上 ⇒ 漏判。
# 而长 commit message 都走 heredoc，这是最常用的写法。
mutate M8 "不剥 heredoc 正文" \
  's/^body = re\.sub(.*/body = cmd/' \
  test_truncation_cases.sh "t9_real_heredoc"

echo
echo "════ mutations PASS=$PASS FAIL=$FAIL ════"
[ "$FAIL" -eq 0 ] || exit 1
