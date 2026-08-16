#!/usr/bin/env python3
"""常驻记忆文件的读取预算闸门(pre-commit)。

为什么按**体积**而不是按条数:CLAUDE.md 原本写的是「≤15 条」,2026-07-29 实测
`grep -c '^## '` 恰好 15 条、完全合规,文件却已 119 KB —— 条数达标是假象,膨胀
从两条缝里溢出来:

1. **压平行**:归档做了一半(把旧条目压成单行)却没搬走,11 条压平行 74 KB 留在
   文件里。它们不以 `## ` 开头,条数统计根本数不到。
2. **格式混用**:`更新于: 日期(...)` 这种旧式分节也不以 `## ` 开头,其正文被算进
   了上一条,让单条看起来有 17 KB。

条数是可绕过的代理指标,体积和行长才是真实成本。这个闸门直接卡后者。

维度(任一超标即 fail):
  - 单行字节:压平行的特征,也是人和 AI 都读不动的形态
  - 单条字节:防某一条(如自动落库的分析全文)独吞预算
  - 文件总字节:固定读取预算 —— 先出后进,加新条目前先归档最老的

2026-07-30 从「只管 current.md」扩到多目标。起因:实测发现闸门管的是 48 KB 的
current.md,却**不管** 25 KB 的 CLAUDE.md 和 12 KB 的 MEMORY.md(这两个才是每个
session 必吃的 always-loaded 常驻区),也不管 47.6 KB 的 triggers.md(其中「B. 研究
重启类」单节 31.6 KB、最长的单个触发器 5.7 KB)。机制发明出来治一个文件,从没迁移
到其他载体 —— 正是 [[feedback_rules_must_migrate_to_new_carriers]] 那条。

⚠️ **`~/.claude/.../memory/` 在 git 仓库外,pre-commit 够不着**(git 会报
"outside repository")。它只能靠 `--include-external` 手动跑,不是强制闸门。
别以为提交时它被检查过。

⚠️ **本闸门有意 * 不 * 上 CI**(两轮自审后的定论,别再"补"上去)。
诉求本身是真的:pre-commit 这道 `--no-verify` 能无痕绕过,而文档类改动通常命中
CI 的 paths-ignore ⇒ 绕过之后没有第二道会发现。但两个候选载体都被否掉:
  ① **塞进现有的部署流水**:①仍然触发不到 docs-only 的 push(问题原样存在)
     ②却会让"记忆文件多写一行"把**生产部署**卡住(test 红 → deploy 被 needs 挡)。
     用一道防"文档写太多"的闸门去换部署停摆的风险,收益和代价完全不成比例。
  ② **独立 workflow**(真写过、又删了):它确实两头都对,但**吃 CI 配额** ——
     记忆文件是高频改动对象(作者仓库近 30 天有 **525 个 commit** 触碰这三个文件),
     而配额耗尽 = **所有** workflow 一起停,包括真正重要的那几个。
⇒ **现存两道**:pre-commit(提交那一刻就红,是主力)+ 一个守**结构**不守体积的单测
(配置里的文件必须真实存在、三个维度各自能红、pre-commit 的 `files:` 正则必须盖住
每个仓内目标 —— 它防的是**闸门自己坏掉**,零配额且不随内容变化)。
诚实边界:`--no-verify` 仍然绕得过。这是**权衡后接受的残余风险**,不是没想到。

归档要求(闸门测不了,靠 CLAUDE.md 纪律):搬走时必须在「📦 更早」小节留一行
摘要 + 指针,降分辨率而不是断链。
"""

from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path


import subprocess

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11
    raise SystemExit("需要 Python 3.11+（tomllib 是内置模块）")


