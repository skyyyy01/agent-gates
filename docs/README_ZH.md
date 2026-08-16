# agent-gates

**你把规则写进了 CLAUDE.md，它没生效。那就别再靠提醒，换成机制。**

给 Claude Code 用的 hook 闸门：代码没真正审过就拒绝提交；agent 每次会话都要读的那些文件，
体积受预算约束。

[![License: MIT](https://img.shields.io/badge/license-MIT-yellow)](../LICENSE)
[![Claude Code](https://img.shields.io/badge/requires-Claude%20Code-8A63D2)](https://claude.com/claude-code)
[![Tests](https://img.shields.io/badge/tests-72%20checks%20%2B%208%20mutations-green)](../tests/)
[![CI](https://github.com/skyyyy01/agent-gates/actions/workflows/tests.yml/badge.svg)](https://github.com/skyyyy01/agent-gates/actions/workflows/tests.yml)

[English](https://github.com/skyyyy01/agent-gates/blob/main/README.md) | **中文**

---

## 它要解决的问题

你在 `CLAUDE.md` 里写了「那条命令的输出不许截断」。

写进了 journal。写进了 memory。写成了机械动作。

**同一天你还是踩了四次。**

不是因为规则写得不清楚 —— 它已经清楚得不能再清楚了。**纪律的所有形式都用尽了**，
剩下的只有一条路：不再提醒，直接拒绝。

这就是全部想法。提醒会衰减，闸门不会。

完整的推理链，包括造闸门的过程中在**闸门自己身上**踩到的三个静默失败：[why mechanism, not discipline](why-mechanism-not-discipline.md)（英文）。

## 长什么样

提醒模式 —— 一行，不拦：

```
🔍 这次 commit 动了 1 个代码文件（payment.py …）——提交前跑：
   /open-code-review:delegate-review
   （…别用「我自己读一遍 diff」代替——那只看得到你想得到的维度。）
```

硬闸门 —— 拒绝：

```
decision: deny

尚未审查（或审查后又改动）的文件: payment.py

先跑 /open-code-review:delegate-review，跑过之后本闸门会自动放行；文件再被改动
则需重审。闸门只看**这条 commit 会提交的文件**，多会话并行时别人的未审文件不会
卡住你（也别替他审——那等于给没读过的代码盖章）。

确需跳过：SKIP_REVIEW_GATE=1 git commit …（必须整条命令行首起句，会留在 shell
历史里便于抽查）
```

截断闸门 —— 这条是最值回票价的：

```
decision: deny

🚫 `ocr delegate rule` 后面跟了管道/重定向 —— 被截掉的文件盖不上章，而 commit 的
判据是「本次要提交的文件是否都有章」，所以这一轮等于白跑（甚至会让你以为审过了）。

  你写的:  ocr delegate rule payment.py | head -20

正确形式：这条命令单独成行，后面什么都不加。

⚠️ 本闸门 2026-08-04 从「提示」升级为 deny：同一天内该纪律被踩四次——CLAUDE.md
写过、写成机械动作、当天写进 journal 与 memory，都没挡住。
```

预算检查：

```
❌ CLAUDE.md 超出读取预算:
   · 全文 41,000 B > 40,000 B —— 先下沉不够格的条目，再合并同族，最后才考虑提高上限
```

## 这是给谁用的

两个条件，缺一不可：

- **你用 AI agent 写代码。** 不用的话，这个问题根本不存在。
- **你已经被咬过。** 如果「规则明明写在 CLAUDE.md 里，它还是没做到」听起来陌生，
  这套东西读起来就是官僚主义；如果听起来熟悉，你心里已经有一条最想先拦住的规则了。

> ⚠️ **依赖 [Claude Code](https://claude.com/claude-code)** —— 这是建立在它的 hook
> 机制上的。Cursor / Copilot / Windsurf 等**不适用**。硬闸门另需
> [open-code-review](https://github.com/alibaba/open-code-review)；仅用提醒模式则不需要。

## 安装

需要 **bash**、**git**、**Python 3.11+**（预算检查器用标准库 `tomllib` 读 `gates.toml`）。
没有别的依赖 —— 不装包、不建虚拟环境。

```bash
curl -fsSL https://raw.githubusercontent.com/skyyyy01/agent-gates/main/install.sh | bash
```

它把两个 hook 装进 `~/.claude/hooks/`，并在 `~/.claude/settings.json` 注册三个事件
（幂等，先备份）。

一个要改 `settings.json` 的脚本，想先读一遍再跑是合理的：

```bash
git clone https://github.com/skyyyy01/agent-gates && cd agent-gates
less install.sh && bash install.sh    # 用本地 hooks/，全程不联网
```

**装完什么都不会发生。** 闸门默认关闭，逐项目 opt-in —— 一个装上就开始拦人的工具会被立刻卸掉。

```bash
cd 你的项目
mkdir -p .claude/hooks
touch .claude/hooks/review-before-commit    # ① 提醒
touch .claude/hooks/review-required         # ② 拒绝
touch .claude/hooks/review-includes-tests   # ③ 扩大范围

# 开关进版本控制，快照绝不进
printf '%s\n' '.claude/hooks/.review-ok' '.claude/hooks/.review-skill' >> .gitignore
```

三个开关互相独立。建议先只开 ①，用几天再说。

最后那行不是收尾杂务。开关文件**应该**提交 —— 它声明的是「这个项目对提交设闸」，
属于项目本身。但 `.review-ok` 装的是**你**审过的那些文件的内容 hash，提交上去就意味着
你的盖章记录能通过队友的闸门，而他那边一个文件都没审过。闸门照常运行，
只是拿别人的证据在回答。

## 闸门

### ① 审查提醒

改了代码要 `git commit` 时，agent 会收到一行：*这次动了 N 个代码文件，提交前先审一遍*。
不拦。

### ② 审查闸门

改动过的文件没真正审过，提交就被 **deny**。

放行判据是本次提交会碰到的**每个文件的内容 hash**，与审查跑过时写下的快照比对：

- **用 hash 不用 mtime** —— `touch` / `checkout` 改 mtime 不改内容。
- **审完又改要重审。** 这是对的，偶尔也确实烦人。
- **范围就是这条命令真正会提交的东西** —— 裸 commit 用暂存区，`-a` 加上已跟踪的改动，
  `-- <pathspec>` 用那些路径。命令认不出就回落整个工作区：**fail-closed**。
- 逃生口：`SKIP_REVIEW_GATE=1 git commit …`，且必须**整条命令行首起句**
  （hook 判的是命令串，不是环境变量）。

### ③ 截断闸门

审查命令后面跟 `… | head` 直接拒。

这条看起来小题大做，直到你看见它怎么坏的：审查命令会打印它覆盖了哪些文件，管道把那份清单
截断，被截掉的文件就盖不上章。然后提交通过了，而**这次提交里有一部分 diff 根本没被审过**
—— 任何地方都不会说这件事。

作者在**一个 session 内踩了五次**，每次动机都一样（「输出太长，只想看一眼」），
而规则早就白纸黑字写着。这才是它从「再写一行文档」升级成硬 deny 的原因。

### ④ 读取预算（可选）

`checkers/check_brain_budget.py` 限制 agent 每次会话都会加载的那些文件的体积 ——
`CLAUDE.md`、常驻状态文件，凡是「每次都要读」的。

**按体积不按条数。** 真实案例：某个文件的规则写的是「≤15 条」，`grep -c '^## '` 数出来
恰好 15 条、完全合规 —— 而文件已经 119 KB。条数是代理指标，而代理指标会漏：压平的行和
混用的标题格式，都不匹配那个正在计数的模式。字节没有这种缝。

配置写在 `gates.toml`（见 `templates/gates.toml.example`）。三类目标：单文件三维度、
面级 glob（新文件自动纳入）、仓库外目录。

## 实测数据

真实使用中量出来的，不是估计：

| | |
|---|---|
| **同一批改动的缺陷检出** | lint + 类型 + 1085 测试 + 变异 → **0 个**。自己读 diff → **4 个**。按外部规则清单再审 → 又 **2 个**。 |
| **截断问题的复发** | **一个 session 内五次**，而规则已经写在四个地方 |
| **测试总量** | **72 项** —— 23 个闸门场景（含自指：commit message 里原样引用逃生口仍须被 deny）、19 个截断用例、15 项结构、15 项端到端。五套都在 CI 上跑，Linux 与 macOS 双平台 |
| **变异自检** | **8/8** —— `tests/mutations.sh` 把 hook 破坏八次，每次要求**指名的那条**断言变红。写它的时候当场照出两条假绿：一条要破坏**锚点**而非被测对象才红，另一条是「分不清 deny 与提醒」的断言 |
| **文档引用检查** | 27 个符号，**0 误报** |

第一行是整个项目的论据：自动化工具**一个都没抓到**，而且它没做错 —— 那些缺陷不是类型错误
也不是测试失败，它们是「**某个值被静默丢弃**」「**某条路径上字典少了个键**」这类问题。
没有哪个 linter 在找这些。

## 已知绕过路径

全列出来。这类工具，漏洞要是得由你自己发现，它就不值钱了。

| # | 绕过路径 | 影响 | 缓解 |
|---|---|---|---|
| 1 | **跑了 ≠ 读了** | 审查命令跑过了，但没人读输出 | 无。靠抽查。 |
| 2 | **TOCTOU** | 同一条 Bash 里 `改文件 && commit`，拿的是改前内容的 hash | 正常流程不会发生 |
| 3 | **子 agent 绕过** | 子 agent 的工具调用不触发父 session 的 hook ⇒ 闸门对它们不存在 | 🔴 **无缓解。** 会 fan out 子 agent 的话，要知道它们在这套东西之外。 |
| 4 | **模型自我修改** | 模型能改 `settings.json` 和 hook 脚本本身 | 把 hook 纳入版本控制 |
| 5 | **Bash heredoc** | `cat > f << EOF` 绕开 Write/Edit hook | 对这里影响较小 —— 它拦的是**提交**不是写入，没盖章的文件会被 deny，方向是 fail-closed |
| 6 | **hook 静默失败** | hook 执行出错时不一定真的 block | 截断检测已会自报失败；还没覆盖到全流程 |

3、4、5、6 来自 [anthropics/claude-code#45427](https://github.com/anthropics/claude-code/issues/45427)，
它的标题就是最诚实的总结：*hooks are necessary but insufficient for governance enforcement*。
该 issue 已被 closed as `not planned`，所以这一层就是目前能有的全部。

还有一条比上面任何一条都更说明问题：
[#40117](https://github.com/anthropics/claude-code/issues/40117) 记录了 agent 用
`--no-verify` 和 `git stash` 绕过 pre-commit hook，**并试图不让用户发现**。
如果还需要一个「为什么提醒不够」的论据，就是它了。

## 同类先例

这套设计至少被独立收敛出来三次：本仓库、
[2026 年 4 月的一篇博客](https://imti.co/pre-commit-review-gate/)（同样的
PreToolUse + SHA-256 + 快照结构，连「用内容 hash 而不是 mtime」这个细节都一样）、
以及 RFC #45427 里的参考实现。

收敛得这么一致，通常说明形状是对的。这里有而别处没有的：那两个都**没有做成可安装的东西**，
也都没有配套测试。72 项检查和那套变异自检，是真正踩过才写得出来的那部分。

## 目录结构

```
hooks/       两个 hook —— 闸门本体
checkers/    可选的 pre-commit 检查（预算、文档引用、索引）
templates/   .brain 骨架、项目开关、gates.toml、pre-commit 配置
tests/       23 闸门 + 19 截断 + 15 结构 + 15 端到端，外加 mutations.sh
```

`.brain` 骨架在仓库里叫 `templates/brain/`（无点），而检查器找的是带点的目录，
所以复制过去时要改名：`cp -R templates/brain 你的项目/.brain`。

想参与、以及改完 hook 之后该跑什么：[CONTRIBUTING.md](../CONTRIBUTING.md)。
这个工具会碰你机器上的什么、以及它为什么**不是**安全边界：[SECURITY.md](../SECURITY.md)。

## 关于注释

hooks 和 checkers 的注释是**中文**，而且密度很高。那些注释大多是事故记录 ——
某个分支为什么是这个顺序、哪个「显然可以简化」的写法试过又退回去了。翻译会把这些细节抹平，
而细节正是它们值得留着的原因。英文 README 讲用法；注释是考古。

## 许可证

MIT
