#!/usr/bin/env bash
# PreToolUse(Bash|Skill) + PostToolUse(Bash) hook —— **动了代码的 commit，提交前提醒先审一遍**。
# 用户级：装在全局，但**默认关闭**，逐项目 opt-in。
#
# ── 启用方式（默认关是有意的）──────────────────────────────────────────────
# 只有当项目根存在 `.claude/hooks/review-before-commit` 时才提醒；没有 = 该项目不需要 ⇒ 静默 exit 0。
# 与同目录 `commit-sync-reminder.sh` 同一套约定：**通用 hook 默认不打扰**，
# 在不需要的项目里冒出来会训练人忽略、乃至干脆关掉整个 hook 机制。
# （2026-07-31 从"默认开 + no-review-reminder 关"改成现在这样，用户要求。
#   旧的 `no-review-reminder` 开关随之作废——当时全机器没有任何项目用过它。）
#
# ── 默认规则自己管，微调才要配置 ────────────────────────────────────────────
# 各项目目录结构天差地别（src/ app/ lib/ cmd/ internal/…），列白名单必然漏。
# 所以反过来：**排除明确不是代码的**（文档/记忆/测试/CI 配置/生成的锁文件），剩下的都算代码。
# 好处是**默认规则换任何项目都不用改这个脚本**。
#
# 项目级文件一共三个，都在该项目的 `.claude/hooks/` 下：
#   `review-before-commit`     启用开关（**必需**，见上方"启用方式"；没有它整个 hook 静默）
#   `review-includes-tests`    可选，空文件 → 让 `tests/` 也参与统计（见下方 skip_dirs 处）
#   `review-exclude.txt`       可选，每行一个正则 → 追加排除本项目特有的生成物/数据/vendor
# 后两个是**可选**的：不放就是纯默认行为。之所以由项目声明而不是写进脚本 ——
# "哪些目录是生成物"只有项目自己知道，写进通用脚本必然越攒越长且对别的项目全是噪声。
#
# ── ⚠️ 注册要求：**PreToolUse(Bash|Skill) + PostToolUse(Bash) 两处都要注册** ────────
# 记快照的判据是"命令真的跑过，且给它输出的规则清单**覆盖到的那些文件**盖章"，而只有
# PostToolUse 拿得到 tool_response。少注册 PostToolUse ⇒ 快照永远不会被写 ⇒ 闸门永远 deny。
# （官方文档说 PostToolUse 的输入没有 tool_response —— 2026-07-31 实测**是有的**，
#   快照真的写出来了。别照文档把这个分支"修"掉。）
#
# ── ⚠️ 注册要求：matcher 必须是 `Bash|Skill`，少了 Skill 会**死锁** ──────────────
# 闸门放行的前提是"最近 30 分钟调用过 /open-code-review:delegate-review"，而那条记录
# （`.review-skill`）只在 tool_name=Skill 的调用里写得下。matcher 若只有 Bash，
# Skill 调用根本不触发本 hook ⇒ 时间戳永远不存在 ⇒ 窗口永远算过期 ⇒ 任何
# `ocr delegate rule` 都不计入审查 ⇒ **启用了 review-required 的项目将无法提交任何代码改动**
# （只剩 SKIP_REVIEW_GATE=1 一条路）。改 settings.json 时别把这个 matcher 改窄。
#
# ── 它只是提醒，代替不了审查 ────────────────────────────────────────────────
# 审查是推理过程，hook 是 shell，执行不了。这里的作用是保证"别忘了"。
#
# 退出码恒 0；任何异常一律静默放过，绝不卡工具调用。

set +e
input=$(cat 2>/dev/null)

# 只管三种调用。**这一步必须极便宜**——matcher 是 `Bash|Skill`，每个 Bash 调用都会
# 走到这里，绝大多数与本 hook 无关，得在任何 git/python 调用之前就退出去。
case "$input" in
  *"git commit"*|*"ocr delegate rule"*|*'"tool_name":"Skill"'*|*'"tool_name": "Skill"'*) ;;
  *) exit 0 ;;
esac

repo="${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$repo" 2>/dev/null || exit 0

# 未启用（没放开关文件）→ 静默。这一步放在 git 调用之前，非 git 项目也零成本。
[ -e "$repo/.claude/hooks/review-before-commit" ] || exit 0

# ── Skill 调用：记下"插件被调过" ───────────────────────────────────────────────
# 2026-07-31 实测的真实结构（装临时探针抓的，不是凭记忆）：
#   tool_name = "Skill"，tool_input = {"skill": "open-code-review:delegate-review",
#                                       "args": "--commit HEAD"}
# 为什么要单独记它：闸门原本只认命令串 `ocr delegate rule`，而那正是**手动路径**的标志——
# 手动敲会跳过 command 的 Step 4（按 High/Medium/Low 分级 + 自动修 High/Medium）。
# 只认命令 = 把近似动作固化进机制（用户 2026-07-31 连纠三次同一个模式）。
case "$input" in
  *'"tool_name":"Skill"'*|*'"tool_name": "Skill"'*)
    case "$input" in
      *delegate-review*) date +%s >"$repo/.claude/hooks/.review-skill" 2>/dev/null ;;
    esac
    exit 0
    ;;