# ── 仓库根 ────────────────────────────────────────────────────
# ⚠️ **不能用 `Path(__file__).resolve().parents[1]`** —— 那只在「脚本就住在被检查的
# 仓库里」时成立。本工具的 checkers 是被**别的**仓库引用的(pre-commit 指过来),
# `__file__` 指向 agent-gates 自己 ⇒ 会跑去 agent-gates 里找用户的 CLAUDE.md、
# 一个都找不到 = **闸门空转且全绿**。这正是本工具专治的那种 fail-OPEN,
# 而它差点长在工具自己身上。
#
# ⚠️ 也不能直接用 `Path.cwd()`:glob 从别的 cwd 跑会零命中,而零命中会被报成
# 「闸门空转」= 假红(原实现的注释里记着:`cd /tmp` 后跑就复现)。
# ⇒ 用 git 自己的答案,拿不到才回落 cwd。
def _repo_root() -> Path:
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=True,
        )
        return Path(out.stdout.strip())
    except Exception:
        return Path.cwd()


_REPO_ROOT = _repo_root()

CONFIG_NAME = "gates.toml"


def _load_config(explicit: str | None = None) -> dict:
    """读 `gates.toml`。找不到 ⇒ 返回空 dict,由调用方明说「什么都没查」。

    ⚠️ **故意不内置任何默认目标**:内置默认会让「忘了写配置」和「配置说这些就够了」
    在输出上完全同形。没有目标就是没检查,必须说出来 —— 这条规则本身就是这个工具存在的理由。
    """
    path = Path(explicit) if explicit else _REPO_ROOT / CONFIG_NAME
    if not path.is_file():
        return {}
    with path.open("rb") as fh:
        return tomllib.load(fh)


def _kb(d: dict, key: str, default: int | None = None) -> int | None:
    """配置里一律写 KB(人读的单位),内部一律用字节(比较的单位)。"""
    v = d.get(key)
    # ⚠️ 必须 round 不能 int:TOML 里的小数上限是 float,而 `int()` 向下取整会在浮点
    # 表示偏低时凭空吃掉 1 字节 ⇒ 刚好卡在上限的合规文件被报成超标 = **假红**
    # (假红比假绿更贵:它会让人去「修」本来正确的东西)。
    # 实测一位小数 0.1–99.9 共 999 个值,`int` 与 `round` 分歧的有 **4 个**:
    # 32.3 / 64.1 / 64.6 / 65.1 KB —— 都是少 1 字节。
    # ⚠️ 这条注释的第一版举的例子是 `76.3`,**实测不成立**(int 和 round 都得 76300)。
    # 写注释时顺手编的"典型值"没验证过;例子必须是跑出来的,否则后人核对时对不上,
    # 会连带怀疑整条规则。
    return default if v is None else round(v * 1000)


def _budgets_from(cfg: dict) -> tuple[Budget, ...]:
    out: list[Budget] = []
    for i, b in enumerate(cfg.get("budget", [])):
        if "path" not in b:
            raise SystemExit(f"❌ gates.toml: [[budget]] 第 {i + 1} 条缺 path")
        out.append(
            Budget(
                path=Path(b["path"]),
                max_file=_kb(b, "max_file_kb", 0) or 0,
                max_entry=_kb(b, "max_entry_kb", 0) or 0,
                max_line=_kb(b, "max_line_kb", 0) or 0,
                line_hint=b.get("line_hint", ""),
                entry_hint=b.get("entry_hint", ""),
                file_hint=b.get("file_hint", ""),
                external=bool(b.get("external", False)),
                max_lines=b.get("max_lines"),
            )
        )
    return tuple(out)


CONFIG: dict = {}
BUDGETS: tuple[Budget, ...] = ()
GLOB_BUDGETS: tuple[tuple[str, int], ...] = ()      # (glob, max_file)
EXTERNAL_DIRS: tuple[dict, ...] = ()                # {path, glob, max_file, exempt}


