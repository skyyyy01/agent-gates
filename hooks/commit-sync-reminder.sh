#!/usr/bin/env bash
# Stop hook —— **有新 commit 落定时提醒一次**。用户级:对所有项目生效,但**默认关闭**。
#
# ── 启用方式(默认关闭是有意的) ──────────────────────────────────────────────
# 只有当项目根存在 `.claude/hooks/commit-reminder.txt` 时才提醒,文件内容即提醒正文。
# 没有这个文件 = 该项目不需要 ⇒ 静默 exit 0。理由:Stop hook 用 decision:block 打断
# 收尾,在不需要的项目里等于每次提交后都被莫名其妙拦一下,很快就会被整个关掉。
#
# ── 触发逻辑(精度靠 commit hash 差分,不是时间窗) ────────────────────────────
#  - 只在【HEAD 变了 vs 上次已提醒的 hash】时提醒 ⇒ 纯对话完全静默。
#  - **每个 commit 只提醒一次**:提醒后把 HEAD 写进状态文件。
#  - stop_hook_active=true(已因本 hook 继续过一次)→ 静默,防无限循环。
# 旧版用「最近 N 分钟有 commit」的时间窗 → commit 后窗口内的纯对话也被误提醒;
# 换成 hash 差分后精准到零误报(实测一整个 session 七八次全部命中真事件)。
#
# ── 状态文件放用户级,按项目分 ───────────────────────────────────────────────
# `~/.claude/hooks/.reminded/<项目路径>`。**不放项目内**是因为那样每个项目都得往
# 自己的 .gitignore 加一条,而一个通用 hook 不该要求被它服务的项目改配置。
#
# 退出码恒 0;任何异常一律静默放过,绝不卡会话。

set +e
input=$(cat 2>/dev/null)

# 已经因为本 hook 续过一次 → 别再拦(否则无限循环)
case "$input" in
  *'"stop_hook_active": true'* | *'"stop_hook_active":true'*) exit 0 ;;
esac

repo="${CLAUDE_PROJECT_DIR:-}"
[ -z "$repo" ] && exit 0

# 未启用(没放文案文件)→ 静默。这一步在 git 调用之前,非 git 项目也零成本。
msg_file="$repo/.claude/hooks/commit-reminder.txt"
[ -f "$msg_file" ] || exit 0
reason=$(cat "$msg_file" 2>/dev/null)
[ -z "$reason" ] && exit 0

head=$(git -C "$repo" rev-parse HEAD 2>/dev/null)
[ -z "$head" ] && exit 0

state_dir="$HOME/.claude/hooks/.reminded"
mkdir -p "$state_dir" 2>/dev/null
state="$state_dir/$(printf '%s' "$repo" | tr '/' '-')"
last=$(cat "$state" 2>/dev/null)

if [ "$head" != "$last" ]; then
  # 出现新 commit,本 commit 还没自检过 → 提醒一次 + 记录(下次起这个 hash 静默)
  echo "$head" >"$state" 2>/dev/null
  # 用 python 生成 JSON:文案里可能有引号/换行/反斜杠,手拼字符串会产出非法 JSON,
  # 那样 hook 输出被丢弃 = 提醒静默失效(且没有任何报错)。
  REASON="$reason" python3 -c '
import json, os
print(json.dumps({"decision": "block", "reason": os.environ["REASON"]}, ensure_ascii=False))
' 2>/dev/null
fi
# HEAD 未变(纯对话/已自检过) → 静默,什么都不输出
exit 0