esac

# ── 截断闸门(2026-08-04 加,用户拍板)────────────────────────────────────────
# `ocr delegate rule` 后面跟管道/重定向 ⇒ 输出被截 ⇒ **被截掉的文件盖不上章**,
# 而 commit 的判据是「本次要提交的文件是否都有章」⇒ 白跑一轮甚至误以为审过了。
# ⚠️ 为什么必须 deny 而不是提示:这条已**用尽「纪律」这个形式** —— CLAUDE.md 明文
# 「一个都不许」、写成了「这条命令单独成行」的机械动作、当天还写进 journal 与 memory,
# **同一天仍踩四次**,每次动机都是同一个「输出太长只想看一眼」。与 review 闸门本身
# 从「只提示」升级到「deny」是同一条路。
# ⚠️ **必须放在 files 计算之前**:截断与「有没有待审文件」无关,而 files 为空时脚本会
# 提前 exit(2026-08-04 实测:干净工作区下闸门整个不生效 —— 第一版就放错了位置)。
# ⚠️ python 代码**不许加缩进**:它在单引号里有自己的缩进语义,整体缩进会
# IndentationError,而 `2>/dev/null` 把错误吞掉 ⇒ 闸门无声失效(同日实测踩到)。
# 所以下面额外加了一条自证:python 非零退出时打一行提示,别让它悄悄消失。
case "$input" in
  *'\nocr delegate rule'*|*'"command":"ocr delegate rule'*|*'"command": "ocr delegate rule'*)
    TRUNC_LINE=$(printf '%s' "$input" | python3 -c '
import json, re, sys
raw = sys.stdin.read()
try:
    cmd = json.loads(raw).get("tool_input", {}).get("command", "")
except Exception:
    sys.exit(3)
for line in cmd.split("\n"):
    ls = line.strip()
    if ls.startswith("ocr delegate rule") and re.search(r"[|>]", ls):
        print(ls[:160])
        break
')
    _rc=$?
    if [ "$_rc" -ne 0 ] && [ "$_rc" -ne 3 ]; then
      # 自证:闸门自己坏了要说出来(否则它无声消失,与"没有截断"同形)
      python3 -c 'import json; m="⚠️ 截断闸门的检测脚本执行失败,本次未检查——闸门可能坏了,请查 ~/.claude/hooks/review-before-commit.sh"; print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":m},"systemMessage":m},ensure_ascii=False))' 2>/dev/null
      exit 0
    fi
    if [ -n "$TRUNC_LINE" ]; then
      D="🚫 \`ocr delegate rule\` 后面跟了管道/重定向 —— **被截掉的文件盖不上章**,
而 commit 的判据是「本次要提交的文件是否都有章」,所以这一轮等于白跑(甚至会让你
以为审过了)。

  你写的:  ${TRUNC_LINE}

**正确形式:这条命令单独成行,后面什么都不加。** 想确认盖章结果就看 hook 的提示
(有未审文件它会点名),别去过滤输出。
⚠️ 本闸门 2026-08-04 从「提示」升级为 deny:同一天内该纪律被踩四次——CLAUDE.md 写过、
写成机械动作、当天写进 journal 与 memory,都没挡住。" \
      python3 -c '
import json, os
d = os.environ["D"]
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": d,
}}, ensure_ascii=False))
' 2>/dev/null
      exit 0
    fi
    ;;
esac

