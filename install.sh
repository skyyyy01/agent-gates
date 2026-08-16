#!/usr/bin/env bash
# agent-gates installer
#
#   curl -fsSL https://raw.githubusercontent.com/skyyyy01/agent-gates/main/install.sh | bash
#
# 或者 clone 之后 `bash install.sh` —— 有本地 hooks/ 时优先用本地的，不联网。
#
# 做四件事：
#   1. 把两个 hook 装到 ~/.claude/hooks/
#   2. 注册到 ~/.claude/settings.json 的三个事件（幂等；先备份）
#   3. 检测 open-code-review 插件是否就位（硬闸门需要它）
#   4. 打印下一步 —— 装完什么都不会发生，必须由项目自己 opt-in
#
# ⚠️ 设计约束：装完之后**默认不生效**。hook 只在项目根有 flag 文件时才动作。
#    一个装上就开始拦人的工具会被立刻卸掉。

set -euo pipefail

REPO="${AGENT_GATES_REPO:-skyyyy01/agent-gates}"
BRANCH="${AGENT_GATES_BRANCH:-main}"
RAW="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
HOOK_DIR="${HOME}/.claude/hooks"
SETTINGS="${HOME}/.claude/settings.json"
HOOKS=(review-before-commit.sh commit-sync-reminder.sh)

say()  { printf '%s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# ── 1. 安装 hook ────────────────────────────────────────────
# 脚本可能是 `curl | bash` 跑的 —— 那时 $0 是 "bash"、没有目录可言。
# 所以先试本地，找不到再下载；两条路都要能走通，不能默认联网。
src_dir=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  maybe="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -d "${maybe}/hooks" ] && src_dir="${maybe}/hooks"
fi

mkdir -p "${HOOK_DIR}"
say "安装 hook 到 ${HOOK_DIR}"
for h in "${HOOKS[@]}"; do
  if [ -n "${src_dir}" ]; then
    cp "${src_dir}/${h}" "${HOOK_DIR}/${h}"
    ok "${h}（本地）"
  else
    curl -fsSL "${RAW}/hooks/${h}" -o "${HOOK_DIR}/${h}" \
      || die "下载 ${h} 失败 —— 检查网络，或 clone 仓库后本地运行"
    ok "${h}（下载）"
  fi
  chmod +x "${HOOK_DIR}/${h}"
done

# ── 2. 注册到 settings.json（幂等）──────────────────────────
say ""
say "注册到 ${SETTINGS}"
python3 - "$SETTINGS" <<'PY'
import json, shutil, sys
from pathlib import Path

p = Path(sys.argv[1])
p.parent.mkdir(parents=True, exist_ok=True)

# ⚠️ 先备份。这个文件是用户手写的，改坏了 Claude Code 起不来。
backed_up = False
if p.is_file():
    shutil.copy2(p, p.with_suffix(".json.agent-gates.bak"))
    backed_up = True
    try:
        data = json.loads(p.read_text() or "{}")
    except json.JSONDecodeError as e:
        raise SystemExit(f"  ✗ settings.json 不是合法 JSON（{e}）—— 请先修好它，安装已中止")
else:
    data = {}

# 三处注册，缺一不可：
#   PreToolUse  "Bash|Skill" —— 少了 Skill，插件调用不触发 hook ⇒ 时间戳永不写入
#                               ⇒ 窗口永远算过期 ⇒ 开了硬闸门就再也提交不了
#   PostToolUse "Bash"       —— 少了它，审查快照永不写 ⇒ 永远 deny
#   Stop        （无 matcher）—— 提交后的同步提醒
WANT = [
    ("PreToolUse",  "Bash|Skill", 'bash "$HOME/.claude/hooks/review-before-commit.sh"'),
    ("PostToolUse", "Bash",       'bash "$HOME/.claude/hooks/review-before-commit.sh"'),
    ("Stop",        None,         'bash "$HOME/.claude/hooks/commit-sync-reminder.sh"'),
]

hooks = data.setdefault("hooks", {})
added = skipped = 0
for event, matcher, command in WANT:
    groups = hooks.setdefault(event, [])
    # 幂等判据是「这条 command 在这个 event 下已存在」，不是「有没有同名 matcher 组」——
    # 用户可能把它挂在别的 matcher 上，重复注册会让同一个 hook 每次跑两遍。
    if any(
        h.get("command") == command
        for g in groups
        for h in g.get("hooks", [])
    ):
        skipped += 1
        continue
    entry = {"type": "command", "command": command}
    # 有同 matcher 的组就并进去，避免同一个 matcher 出现多个组
    for g in groups:
        if g.get("matcher") == matcher or (matcher is None and "matcher" not in g):
            g.setdefault("hooks", []).append(entry)
            break
    else:
        g = {"hooks": [entry]}
        if matcher is not None:
            g["matcher"] = matcher
        groups.append(g)
    added += 1

p.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
# ⚠️ 只在真备份了才提备份 —— 全新环境下没有文件可备，说"已备份"是假话，
# 而用户会据此以为有退路。
tail = f"（备份：{p.name}.agent-gates.bak）" if backed_up else "（此前没有 settings.json，已新建）"
print(f"  ✓ 新增 {added} 项，已存在 {skipped} 项{tail}")
PY

# ── 3. 检测 open-code-review ────────────────────────────────
# 硬闸门的放行判据是「最近 30 分钟调用过 /open-code-review:delegate-review」。
# 没装这个插件 + 开了硬闸门 = 提交不了任何代码。装的时候就说清楚，
# 别让人开了闸门才发现 —— 静默失败正是这套设计自己反复踩过的坑。
say ""
say "检查硬闸门依赖"
if ls -d "${HOME}/.claude/plugins/"*/open-code-review >/dev/null 2>&1 \
   || ls -d "${HOME}/.claude/plugins/marketplaces/open-code-review" >/dev/null 2>&1; then
  ok "open-code-review 已安装 —— 硬闸门可用"
else
  warn "未检测到 open-code-review。**提醒模式不受影响**，但硬闸门需要它："
  say  "      /plugin marketplace add alibaba/open-code-review"
  say  "      /plugin install open-code-review"
  say  "    不装的话别打开 review-required，否则会提交不了代码"
  say  "    （逃生口：SKIP_REVIEW_GATE=1 git commit …，必须整条命令行首起句）"
fi

# ── 4. 下一步 ───────────────────────────────────────────────
say ""
say "装好了。现在什么都不会发生 —— 闸门默认关闭，逐项目 opt-in："
say ""
say "  cd <你的项目>"
say "  mkdir -p .claude/hooks"
say "  touch .claude/hooks/review-before-commit    # ① 提醒：改了代码提交前提示一句"
say "  touch .claude/hooks/review-required         # ② 硬闸门：没审过就 deny（需 ocr）"
say "  touch .claude/hooks/review-includes-tests   # ③ 把 tests/ 也纳入审查范围"
say ""
say "三个开关互相独立，建议先只开 ①，用几天再决定要不要 ②。"
say "预算检查器（可选）：把 templates/gates.toml.example 复制成仓库根的 gates.toml。"