def _apply_config(cfg: dict) -> None:
    """把配置摊平成模块级常量 —— 保持下方函数的写法与原实现一致。"""
    global CONFIG, BUDGETS, GLOB_BUDGETS, EXTERNAL_DIRS
    CONFIG = cfg
    BUDGETS = _budgets_from(cfg)
    GLOB_BUDGETS = tuple(
        (g["pattern"], _kb(g, "max_file_kb", 0) or 0)
        for g in cfg.get("glob_budget", [])
        if "pattern" in g
    )
    EXTERNAL_DIRS = tuple(
        {
            "path": Path(d["path"]).expanduser(),
            "glob": d.get("glob", "*.md"),
            "max_file": _kb(d, "max_file_kb", 0) or 0,
            # 例外**必须带理由** —— 没有「什么时候撤销」的例外会让这张表变成垃圾桶,
            # 几轮之后就没人知道每条为什么在这儿。加新条目前先问:是这个文件真有正当
            # 理由,还是我在迁就一个压不下去的数字?后者该去压内容,不是来加例外。
            "exempt": {
                k: (int(v["max_kb"] * 1000), v.get("reason", ""))
                for k, v in (d.get("exempt") or {}).items()
            },
        }
        for d in cfg.get("external_dir", [])
        if "path" in d
    )



@dataclass(frozen=True)
class Budget:
    """一个常驻文件的读取预算。

    三个上限的**语义随文件结构而变**,提示语因此也各写各的:
    current.md 的「条」是 `## ` 分节、「行」是散文行(长行=压平行);
    triggers.md 的「条」是类别、「行」是**一个触发器**(表格行,长行=依据列
    塞了论证全文);CLAUDE.md 的「条」是章节。
    """

    path: Path
    max_file: int
    max_entry: int
    max_line: int
    line_hint: str
    entry_hint: str
    file_hint: str
    external: bool = False  # git 仓库外 ⇒ pre-commit 管不到,仅手动检查
    # ⚠️ **行数维度**(2026-08-08 加,给 skill 用):两个 SKILL.md 的预算是**用行数写的**
    # (「≤1000 行」「≤260 行」这种),而本脚本原本只量字节。改文字去迁就脚本会让
    # 历史引用漂移 ⇒ **让机制匹配已有的字**,而不是反过来。None = 不查这一维。
    max_lines: int | None = None



def check_glob_budget(pattern: str, max_file: int, root: Path | None = None) -> tuple[list[str], str]:
    """一个 glob 面下所有文件的单文件体积(面级,新增文件自动纳入)。

    为什么要有面级而不是逐个点名:逐个加 Budget 是**载体层**写法,下次新增一个文件又漏。
    真实教训:上午刚给三个文件装了闸门,当天下午往同目录搬内容时才发现**另外 5 个
    文件一个都没设防** —— 膨胀立刻找到了没设防的出口。

    ⚠️ **排除已有专属 `Budget` 的文件**:两套规则管同一个文件、上限还不同 ⇒ 必然有一个
    在说谎。首版没排,当场把两个有专属上限(42 KB / 37 KB)的文件报成「超 24 KB」=
    **自己造的假红**。专属 Budget 的数字是按各自实际内容定的,面级这条只兜底**没人管**的。
    """
    base = root or _REPO_ROOT
    budgeted = {(base / b.path).resolve() for b in BUDGETS if not b.external}
    files = [p for p in sorted(base.glob(pattern)) if p.resolve() not in budgeted]
    if not files:
        # ⚠️ **一个都没匹配到要出声**:glob 静默零命中 = 这道闸门等于不存在,
        # 而它和「全都合格」在输出上同形。
        return [f"❗ `{pattern}` 一个文件都没匹配到 —— 路径变了?这道闸门当前是空转的"], ""
    errors = [
        f"{f.relative_to(base)} {f.stat().st_size:,} B > {max_file:,} B —— "
        "这类文件是**按需读**的,但一份超限的参考等于没人会读完;"
        "先把最老的条目压成索引或搬进流水文件"
        for f in files
        if f.stat().st_size > max_file
    ]
    biggest = max(files, key=lambda p: p.stat().st_size)
    return errors, (
        f"{len(files)} 份 / 共 {sum(f.stat().st_size for f in files):,} B / "
        f"最大 {biggest.name} {biggest.stat().st_size:,} B(上限 {max_file:,})"
    )