# ── git commit 的截断保护(2026-08-04 同日补)────────────────────────────────
# 与上面同源:`git commit … | tail -4` 会把**失败原因**截掉。同日实测踩了两次,第二次
# 白绕一圈 —— 提交失败的真因是「pre-commit reformat 了文件 ⇒ 审查快照失效」,而那行
# 提示正好在被截掉的部分。git commit 的输出本来就只有十几行,**根本不需要截**。
# ⚠️ 只 deny `| head` / `| tail`,**不碰 `>` 和 `2>`**:commit message 里出现 `>` 极常见
# (箭头/引用/比较),按 `>` 判会大面积误伤。这是**有意的窄口径**,不是遗漏。
case "$input" in
  *"git commit"*)
    GC_TRUNC=$(printf '%s' "$input" | python3 -c '
import json, re, sys
try:
    cmd = json.loads(sys.stdin.read()).get("tool_input", {}).get("command", "")
except Exception:
    sys.exit(3)
# 剥掉 heredoc 正文(commit message 常含 | 和 >),只看命令骨架。
# ⚠️ 末尾 `[ \t]*\n?` 要吃掉结束标记那行的换行 —— 否则 `git commit -m "$(cat <<EOF
# … EOF\n)" | tail -2` 剥完变成两行,`| tail` 落在不含 git commit 的第二行上 ⇒ 漏判。
# 而这恰恰是**最常用的写法**(长 commit message 都走 heredoc),实测 t9 场景抓到。
body = re.sub(r"<<\s*.?(\w+).?[\s\S]*?\n\1[ \t]*\n?", " <<HEREDOC ", cmd)
# ⚠️ 判据必须区分「执行」与「提到」——写文档/写测试/写记档时命令行里会出现这个串
# (实测:验证本闸门的那条测试命令自己被 deny 了,[[self-referential-contamination]])。
# 两道:①`| head`/`| tail` 必须在**行末** ②`git commit` 必须在**命令位置**
#       (行首 / `&&` `||` `;` `|` 之后,允许 `VAR=x` 前缀),不能是引号里的字面量。
# ⚠️ 只有 ① 的时候被实测打脸两次(同日):
#     · `archive_current.py --summary "…git commit 截断保护…" 2>&1 | tail -2`
#     · `grep -n "git commit" hook.sh | head -20`  ← 它甚至挡住了我读本文件来修这个 bug
#   两条的 `git commit` 都在**引号内**,而 `| tail` 确实在行末 ⇒ ① 单独不够。
#   注释原本写「字面量里的它后面总跟着别的东西,不会在行尾」——那说的是 `| head` 的位置,
#   根本没约束 `git commit` 自己在哪。**记档/commit message 天天引用这个串** ⇒ 必修。
# ⚠️ 必须**按命令分隔符切段**再判,不能按物理行 —— 否则
#   `git commit -m "…" && gh run list | head -3` 会被 deny,而那个 head 是给 gh 的
#   (实测 t11 场景)。段内保留 `|`(管道属于同一条命令),段间用 && || ; 换行 切开。
SEG_HEAD = re.compile(r"^\s*(?:\w+=\S+\s+)*git\s+commit\b")
for seg in re.split(r"&&|\|\||;|\n", body):
    if SEG_HEAD.match(seg) and re.search(r"\|\s*(head|tail)(\s+-\w+)?\s*$", seg.rstrip()):
        print(seg.strip()[:150])
        break
')
    _rc=$?
    if [ "$_rc" -ne 0 ] && [ "$_rc" -ne 3 ]; then
      python3 -c 'import json; m="⚠️ git commit 截断检测脚本执行失败,本次未检查"; print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":m},"systemMessage":m},ensure_ascii=False))' 2>/dev/null
      exit 0
    fi
    if [ -n "$GC_TRUNC" ]; then
      D2="🚫 \`git commit\` 后面跟了 \`| head\`/\`| tail\` —— **提交失败时,原因就在被截掉的
那部分**。同日实测:一次提交失败的真因是「pre-commit reformat 了文件 ⇒ 审查快照失效」,
那行提示正好被 tail 截掉,白绕一圈才查出来。

  你写的:  ${GC_TRUNC}

git commit 的输出本来就只有十几行,**不需要截**。要看简短结果用 \`git log --oneline -1\`。" \
      python3 -c '
import json, os
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": os.environ["D2"],
}}, ensure_ascii=False))
' 2>/dev/null
      exit 0
    fi
    ;;
esac

# ⚠️ `-c core.quotepath=false` 是必须的（2026-07-31 实测）：默认 git 会把**非 ASCII 文件名**
# 转义成 `"\346\236\266..."`（**带引号**），于是 `架构设计.md` 结尾不是 `d` 而是 `"`，
# `\.md$` 匹配不上 ⇒ 一个纯文档改动被算成"代码文件"、白提示一次。中文/日文/韩文文件名
# 在任何项目都可能有，所以修在这里而不是让项目自己绕。
# ⚠️ 必须带上 **untracked**（2026-07-31 实测踩到死锁）：`git diff --cached` 与 `git diff`
# 都看不见新建文件，于是**任何新增代码文件都无法通过闸门**——未 `git add` 时 hook 看不到它，
# 给不了章；`git add` 之后它进了 staged、闸门要求有章，而章永远记不上 ⇒ 死锁。
# 加上它也让口径真的与 `ocr delegate preview` 的 workspace 模式（staged+unstaged+untracked）
# 一致（原注释宣称"天然对齐"，实际差了 untracked 这一块）。`--exclude-standard` 尊重
# .gitignore，构建产物不会涌进来。
files=$({ git -c core.quotepath=false diff --cached --name-only
          git -c core.quotepath=false diff --name-only
          git -c core.quotepath=false ls-files --others --exclude-standard; } 2>/dev/null | sort -u)
[ -z "$files" ] && exit 0

# tests 默认排除（多数项目里测试改动不必每次提醒）。但有的项目**测试本身就是要审的对象**
# ——断言覆盖不到的维度 = 假绿，跑多少次都不会红。放空文件
# `.claude/hooks/review-includes-tests` 即让测试也参与统计。
# ⚠️ `skip_note` 必须跟着 `skip_dirs` 一起分叉(2026-07-31 实测):末尾那行提示原本写死
# 「只改 docs/memory/tests/锁文件时本提示不出现」,而启用本开关的项目里**改 tests 就会提示**
# —— 文案成了假话,且它是**打给 agent 看的**,会让人按错误的预期判断"这次为什么提示了"。
# 「告警文案是承诺,承诺要跟着实现走」:同一次改动里加了分支,就得把描述这个分支的话一起改。
if [ -e "$repo/.claude/hooks/review-includes-tests" ]; then
  skip_dirs='(^|/)(docs?|memory|\.claude|\.github)/'
  skip_note='docs/memory/锁文件时本提示不出现；本项目已把 tests 纳入审查'
else
  skip_dirs='(^|/)(docs?|memory|\.claude|\.github|__tests__|tests?|spec|fixtures|testdata)/'
  skip_note='docs/memory/tests/锁文件时本提示不出现'
fi

code=$(printf '%s\n' "$files" \
  | grep -vE "$skip_dirs" \
  | grep -vE '\.(md|txt|rst|adoc|lock|sum)$' \
  | grep -vE '(-lock\.json|\.lock\.json)$' \
  | grep -vE '(^|/)(README|CHANGELOG|LICENSE|CONTRIBUTING)')

# 项目级追加排除：`.claude/hooks/review-exclude.txt`，每行一个 grep -E 正则，`#` 开头是注释。
# 上面的通用规则按"排除明确不是代码的"设计，但每个项目都有自己的生成物/数据/vendor 目录
# （本仓：reports/ 研究产物、.brain/*.jsonl 台账、static/vendor/ 第三方库），
# 那些只有项目自己知道 ⇒ 由项目声明，脚本保持通用。
xf="$repo/.claude/hooks/review-exclude.txt"
if [ -n "$code" ] && [ -f "$xf" ]; then
  while IFS= read -r pat || [ -n "$pat" ]; do
    case "$pat" in ''|'#'*) continue ;; esac
    code=$(printf '%s\n' "$code" | grep -vE "$pat")
    [ -z "$code" ] && break
  done <"$xf"
