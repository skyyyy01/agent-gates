# `git commit` / `ocr delegate rule` 截断闸门的场景用例

这里只放**语料**（19 个 `*.json`）和**期望**（`expect.json`，`true` = 必须 deny）。
跑它们的是 `tests/test_truncation_cases.sh`：

```bash
bash tests/test_truncation_cases.sh
```

`tests/mutations.sh` 里的 M7 / M8 会故意破坏截断闸门，证明这批用例真的在测东西。

## ⚠️ 这份跑法本身出过一次事（2026-08-16 修）

原先这里写的是一段**要人手动粘贴**的 Python，而且：

- 路径写的是 `.claude/hooks/testcases-commit-truncation` —— 那是作者机器上的旧位置，
  仓库里的实际位置是 `tests/testcases-commit-truncation`，照抄必红
- 没说必须在一个**已 opt-in**（`.claude/hooks/review-before-commit` 存在）的仓库里跑，
  否则 hook 在第一道开关处就静默 exit 0，7 条「应该 deny」的用例全部落空
- 没有任何脚本引用这 19 个用例 ⇒ 它们是孤儿，只有想起来才会被跑

一个主张「机制优于纪律」的项目，把 19 个测试托付给了「记得手动粘贴文档里的代码」。
这条自己踩的坑与 `docs/why-mechanism-not-discipline.md` 里记的那三个同源，
所以留在这里，不删。

## 两条仍然成立的注意事项

- 数据必须**从文件喂给 stdin**，不能 `echo "$(cat f)"` 转一道 —— 用例里的 `\n` 是
  JSON 字符串里的两字符转义，被解释成真换行就变成了另一条命令，heredoc 那几条
  （t9/t11/t12）的判据整个失效
- 判据要的是「**截断**闸门 deny 了」，不是「输出里有 deny」—— 后者会把审查闸门的
  deny 算成截断闸门的功劳。runner 用两条截断文案共有的「后面跟了」当指纹

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