def check_external_dir(spec: dict) -> tuple[list[str], str]:
    """仓库外目录下每个文件的体积。⚠️ 仓库外 ⇒ pre-commit 够不着,只能手动跑。"""
    d, glob, max_file = spec["path"], spec["glob"], spec["max_file"]
    exempt: dict[str, tuple[int, str]] = spec["exempt"]
    if not d.is_dir():
        return [], f"跳过: {d} 不存在"
    files = sorted(d.glob(glob))
    if not files:
        # 与面级同理:零命中不能静默
        return [f"❗ `{d}/{glob}` 一个文件都没匹配到 —— 这道检查当前是空转的"], ""
    total = sum(f.stat().st_size for f in files)
    errors: list[str] = []
    exempt_used: list[str] = []
    for f in sorted(files, key=lambda p: -p.stat().st_size):
        n = f.stat().st_size
        limit, why = exempt.get(f.name, (max_file, ""))
        if n <= limit:
            if why and n > max_file:
                exempt_used.append(f"{f.name} {n:,} B(例外上限 {limit:,})")
            continue
        errors.append(
            f"{f.name} {n:,} B > {limit:,} B —— "
            + (
                f"**已有例外仍然超标**,例外理由:{why[:80]}… ⇒ 要么压内容,要么这条例外本身该重审"
                if why
                else "一个文件一个 fact;把已结案的流水移进日志或 ADR,这里只留「现在还成立的结论 + 指针」"
            )
        )
    if exempt_used:
        # 例外不是错,但必须**可见** —— 静默放过等于没有例外表
        print(f"   · 用到例外: {'; '.join(exempt_used)}")
    return errors, (
        f"{len(files)} 个文件 / 共 {total:,} B / 最大 {max(f.stat().st_size for f in files):,} B"
    )



def check(b: Budget) -> tuple[list[str], str]:
    """返回 (错误列表, 一行摘要)。"""
    raw = b.path.read_bytes()
    lines = b.path.read_text(encoding="utf-8").split("\n")
    errors: list[str] = []

    # 1) 单行过长
    for i, line in enumerate(lines, 1):
        n = len(line.encode())
        if n > b.max_line:
            errors.append(f"L{i}: 单行 {n:,} B > {b.max_line:,} B —— {b.line_hint}")

    # 2) 单条过大(第一个 ## 之前的头部不计)
    entries: list[tuple[str, int]] = []
    title, size = "", 0
    for line in lines:
        if line.startswith("## "):
            if title:
                entries.append((title, size))
            title, size = line[3:], 0
        if title:
            size += len(line.encode()) + 1
    if title:
        entries.append((title, size))

    for entry_title, entry_size in entries:
        if entry_size > b.max_entry:
            errors.append(
                f"条目「{entry_title[:40]}」{entry_size:,} B > {b.max_entry:,} B —— {b.entry_hint}"
            )

    # 3) 文件总量 = 固定读取预算
    if len(raw) > b.max_file:
        errors.append(f"全文 {len(raw):,} B > {b.max_file:,} B({len(entries)} 条)—— {b.file_hint}")

    # 4) 行数(只有 skill 用 —— 它们的预算是用行数写的,见 Budget.max_lines 注释)
    # ⚠️ **不能用 `len(lines)`**:`split("\n")` 对以换行结尾的文件会多出一个空串,
    # 报出的行数比 `wc -l` 大 1 ⇒ 贴着上限时会假红一次,而假红比假绿更容易让人
    # 去"修"一个本来合规的文件([[gotcha_verifier_itself_is_wrong]])。
    n_lines = len(raw.splitlines())
    if b.max_lines is not None and n_lines > b.max_lines:
        errors.append(f"全文 {n_lines:,} 行 > {b.max_lines:,} 行 —— {b.file_hint}")

    longest = max((len(x.encode()) for x in lines), default=0)
    summary = (
        f"{len(raw):,} B / {len(entries)} 条 / 最长行 {longest:,} B"
        + (f" / {n_lines:,} 行(上限 {b.max_lines:,})" if b.max_lines else "")
        + f"  (上限 {b.max_file:,}/{b.max_entry:,}/{b.max_line:,})"
    )
    return errors, summary


