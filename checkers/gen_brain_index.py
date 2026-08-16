#!/usr/bin/env python3
"""给 `.brain/gotchas/` 与 `.brain/decisions/` 生成标题索引。

## 为什么要有它

2026-08-02 实测:`gotchas/` **63** 个、`decisions/` **38** 个,两边**都没有任何索引**,
而 CLAUDE.md 里只手工点名了 5 个「高频」gotcha。另外 96 份的发现路径只剩「grep 猜关键词」
—— 猜中了才存在,猜不中就等于没写过。这是**检索衰减**:写入侧一直在涨,读取侧从没跟上。

索引**故意只做机械的那一半**:文件名 + 它自己的 `# ` 标题。不提炼、不概括、不编 hook ——
那是判断题,脚本替人编就会编错(同样的理由见 `archive_current.py` 的 `--summary` 必填)。
前提是标题本来就写得具体(「`mode == "live"` 在多后端部署里全是隐式的主后端假设」这种),
标题即 hook,不需要第二段文字。标题写得含糊时,索引也只能含糊 —— 这是有意的。

## 为什么不并进 `check_doc_references.py`

那个脚本的 docstring 明写它为**可移植性**而参数化(默认只查 CLAUDE.md,零配置搬去别的项目),
而且它是**纯只读检查器**。索引要写文件、要认识 `.brain/` 的目录约定 —— 两件事职责不同,
混在一起会让那份可移植性失效。这里独立成脚本,同样在 pre-commit 注册,同步强制力不打折。

## 为什么索引不进 CLAUDE.md

它是**按需读**的载体(① 层),不是每 session 必吃的常驻区。101 条、每条约 120 B ⇒ 合计约 12 KB,
塞进常驻区会直接吃掉 CLAUDE.md 40 KB 预算的三成 —— 而绝大多数 session 一条都用不到。
CLAUDE.md 里只留一个指针(那行本来就在,只是从「点名 5 个」变成「点名 5 个 + 指向全量」)。

## 用法

```bash
uv run python scripts/gen_brain_index.py            # 重新生成(幂等)
uv run python scripts/gen_brain_index.py --check    # 只检查,不写(pre-commit 用)
```
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# ⚠️ 按**脚本自己的位置**定位仓库根,不按 cwd:从子目录跑也必须对。
# `archive_current.py` 用的是相对 cwd 的路径,那条路在这里会变成**静默假绿** ——
# `.brain/` 找不到 ⇒ 两个 section 都被跳过 ⇒ 打印「已是最新」并 exit 0,
# 与「真的已是最新」一模一样([[gotcha_no_info_rendered_as_normal]])。
# 下面 `main()` 里的「两个目录都不存在就报错」是同一道防线的另一半。
ROOT = Path(__file__).resolve().parent.parent

# 索引文件名。⚠️ **必须把它自己排除在被索引的集合之外** —— 否则第一次生成后
# 索引里会多出「INDEX.md — 踩坑清单索引」这条,而它是**上一次生成的产物**,
# 于是每跑一次就多一层自指。这是这个仓库的高频病:
# [[gotcha_self_referential_contamination]](说明 X 与犯 X 同形)。
INDEX_NAME = "INDEX.md"

# ⚠️ decisions/ 用 `INDEX.md` 而不是 `0000-index.md`:后者会被读成「ADR-0000」,
# 而 ADR 编号是有语义的连续序列,插一个非决策进去会污染它。
SECTIONS: tuple[tuple[str, str, str], ...] = (
    (
        "gotchas",
        "踩坑清单",
        "踩过的坑。按文件名字典序,标题即 hook —— 认出哪条像自己正在做的事,再去读那一份。",
    ),
    (
        "decisions",
        "决策记录(ADR)",
        "按 ADR 编号排序。想知道「为什么是现在这样」先查这里,别从代码反推。",
    ),
)

BANNER = "> ⚠️ **本文件由 `scripts/gen_brain_index.py` 自动生成,别手改** —— 手改会被 pre-commit 的 `brain-index` 闸门打回。"
REGEN = "> 加 / 删 / 改标题后跑 `uv run python scripts/gen_brain_index.py` 重新生成。"


def extract_title(path: Path) -> str | None:
    """取文件第一个**代码围栏之外**的 `# ` 标题。

    ⚠️ 围栏判定不是洁癖:gotcha 里到处贴 shell / Python 片段,而 `# 注释` 与
    Markdown 一级标题**在文本上完全同形**。今天(2026-08-02)全量扫过 101 份、
    围栏内 `# ` 开头的行是 0 条 —— 所以这是**潜在漏洞防御**,不是现存 bug。
    但「贴一段以注释开头的脚本」是这个目录最自然的写法,迟早会踩,而它踩起来
    是**静默错标题**(索引照样生成、照样绿),不是报错。
    """
    fence = False
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.lstrip()
        if stripped.startswith("```") or stripped.startswith("~~~"):
            fence = not fence
            continue
        if not fence and line.startswith("# "):
            return line[2:].strip()
    return None


def collect(folder: Path) -> tuple[list[tuple[str, str]], list[str]]:
    """返回 (已取到标题的条目, 没有标题的文件名)。

    ⚠️ 缺标题**必须报出来**,不许回落成文件名 —— 回落之后索引仍然「完整」、
    仍然绿,只是那一条的信息量悄悄降级了。[[gotcha_no_info_rendered_as_normal]]。
    """
    entries: list[tuple[str, str]] = []
    missing: list[str] = []
    for path in sorted(folder.glob("*.md")):
        if path.name == INDEX_NAME:
            continue
        title = extract_title(path)
        if title is None:
            missing.append(path.name)
        else:
            entries.append((path.name, title))
    return entries, missing


def render(heading: str, blurb: str, entries: list[tuple[str, str]]) -> str:
    lines = [
        f"# {heading}索引({len(entries)} 项)",
        "",
        BANNER,
        REGEN,
        "",
        blurb,
        "",
    ]
    lines += [f"- [`{name}`](./{name}) — {title}" for name, title in entries]
    lines.append("")
    return "\n".join(lines)


# 差异行折叠上限。⚠️ 不是洁癖:`check_doc_references.py` 的 docstring 里钉着
# 「**一个吵闹的检查会被 `--no-verify` 绕过,最终等于没有** —— 那比没有还糟」。
# 首次生成那次实测刷了 **101 行**,而日常差异几乎总是 1~2 条(刚写了一份新 gotcha)。
_DIFF_MAX = 8


def _diff_summary(want: str, got: str) -> list[str]:
    """只报「条目集合」的增删改,不打整份 diff —— 差异几乎总是「加了新文件没重生成」。"""

    def rows(text: str) -> dict[str, str]:
        out: dict[str, str] = {}
        for ln in text.splitlines():
            if ln.startswith("- [`") and "`](" in ln:
                name = ln[4 : ln.index("`](")]
                out[name] = ln
        return out

    a, b = rows(want), rows(got)
    msgs = [f"     + 索引缺了 {n}" for n in sorted(a.keys() - b.keys())]
    msgs += [f"     - 索引里有个已不存在的 {n}" for n in sorted(b.keys() - a.keys())]
    msgs += [
        f"     ~ {n} 的标题变了" for n in sorted(k for k in a.keys() & b.keys() if a[k] != b[k])
    ]
    if not msgs:
        return ["     (条目一致,差在头部说明或空行 —— 直接重新生成即可)"]
    if len(msgs) > _DIFF_MAX:
        hidden = len(msgs) - _DIFF_MAX
        return [*msgs[:_DIFF_MAX], f"     … 另有 {hidden} 处差异(共 {len(msgs)} 处)"]
    return msgs


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true", help="只检查是否同步,不写文件")
    ap.add_argument("--root", metavar="DIR", help="仓库根(默认按脚本位置推定;测试用)")
    args = ap.parse_args(argv)

    brain = (Path(args.root) if args.root else ROOT) / ".brain"
    folders = [(brain / d, d, h, b) for d, h, b in SECTIONS]
    if not any(f.is_dir() for f, *_ in folders):
        # ⚠️ 一个都找不到 = root 指错了。**必须报错,不能当「没什么要做的」** ——
        # 静默 exit 0 与「真的已同步」在输出上完全一致,而这正是这个仓库十二次的老病。
        print(f"❌ {brain} 下既没有 gotchas/ 也没有 decisions/ —— 仓库根找错了?")
        return 1

    # 先全量算一遍再动手,不边算边写 —— 理由见下面 broken 那段。
    plan: list[tuple[Path, str, str, int]] = []
    broken: list[str] = []
    for folder, dirname, heading, blurb in folders:
        if not folder.is_dir():
            continue
        entries, missing = collect(folder)
        broken += [f".brain/{dirname}/{n}" for n in missing]
        plan.append((folder, dirname, render(heading, blurb, entries), len(entries)))

    # ⚠️ 缺标题必须**在动任何文件之前**拒掉。第一版是边写边攒 broken、循环结束才报错,
    # 于是输出成了「✅ 已更新 …」在前、「❌ 有文件缺标题」在后 —— 而那份已经落盘的索引
    # 正是**少了那一条的残次品**。看到第一行就以为成了,是这类脚本最典型的误读。
    # 要么全对,要么一个字节都不动。
    if broken:
        print("❌ 这些文件没有代码围栏之外的 `# ` 一级标题,索引取不到它们的 hook:")
        for f in broken:
            print(f"   {f}")
        print("\n每份 gotcha / ADR 的第一行标题就是它在索引里的全部信息量。补一行 `# 标题`。")
        return 1

    stale: list[str] = []
    written: list[str] = []
    for folder, dirname, want, count in plan:
        index_path = folder / INDEX_NAME
        got = index_path.read_text(encoding="utf-8") if index_path.exists() else ""
        if want == got:
            continue
        rel = f".brain/{dirname}/{INDEX_NAME}"
        if args.check:
            stale.append(rel)
            print(f"❌ {rel} 与目录不同步({count} 份文件):")
            for line in _diff_summary(want, got):
                print(line)
        else:
            index_path.write_text(want, encoding="utf-8")
            written.append(f"{rel}({count} 项)")

    if args.check:
        if stale:
            print(
                "\n索引是 gotchas/decisions 唯一的目录 —— 不同步意味着新写的那份"
                "「存在但找不到」,等于没写。\n"
                "跑 `uv run python scripts/gen_brain_index.py` 重新生成后再提交。"
            )
            return 1
        print("✅ .brain 索引与目录同步")
        return 0

    if written:
        for w in written:
            print(f"✅ 已更新 {w}")
    else:
        print("✅ .brain 索引已是最新,无需改动")
    return 0


if __name__ == "__main__":
    sys.exit(main())