fi
[ -z "$code" ] && exit 0

# ── 审查闸门（逐项目 opt-in：放空文件 `.claude/hooks/review-required` 才启用）──────
#
# 为什么需要它：提醒挡不住一个**错误的自我评估**。2026-07-31 实证——我不是忘了审，
# 是"以为审了"（跑过 lint/类型/全量测试/变异测试，"验证"那个格子已经被填上），
# 于是「提交前先审一遍」被一个**近似的已完成动作**吸收掉。同一批改动：只跑测试抓到 0、
# 自己读 diff 抓到 4、按 OCR 规则清单再审又抓到 2（全是自己读时漏掉的维度）。
#
# 判据用**内容 hash 而非 mtime**：`touch` / `git checkout` 会改 mtime 却不改内容，
# 用 mtime 会既漏（内容变了但 mtime 没动）又吵（内容没变却要求重审）。
#
# 范围**只是这次要提交的文件**，不是全项目、也不是整个工作区（用户 2026-07-31 两次明确）。
# ⚠️ 两侧范围**故意不同**，别"对齐"回去：
#   · 记快照（PostToolUse）按**整个工作区**算待审全集，与 `ocr delegate preview` 的
#     workspace 模式一致 —— 那时还不知道将来会 commit 什么，只能按全集报"还有谁没审"。
#   · 查快照（PreToolUse）只按**这条 commit 真正会提交的文件** —— 见下方范围解析。
# 章绑在**文件**上（hash → path），所以两侧范围不同不会串味：审谁盖谁、提交谁查谁。
_ok_file="$repo/.claude/hooks/.review-ok"

