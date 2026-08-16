#!/usr/bin/env python3
"""校验 CLAUDE.md / .brain 文档里**引用的东西是否真实存在**。

## 为什么要有它

CLAUDE.md 是每个 session 的**唯一入口**,里面一个错误的引用不是「文档不准」,
是**下一个 session 基于错误信息行动**。2026-07-29 实际踩到:CLAUDE.md 写着
读 parquet 用 `_read_parquet_retry`,而真名是 `read_parquet_retry`(无下划线前缀)
—— 照着 grep 必然找不到,我当时一度以为这个机制根本不存在。

## 为什么只查符号,不查路径(重要)

第一版把路径也查了:72 个路径引用报出 22 个「坏」,**实际几乎全是误报** ——
模板占位符(`NNNN-xxx.md`/`YYYY-MM-DD.md`)、斜杠命令(`/kill`、`/cone`)、
相对 `.brain/` 或 `src/` 的短路径。

**一个吵闹的检查会被 `--no-verify` 绕过,最终等于没有** —— 那比没有还糟,
因为它会训练人跳过整组 pre-commit。所以这里只做**信噪比可靠**的那一维:
代码符号(`module.SYMBOL` / `snake_case` 标识符)。实测 20 个符号全部命中,
误报 0;而它恰好覆盖了真正咬人的那类错误(函数改名 / 名字写错)。

路径检查留待有人能把占位符与真路径可靠区分时再加 —— 在那之前,不加。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# 扫这些文档里的符号引用
# 默认只查 CLAUDE.md —— 这是**任何** Claude Code 项目都有的入口文件,搬去别的仓库
# 零配置即可用。本项目的第二个入口(威胁模型)由 pre-commit 的 args 传入,见 main()。
TARGETS = ["CLAUDE.md"]

# 在这些地方找符号
SEARCH_DIRS = ["src", "tests", "scripts", "ops", ".github", "docker-compose.yml", "Dockerfile"]

# ⚠️ **变异清单必须排除** —— `scripts/probes/*.json` 里装的正是「故意写错的名字」
# (`test_socket_proxy_readonly_bogus_name` 之类)。它们躺在语料里 ⇒ 每个 bogus 名字都
# 「找得到」⇒ 变异 4/4 全假绿。**用来测这个错误的数据,本身含有这个错误** ——
# 与 v1 那次(本文件 docstring 污染语料)同源,一天之内第三次。
EXCLUDE_DIRS = {"probes", "__pycache__"}

# 反引号里:`a.B` / `a.b.C`(任意段数)或 `snake_case`(至少一个下划线,避免抓到普通英文单词)
# ⚠️ 第二个分支必须允许**前导下划线** —— Python 私有函数全是 `_xxx`,而本脚本的
# 立项案例(`_read_parquet_retry`)正是这种形态。第一版写成 `[a-z]` 开头 ⇒
# **抓不到自己的立项案例**,变异探针 M1 当场照出假绿。
# ⚠️ 点号分支必须是 `(?:\.…)+` 而不是只认**两段**(2026-07-30 修):原来写死一个 `\.`,
# 于是 `quant.execution.oms.some_symbol` 这种完整路径**整体不匹配**、被无声跳过 ——
# 我给它做参数化时随手写了个四段假符号当变异,结果"全部命中"、exit 0,才发现这条缝。
# 实测当时 CLAUDE.md 与威胁模型里 ≥3 段引用**恰好是 0 个**(所以是潜在漏检、非现存漏洞),
# 但把完整模块路径写进文档是最自然的引用方式,迟早会踩。段数与信噪比无关,两段可靠
# ⇒ 多段一样可靠,不存在"放宽会变吵"的取舍。
# ⚠️ **`[[wiki 链接]]` 形式故意不在此检查**(2026-07-31 外审 §八问出、主线裁决):
# 本项目的 `[[name]]` 是**软链接语义**——CLAUDE.md memory 指南明文允许它指向尚未落地的
# memory("不匹配现有 memory 也没关系,标记待写"),且可跨载体(repo 文档 ↔ git 仓库外的
# ~/.claude/.../memory/*.md,如 threat-model.md 的 [[gotcha_manual_mutation_flatters_the_
# assertion]] 指的就是 memory 文件)。把 [[]] 纳入硬检查 = 要么解析 git 外目录(脆),
# 要么把"先挂后写"的合法用法全打成假红。**反引号 = 硬引用(受本闸门强制);[[]] = 软链接
# (允许待落地/跨载体)** —— 两种形式强制力不同是设计,规范见 .brain/README.md §链接规范。
_SYMBOL = re.compile(
    r"`([a-zA-Z_][a-zA-Z0-9_]*(?:\.[a-zA-Z_][a-zA-Z0-9_]*)+|_?[a-zA-Z][a-zA-Z0-9]*_[a-zA-Z0-9_]+)`"
)

# 不是代码符号的东西
_SKIP_SUFFIX = (".md", ".py", ".json", ".yml", ".yaml", ".sh", ".env", ".txt", ".jsonl", ".parquet")
_SKIP_EXACT = {
    "docker-compose",  # 文件名而非符号
    "pre-commit",
    "docker_api",  # 网络名,在 compose 里但形态特殊(下面会查到,留着不跳过更好)
}


# 文档里**讨论**一个错误名字(而不是引用它)时的豁免标记。
# ⚠️ 必要性:威胁模型里写着「CLAUDE.md 曾把它写成 `_read_parquet_retry`」——
# 那是在**说明一个不存在的名字**,不是在引用它。检查器无法从文本区分
# 「引用」与「讨论」,只能由作者显式标注。这是**自指问题的另一面**:
# 前面是「说明这个错误」污染了语料,这里是「说明这个错误」触发了误报。
# 豁免只作用于**所在那一行**,不是整份文档 —— 范围越窄越不容易被滥用。
_IGNORE_MARK = "<!-- ref-ignore -->"


def _referenced_symbols(text: str) -> set[str]:
    out: set[str] = set()
    lines_ok = "\n".join(ln for ln in text.splitlines() if _IGNORE_MARK not in ln)
    for m in _SYMBOL.findall(lines_ok):
        if "/" in m or m.endswith(_SKIP_SUFFIX) or m in _SKIP_EXACT:
            continue
        # 取最后一段:`cone_tracker.LIVE_LEV_KEY` → LIVE_LEV_KEY
        needle = m.split(".")[-1]
        if len(needle) < 4:  # 太短的容易撞上无关文本
            continue
        out.add(m)
    return out


_COMMENT_LINE = re.compile(r"^\s*(#|//|--)")
_DOCSTRING = re.compile(r'"""(?:.|\n)*?"""|\'\'\'(?:.|\n)*?\'\'\'')
_WORD_CACHE: set[str] | None = None
_FILE_STEMS: set[str] | None = None


def _code_corpus() -> tuple[set[str], set[str]]:
    """把「真代码」抽出来一次:标识符集合 + 文件名 stem 集合。

    ⚠️ **必须剥注释与 docstring** —— 三次迭代的教训:

    | 版本 | 判定方式 | 被什么打穿 |
    |---|---|---|
    | v1 | `grep -F <name>` 裸子串 | **全盘假绿**:污染源是**本文件的 docstring**,它为解释立项案例原样写了错误名 `_read_parquet_retry` ⇒ grep 找得到 ⇒ 永不红 |
    | v2 | 要求 `def X`/`X =`/`X(` 等语法位置 | **大量误报**:`GITHUB_TOKEN` 写作 `${{ secrets.X }}`、`ohlcv_age_sec` 是 JSON 键、`test_xxx` 其实是**文件名** |
    | v3 | 剥注释后取标识符 + 认文件名(本版) | ← |

    v1 正是教训㉗的又一次实例:**「解释这个错误」与「犯这个错误」在文本上同形**。
    """
    global _WORD_CACHE, _FILE_STEMS
    if _WORD_CACHE is not None and _FILE_STEMS is not None:
        return _WORD_CACHE, _FILE_STEMS

    words: set[str] = set()
    stems: set[str] = set()
    for base in SEARCH_DIRS:
        p = ROOT / base
        files = [p] if p.is_file() else [f for f in p.rglob("*") if f.is_file()]
        for f in files:
            # ⚠️ **检查器自身必须排除** —— 它的错误提示文案里写着要检测的那个名字
            # (`...实例)。` 那句),那是**普通字符串字面量**、既非注释也非 docstring,
            # 剥不掉 ⇒ 自我豁免 ⇒ 立项案例那条变异永远假绿(实测 M1)。
            # 一天之内同一个病的第五次:**「说明这个东西」与「这个东西本身」文本同形**。
            if f.resolve() == Path(__file__).resolve():
                continue
            if EXCLUDE_DIRS & set(f.parts) or f.suffix in (".pyc", ".parquet", ".png"):
                continue
            stems.add(f.stem)
            try:
                text = f.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            if f.suffix == ".py":
                text = _DOCSTRING.sub(" ", text)
            text = "\n".join(ln for ln in text.splitlines() if not _COMMENT_LINE.match(ln))
            # 行尾注释也要剥(`x = 1  # 见 _foo_bar`)
            text = re.sub(r"\s#[^\n]*", " ", text)
            words.update(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", text))
    _WORD_CACHE, _FILE_STEMS = words, stems
    return words, stems


def _exists(symbol: str) -> bool:
    words, stems = _code_corpus()
    needle = symbol.split(".")[-1]
    # 认三种:代码里的标识符 / 文件名(如 `test_xxx` 指的是 test_xxx.py) / 完整点号路径
    return needle in words or needle in stems or symbol in words


def main() -> int:
    # 待查文档 = 命令行参数(相对仓库根),没给就用 TARGETS 默认值。
    # 参数化是为了让这个脚本能**原样搬去别的项目**(2026-07-30):它守的
    # 「CLAUDE.md 里引用的符号必须真实存在」对每个用 Claude Code 的项目都成立 ——
    # CLAUDE.md 是每 session 的唯一入口,写错一个函数名就会让下一个 session
    # 照着 grep 一无所获、进而以为那个机制根本不存在。原来 `.brain/security/
    # threat-model.md` 是硬编码在 TARGETS 里的,那是本项目特有的第二个入口文件,
    # 现在由 pre-commit 的 args 传入,默认值只留普适的 CLAUDE.md。
    targets = sys.argv[1:] or TARGETS
    bad: list[tuple[str, str]] = []
    checked = 0
    for rel in targets:
        path = ROOT / rel
        if not path.exists():
            continue
        for sym in sorted(_referenced_symbols(path.read_text(encoding="utf-8"))):
            checked += 1
            if not _exists(sym):
                bad.append((rel, sym))

    if bad:
        print("❌ 文档引用了代码里不存在的符号:")
        for rel, sym in bad:
            print(f"   {rel}: `{sym}`")
        print(
            "\n这不是「文档不准」—— CLAUDE.md 是每个 session 的唯一入口,"
            "错误的符号名会让下一个 session 照着 grep 一无所获,"
            "进而以为那个机制不存在(2026-07-29 实际发生过一次)。"
            "\n改文档或改代码,让两边对上。"
        )
        return 1

    print(f"✅ 文档符号引用全部命中({checked} 个)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
