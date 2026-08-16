# `git commit` / `ocr delegate rule` 截断闸门的场景用例

跑法（数据必须**从文件读**，别用 `echo` 传——`echo` 会把 `\n` 解释成真换行 ⇒ 误判）:

```bash
uv run python - <<'EOF'
import json, pathlib, subprocess
d = pathlib.Path(".claude/hooks/testcases-commit-truncation")
exp = json.loads((d / "expect.json").read_text())
hook = str(pathlib.Path.home() / ".claude/hooks/review-before-commit.sh")
bad = []
for name, want in exp.items():
    p = subprocess.run(["bash", hook], stdin=(d / f"{name}.json").open("rb"),
                       capture_output=True, text=True)
    got = '"deny"' in p.stdout
    if got != want: bad.append(name)
print("OK" if not bad else f"FAIL: {bad}")
EOF
```

## 两批的来历

- `01_*`~`07_*`（2026-08-04 上午）：`git commit` 截断保护首版
- `t1_*`~`t12_*`（同日下午）：**修假阳性**那轮 —— 原判据只要求
  `| head`/`| tail` 在行末 + 那行含 `git commit` 子串，于是
  `grep -n "git commit" hook.sh | head -20` 被 deny（它甚至挡住了我读源码修 bug），
  `archive_current.py --summary "…git commit…" | tail -2` 也被 deny。
  修成**两道**：命令位置（段首，允许 `VAR=x` 前缀）+ 按 `&&`/`||`/`;`/换行 切段。

## ⚠️ 三个容易写错的期望

- `t10_ok_midline`：`git commit … | tail -4 && echo done` **应该 deny**
  （名字里的 `ok` 是首版的错误期望，留着当教训：它描述的是**旧判据的行为**，
  不是**应该的行为**）
- `t11_heredoc_then_cmd`：`git commit … && gh run list | head -3` **应该放行**
  （那个 head 是给 gh 的）
- `t9_real_heredoc`：heredoc 形式**必须 deny** —— 长 commit message 都走 heredoc，
  这是最常用的写法，而剥离 heredoc 时若不吃掉结束标记那行的换行就会漏判