# ── PostToolUse：命令**真的跑过**，就给它**输出的规则清单覆盖到的那些文件**记快照 ────
# ⚠️ 2026-07-31 三改：原先要求"覆盖**全部**待审文件才记，否则一个都不记"，
# **多会话并行下直接死锁**——工作区里有别人 15 个在改的文件，我只审自己 3 个 ⇒ 永不记章 ⇒
# 永远 deny；而把别人的文件一起传给 rule 来凑覆盖率，就是给没读过的代码盖章 = 假绿。
# 现在改成**覆盖谁记谁**（增量合并进快照，同 path 以新 hash 覆盖）。fail-CLOSED 的内核
# 没丢：章依然只发给**真的出现在 `Applies to:` 里**的路径，喂 `/nonexistent/x.py` 只会给
# 那个不存在的路径盖章，碰不到任何真实待审文件。
# 判据为什么是"覆盖"而不是"跑成功"（2026-07-31 实测后二改）：`ocr delegate rule` 是
# 纯"路径→规则"映射——**不读文件内容、不校验文件存在**，喂 `/nonexistent/x.py` 照样
# 吐出带 `### Rule Group`/`Applies to:` 的清单（实测）。所以"输出含判据串"只证明
# **某次 rule 跑成功了**，证明不了**审的是这批文件**——审别的、审不存在的，都能给
# 当前待审文件盖章 = fail-OPEN 换了个入口。现在解析输出里全部 `Applies to:` 段的
# `- <path>`，**给在场的那些**记快照：章绑在"被审文件列表"上，不绑在"命令成功"上。
# 不会因"某类文件没规则"假红：rule 对任何扩展名都给出规则组（无匹配的落
# system/default，实测 .sh 如此）。
# ⚠️ 有意的 fail-CLOSED 代价：`> file` / `| head` / `| grep` 会让 tool_response 缺清单
# ⇒ 那些文件盖不上章 ⇒ 审查时**别重定向/截断 rule 的输出**。一个都没盖上会明说
# （additionalContext）——无声不记的话，下次 commit 被 deny 看起来就像闸门坏了。
# 残余边界只剩：**跑了≠读了**（文件名进了命令 ≠ 按清单读过 diff）——无技术方案，靠抽查。
case "$input" in
  *'"tool_response"'*)
    # 仍要求"最近调过插件"：手动敲会跳过 command 的 Step 4（分级 + 自动修）
    _sk_ts=$(cat "$repo/.claude/hooks/.review-skill" 2>/dev/null || echo 0)
    _sk_fresh=0
    [ "$(( $(date +%s) - _sk_ts ))" -le 1800 ] && _sk_fresh=1
    _res=$(INPUT="$input" CODE="$code" OKFILE="$_ok_file" SK_FRESH="$_sk_fresh" python3 -c '
import json, os, re, subprocess, sys
try:
    d = json.loads(os.environ["INPUT"])
except Exception:
    sys.exit(0)
cmd = (d.get("tool_input") or {}).get("command") or ""
# 命令侧仍要求行首（与下方提前告知分支同口径），挡掉句中提到
if not re.search(r"(^|\n)\s*ocr\s+delegate\s+rule\b", cmd):
    sys.exit(0)
resp = d.get("tool_response")
text = "\n".join(str(v) for v in resp.values()) if isinstance(resp, dict) else str(resp)
applies, on = set(), False
for line in text.splitlines():
    s = line.strip()
    if s.startswith("Applies to:"):
        on = True
    elif on and s.startswith("- "):
        applies.add(re.sub(r"^\./", "", s[2:].strip()))
    elif s:
        on = False
todo = [re.sub(r"^\./", "", f.strip()) for f in os.environ.get("CODE", "").splitlines() if f.strip()]
if not todo:
    sys.exit(0)

def covered(f):
    # applies 里可能是绝对路径（rule 原样回显传入的路径），todo 是 repo 相对路径
    return f in applies or any(a.endswith("/" + f) for a in applies)

stamped = [f for f in todo if covered(f)]
missing = [f for f in todo if not covered(f)]
if not stamped:
    print("NONE:" + " ".join(missing))
    sys.exit(0)
if os.environ.get("SK_FRESH") != "1":
    print("STALE")
    sys.exit(0)

def hash_all(paths):
    # 与闸门侧同源：两边都用 `git hash-object`，免得 autocrlf/clean filter 让它们算出
    # 不同值（那会变成"审了也永远 deny"）。批量一次；失败逐个；再失败才记 missing
    # （与闸门侧 `|| echo missing` 同口径，删掉的文件两边都算 missing ⇒ 能匹配上）。
    try:
        o = subprocess.run(["git", "hash-object", "--"] + paths,
                           capture_output=True, text=True, timeout=30)
        hs = o.stdout.split()
        if len(hs) == len(paths):
            return hs
    except Exception:
        pass
    res = []
    for p in paths:
        try:
            o = subprocess.run(["git", "hash-object", "--", p],
                               capture_output=True, text=True, timeout=10)
            res.append(o.stdout.strip() or "missing")
        except Exception:
            res.append("missing")
    return res

okfile = os.environ["OKFILE"]
merged = {}
try:
    with open(okfile, encoding="utf-8") as fh:
        for ln in fh:
            parts = ln.rstrip("\n").split(" ", 1)
            if len(parts) == 2:
                merged[parts[1]] = parts[0]
except Exception:
    pass
merged.update(dict(zip(stamped, hash_all(stamped))))
try:
    with open(okfile, "w", encoding="utf-8") as fh:
        for p in sorted(merged):
            fh.write(merged[p] + " " + p + "\n")
except Exception:
    sys.exit(0)
print("OK:%d:%s" % (len(stamped), " ".join(missing)))
' 2>/dev/null)
    case "$_res" in
      OK:*)
        _miss=${_res#OK:*:}
        [ -z "$_miss" ] && exit 0
        M="ℹ️ 已给这次 \`ocr delegate rule\` 覆盖到的文件盖章。工作区另有**未审**文件:$_miss
不影响本次提交（闸门只看这条 commit 真正会提交的文件），但要提交它们就得先审。
多会话并行时这通常是别人的活，不用替他审。" \
        python3 -c '
import json, os
m = os.environ["M"]
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse",
      "additionalContext": m}, "systemMessage": m.split("\n")[0]}, ensure_ascii=False))