def main(argv: list[str]) -> int:
    include_external = "--include-external" in argv
    cfg_path = None
    if "--config" in argv:
        cfg_path = argv[argv.index("--config") + 1]
    named = [a for a in argv if not a.startswith("-") and a != cfg_path]

    _apply_config(_load_config(cfg_path))

    if not BUDGETS and not GLOB_BUDGETS and not EXTERNAL_DIRS:
        # ⚠️ 没有目标 = **什么都没检查**,绝不能和「全部合格」长得一样。
        # 退出码给 0(用户还没配置不算失败),但必须让人一眼看出闸门没生效。
        print(f"⚠️ 未找到 {CONFIG_NAME}(或其中没有任何目标)—— **本次什么都没检查**。")
        print(f"   把 gates.toml.example 复制成 {CONFIG_NAME} 并按你的仓库改写。")
        return 0

    if named:
        # pre-commit 传具体文件名 ⇒ 只查这些(仓库外目标不会被传进来)
        wanted = {Path(n).resolve() for n in named}
        targets = [b for b in BUDGETS if b.path.resolve() in wanted]
    else:
        targets = [b for b in BUDGETS if include_external or not b.external]

    failed = False
    for b in targets:
        if not b.path.exists():
            if b.external:
                print(f"跳过: {b.path} 不存在(仓库外)")
                continue
            # ⚠️ **仓内文件缺失 = 闸门什么都没检查**,不能当成通过。
            # 原来这里也只打印「跳过」+ 最终 return 0 ⇒ 把常驻文件改名/搬走之后,
            # 闸门**全绿**,与「检查过且合格」在输出上难以区分。
            failed = True
            print(f"❌ {b.path} 在 {CONFIG_NAME} 里登记着却不存在 —— 路径写错了,或文件搬了而没跟")
            continue
        errors, summary = check(b)
        if errors:
            failed = True
            print(f"❌ {b.path} 超出读取预算:")
            for e in errors:
                print(f"   · {e}")
        else:
            print(f"✅ {b.path}: {summary}")

    # 面级检查。⚠️ **不受 `named` 限制**:pre-commit 传的是本次改动的文件名,而这道闸门
    # 管的是「这个面里有没有谁超标」—— 只在改到面内文件时才查,等于给「改 A 撑大 B」
    # 留了口子(而搬迁恰恰是从 A 搬到 B)。
    for pattern, max_file in GLOB_BUDGETS:
        if named and not any(Path(n).match(pattern) for n in named):
            continue
        errors, summary = check_glob_budget(pattern, max_file)
        if errors:
            failed = True
            print(f"❌ {pattern} 超出单文件预算:")
            for e in errors:
                print(f"   · {e}")
        elif summary:
            print(f"✅ {pattern}: {summary}")

    if include_external and not named:
        for spec in EXTERNAL_DIRS:
            errors, summary = check_external_dir(spec)
            if errors:
                failed = True
                print(f"❌ {spec['path']}/{spec['glob']} 超出单文件上限:")
                for e in errors:
                    print(f"   · {e}")
            else:
                print(f"✅ {spec['path']}/{spec['glob']}: {summary}")

    if not include_external and (EXTERNAL_DIRS or any(b.external for b in BUDGETS)) and not named:
        print(
            "注: 配置里有仓库外目标,pre-commit 够不着 —— "
            "用 `--include-external` 手动查(不是强制闸门)"
        )
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