' 2>/dev/null
        exit 0 ;;
      NONE:*)
        M="⚠️ 这次 \`ocr delegate rule\` 的输出**一个待审文件都没覆盖**，快照未记。待审:${_res#NONE:}
把要提交的文件传给 rule；也别重定向/截断它的输出（\`> f\` / \`| head\` / \`| grep\` 都会让输出缺清单）。" \
        python3 -c '
import json, os
m = os.environ["M"]
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse",
      "additionalContext": m}, "systemMessage": m.split("\n")[0]}, ensure_ascii=False))
' 2>/dev/null
        exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
esac

# 见到 `ocr delegate rule` → **只提前告知**（插件窗口过期时警告）。记快照在上面的
# PostToolUse 分支——那里才拿得到输出，才分得清「执行它」和「某行恰好以它开头」，
# 也才校验得了「审的就是这批文件」（Applies to 覆盖检查）。
# ⚠️ 匹配**行首**的 ocr，不是任意位置（2026-07-31 当天两次误触发后收紧）：
# JSON 里命令的换行是字面的 `\n`，真实调用长这样 —— `"command":"cd /path\nocr delegate rule …"`。
# 而「提到它」的场合都在句中或被转义：写场景测试时内层 JSON 的引号成了 `\"command\"`、
# 往记档里写时它躺在反引号中间 —— 两者都不以行首出现。
case "$input" in
  *'\nocr delegate rule'*|*'"command":"ocr delegate rule'*|*'"command": "ocr delegate rule'*)
    # ⚠️ **必须先调过插件**：只认这条命令的话，手动敲照样放行，而手动敲正是会跳过
    # command Step 4 的那条路 —— 那等于把「近似动作」固化进机制。
    # （「提到 vs 执行」的老误报已随记快照挪去 PostToolUse 而失效：本分支只剩提示，
    #   多打一次无害；快照那侧要求**真实输出覆盖待审文件**，纯"提到"产不出来。）
    # 30 分钟窗口：一次 review 流程（preview → rule → 读 diff）不会更久；
    # 过期就当没调过，免得早上调一次、晚上还在放行。
    _sk="$repo/.claude/hooks/.review-skill"
    _sk_ts=$(cat "$_sk" 2>/dev/null || echo 0)
    if [ "$(( $(date +%s) - _sk_ts ))" -gt 1800 ]; then
      SK_MSG="⚠️ 检测到手动执行 \`ocr delegate rule\`，但最近 30 分钟内没有调用过
\`/open-code-review:delegate-review\`。**本次不计入审查**——手动敲这两条命令会跳过
command 的 Step 4（按 High/Medium/Low 分级 + 自动修 High/Medium），那正是它的价值所在。
请改用 /open-code-review:delegate-review。" \
      python3 -c '
import json, os
m = os.environ["SK_MSG"]
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
      "additionalContext": m}, "systemMessage": m.split("\n")[0]}, ensure_ascii=False))
' 2>/dev/null
      exit 0
    fi
    # 到这里说明"看起来在跑 rule 且插件窗口有效"，但**不在这里记快照**——
    # PreToolUse 只看得到命令串。记快照在 PostToolUse，判据是"输出的 Applies to
    # 覆盖全部待审文件"——光跑一条成功的 rule，盖不了别的文件的章。
    exit 0
    ;;
esac

# ── 往下只剩「闸门 + 提醒」，它们只对真正的 commit 有意义 ──────────────────────
# cheap case 也放进了「只是提到 `ocr delegate rule`」的输入（grep / 写文档 / 场景测试，
# 行中非行首 ⇒ 上面的分支都不吃）；不含 git commit 的它们走到这里就该结束——否则有
# 未审文件时会被闸门误 deny（2026-07-31 场景重验时当场撞到：一条 `ls; ocr …` 复合命令
# 被当成待提交拦下）。含 "git commit" 的仍全量过闸（含 `git add && git commit` 复合式；
# 收窄到行首会给 compound commit 开后门，宁可误拦 `echo "git commit"` 这种罕见句）。
case "$input" in
  *"git commit"*) ;;
  *) exit 0 ;;
esac

# ── 范围收窄：闸门只看**这条命令真正会提交的文件** ────────────────────────────
# （用户 2026-07-31 拍板收窄。原先按 staged ∪ unstaged 的整个工作区判，
#  **多会话并行时会被别人的文件卡死**：那天我只提交自己 4 个文件，却因并行会话
#  另外 3 个未审文件被 deny，而替别人盖章等于把闸门变假绿——两条路都不通。）
# 解析出 commit 的真实范围：
#   `git commit`                → staged（unstaged 根本不会被提交，不该拦）
#   `git commit -a`             → staged ∪ 已跟踪的修改
#   `git commit -- <pathspec>`  → 这些路径下相对 HEAD 有改动的文件（**忽略 staged 其余**）
# ⚠️ 解析不了一律**回落整个工作区**（fail-CLOSED）：宁可多拦，不可漏放。
_scope=$(INPUT="$input" python3 -c '
import json, os, shlex, sys
try:
    cmd = (json.loads(os.environ["INPUT"]).get("tool_input") or {}).get("command") or ""
    toks = shlex.split(cmd)
except Exception:
    sys.exit(0)
# 多条 commit / 认不出 → 回落（不输出）
if toks.count("commit") != 1 or "git" not in toks:
    sys.exit(0)
i = toks.index("commit")
if "git" not in toks[:i]:
    sys.exit(0)
rest = toks[i + 1:]
# 带值的选项：其后一个 token 是值，不能当 pathspec / 不能当 `--`
NEEDS_VAL = {"-m", "--message", "-F", "--file", "-C", "--reuse-message",
             "-c", "--reedit-message", "--author", "--date", "-t", "--template",
             "--cleanup", "--fixup", "--squash", "--trailer", "-S", "--gpg-sign"}
VAL_SHORT = set("mFCct")
allf, paths, skip = False, None, False
for t in rest:
    if skip:
        skip = False
        continue
    if paths is not None:
        paths.append(t)
        continue
    if t == "--":
        paths = []
        continue
    if t in NEEDS_VAL:
        skip = True
        continue
    if t.startswith("--"):
        continue
    if t.startswith("-") and len(t) > 1:
        body = t[1:]
        if "a" in body:
            allf = True
        # 短选项组合 `-am "msg"`：末位字母带值 ⇒ 下一个 token 是值
        if body and body[-1] in VAL_SHORT:
            skip = True
        continue
    # commit 后出现的裸 token（子命令拼接、shell 元字符…）⇒ 认不准，回落
    sys.exit(0)
if paths:
    # pathspec 区里混进 shell 元字符 ⇒ 后面还有别的命令，认不准，回落
    if any(p in ("&&", "||", ";", "|", ">", ">>") for p in paths):
        sys.exit(0)
    print("PATHSPEC")
    for p in paths:
        print(p)
elif paths == []:
    sys.exit(0)   # 写了 `--` 却没给路径 ⇒ 语义存疑，回落
elif allf:
    print("ALL")
else:
    print("DEFAULT")
' 2>/dev/null)

_cf=""
_scoped=0
case "$_scope" in
  DEFAULT)
    _cf=$(git -c core.quotepath=false diff --cached --name-only 2>/dev/null); _scoped=1 ;;
  ALL)
    _cf=$({ git -c core.quotepath=false diff --cached --name-only
            git -c core.quotepath=false diff --name-only; } 2>/dev/null | sort -u); _scoped=1 ;;
  PATHSPEC*)
    _cf=$(printf '%s\n' "$_scope" | tail -n +2 | tr '\n' '\0' \
          | xargs -0 git -c core.quotepath=false diff HEAD --name-only -- 2>/dev/null); _scoped=1 ;;
esac

# ⚠️ "`_cf` 空"有两种截然不同的含义，**必须分开**（2026-07-31 真实仓库验证时踩到）：
#   · 范围没解析出来（`_scoped=0`）→ 回落整个工作区，宁可多拦
#   · 范围解析出来了、里面就是没有改动（`_scoped=1` 且 `_cf` 空）→ 这条 commit 什么都不提交
# 混为一谈的后果实测过：`git commit -- CLAUDE.md`（该文件并无改动）被当成"解析失败"回落
# 全工作区，于是一个**纯 docs 提交**被工作区里别的代码文件 deny 掉 —— 而记档提交恰恰是
# 最高频的那种。测试当时没抓到，因为样本用的是"有改动的 .md"，没覆盖"pathspec 指向无改动文件"。
if [ "$_scoped" = 1 ]; then
  if [ -n "$_cf" ]; then
    code=$(printf '%s\n' "$code" | grep -xF -f <(printf '%s\n' "$_cf") 2>/dev/null)
  else
    code=""
  fi
fi
# 本次提交里没有代码文件（只提交 docs、或范围内根本没有改动）⇒ 闸门与提醒都不该出现
[ -z "$code" ] && exit 0

# ── 逃生口：`SKIP_REVIEW_GATE=1 git commit …` ────────────────────────────────
# ⚠️ 必须解析**命令串**，不能只看 `$SKIP_REVIEW_GATE`（2026-07-31 实测踩到）：
# hook 是 PreToolUse，在命令**执行之前**跑，而 `VAR=1 cmd` 的前缀只作用于随后启动
# 的那个进程 ⇒ hook 自己的环境里永远没有它。原先只判环境变量，等于这条逃生口
# **根本不存在**，而 hook 的 deny 提示还一直在教这个用法。
# ⚠️ 用 `re.match`（整条命令的最开头）而不是 `(^|\n)`：写记档、写 commit message、
# 做场景测试时都会**在行首**原样引用这行字（本次修复的 commit message 里就有）,
# 用行首锚点会把"说明它"当成"执行它" —— 自指污染的老毛病。
# 代价：`cd /x && SKIP_REVIEW_GATE=1 git commit …` 认不出（fail-CLOSED，让它 deny 就好）。
_skip="$SKIP_REVIEW_GATE"
if [ -z "$_skip" ]; then
  _skip=$(INPUT="$input" python3 -c '
import json, os, re, sys
try:
    cmd = (json.loads(os.environ["INPUT"]).get("tool_input") or {}).get("command") or ""
except Exception:
    sys.exit(0)
if re.match(r"\s*SKIP_REVIEW_GATE=\S+\s+git\s+commit\b", cmd):
    print("1")
' 2>/dev/null)
fi

# ⚠️ 固有 TOCTOU（2026-07-31 场景重验实测）：PreToolUse 在命令**执行前**看文件，
# 同一条 Bash 里"改文件 && git commit"会拿**改动前**的内容过 hash 检查 ⇒ 放行。
# 正常流程（Edit 工具改文件、commit 单独一条命令）不受影响；要堵得上 PostToolUse
# 事后比对 + 提示 revert，投入产出不成比例——记录在案，靠抽查。
if [ -e "$repo/.claude/hooks/review-required" ] && [ -z "$_skip" ]; then
  _stale=""
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    _h=$(git hash-object "$f" 2>/dev/null || echo missing)
    grep -qxF "$_h $f" "$_ok_file" 2>/dev/null || _stale="$_stale $f"
  done <<EOF_FILES
$code
EOF_FILES
  if [ -n "$_stale" ]; then
    DENY="尚未审查（或审查后又改动）的文件:$_stale

先跑 /open-code-review:delegate-review（前两步不调 LLM、零 API 费），
它第 2 步 \`ocr delegate rule <files>\` 给出的**外部规则清单**正是自己读 diff 看不到的维度。
跑过之后本闸门会自动放行；文件再被改动则需重审。闸门只看**这条 commit 会提交的文件**，
多会话并行时别人的未审文件不会卡住你（也别替他审——那等于给没读过的代码盖章）。
确需跳过：SKIP_REVIEW_GATE=1 git commit ...（**必须整条命令行首起句**，会留在 shell 历史里便于抽查）" \
    python3 -c '
import json, os
d = os.environ["DENY"]
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": d,
    },
    "systemMessage": "⛔ 审查闸门:" + d.split("\n")[0],
}, ensure_ascii=False))
' 2>/dev/null
    exit 0
  fi
fi

n=$(printf '%s\n' "$code" | wc -l | tr -d ' ')
head3=$(printf '%s\n' "$code" | head -3 | tr '\n' ' ')

# ⚠️ **必须输出 JSON，裸 echo 到不了 agent 手里**（2026-07-31 实测）：PreToolUse 在
# exit 0 时属于"静默成功"，stdout 既不进模型上下文也不显示，于是这个 hook 会每次
# 都跑、每次都算出结果、再把结果丢掉——一整个会话 13 次 commit 全程无声。
# 用 sentinel 文件才验证出它其实一直在跑。想让 agent 看见只有 additionalContext，
# 想让人看见只有 systemMessage，两个都给。
# ⚠️ **只给一条路,不给"或手动"**（2026-07-31 用户第三次纠正同一个模式）：
# 文案原本写「/open-code-review:delegate-review；**或手动**：ocr delegate preview → …」，
# 于是我每次都选了手动那条——它看起来等价，实际**跳过了 command 的 Step 4**
# （按 High/Medium/Low 分级 + 自动修 High/Medium）。
# **给出近似选项，近似选项就会被选中**：这和「跑了测试」吸收掉「审一遍」是同一个毛病，
# 差别只在这次是提示文案自己把捷径递到手上。手动命令仍写在 command 定义里，
# 需要时看得到，但不在这里当成并列选项。
MSG="🔍 这次 commit 动了 ${n} 个代码文件（${head3}…）——提交前跑：
   /open-code-review:delegate-review
   （插件命令，前两步不调 LLM、零 API 费；它会给出外部规则清单并要求按 High/Medium/Low 分级。
     别用「我自己读一遍 diff」代替——那只看得到你想得到的维度。只改 ${skip_note}。）"
MSG="$MSG" python3 -c '
import json, os
m = os.environ["MSG"]
print(json.dumps({
    "hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": m},
    "systemMessage": m,
}, ensure_ascii=False))
' 2>/dev/null
exit 0
