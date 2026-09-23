# `git rebase --onto A B C` 整理

`git rebase --onto A B C` 做三件事：取出 C 上从 B 走不到的那些提交，把它们按原顺序逐个重新提交到 A 上，
最后让分支 C 指向新链的末端。这份整理讲清楚三个参数各自决定什么、git 内部按什么顺序执行、
哪些提交会被悄悄跳过或丢弃、冲突时 ours 和 theirs 各是谁、父分支被改写后怎么把子分支搬过去，
以及一些不报错但结果不对的写法。

每个结论都配有能直接跑的例子，脚本里用断言兑现，而不是靠肉眼读输出。

## 核对环境

2026-09-22 在 Linux x86_64 上核对：

- git 2.55.0（发行版包）。所有例子在这个版本上跑通。
- 源码行号取自 git 仓库的 tag `v2.55.0`（`e9019fcafe00`）：`builtin/rebase.c`、`sequencer.c`、`commit.c`。
- 手册取自同一 tag 的 `Documentation/git-rebase.adoc`。

正文里的结论分四种依据，就地标注：

- 实测：`examples/` 里的断言，或正文给出的命令输出。
- 代码阅读：git 源码，给出文件与行号。
- 手册：`Documentation/git-rebase.adoc`。
- 推论：由前三者推出，没有单独实跑。

## 读法

- [01 模型](01-model.md)：前提词；三个参数各决定什么；为什么要拆成两个参数；git 内部的执行顺序；
  用普通命令手工重做一遍；对应的源码。
- [02 写法对照](02-variants.md)：同一个仓库，A / B / C 换十几种写法，逐条看搬了哪些提交、结果是什么、HEAD 停在哪。
- [03 重复提交与空提交](03-duplicates.md)：预检（patch-id，比较的是 B 那边）与重放后变空（`--empty`）两套机制；
  副本只在 B 那边时改动会整个丢掉。
- [04 冲突与恢复](04-conflicts.md)：base / ours / theirs 各是谁；进行中的状态存在哪；
  `--continue` / `--skip` / `--abort` / `--quit`；做完以后怎么撤销。
- [05 叠放分支](05-stacked.md)：父分支被改写后把子分支搬过去；旧 tip 去哪找；`--fork-point`；`--update-refs`。
- [06 merge 提交与其他坑](06-merges-and-pitfalls.md)：merge 默认被拍平；`--rebase-merges`；
  分支被别的 worktree 检出；工作区不干净与 `--autostash`；坑的清单。

第一次读按 01 → 06 的顺序。只想查"某种写法会得到什么"，直接看 02。

## 目录

```text
git-rebase-onto/
├── 01-model.md … 06-merges-and-pitfalls.md
└── examples/
    ├── lib.sh                    共用脚手架：一次性目录、屏蔽个人配置、固定时间、建实验仓库、断言
    ├── run-all.sh                依次跑全部例子
    ├── 01-model/                 todo 与 rev-list 公式逐条比较；A 不影响要搬的提交；reflog；手工重做
    ├── 02-variants/              十几种写法的结果
    ├── 03-duplicates/            预检剔除、变空丢弃、-i 下停住、--empty=keep、副本只在 B 那边
    ├── 04-conflicts/             三个 stage、冲突标记、状态文件、continue / skip / abort / quit、事后撤销
    ├── 05-stacked/               父分支改写后搬子分支、reflog 里找旧 tip、fork-point、--update-refs
    └── 06-merges-and-pitfalls/   merge 被拍平、--rebase-merges、worktree、--autostash
```

所有例子用同一个实验仓库（`lib.sh` 里的 `mk`）：

```text
o0 ─ m1 ─ m2 ─ m3                 main
     ├─ s1                        side
     └─ t1 ─ t2                   topic
             └─ c1 ─ c2 ─ c3      child
```

每个提交只新增一个以自己名字命名的文件（`c1` 新增 `c1.txt`，内容是 `c1`），所以除非例子特意制造，彼此不会冲突。

## 跑例子

```bash
examples/run-all.sh                            # 全部例子；成功的只打印一行，失败的打印完整输出
bash examples/03-duplicates/run.sh             # 单个例子，完整输出
KEEP=1 bash examples/05-stacked/run.sh         # KEEP=1：结束后保留一次性目录，可以进去自己敲命令
GIT=/opt/git-2.50/bin/git examples/run-all.sh  # GIT=<路径>：换一个 git 可执行文件复核
```

每个例子在 `mktemp -d` 建的一次性目录里建仓库，结束时删除，不碰你机器上的任何仓库。
`lib.sh` 设了 `GIT_CONFIG_GLOBAL=/dev/null` 与 `GIT_CONFIG_NOSYSTEM=1`，屏蔽 `~/.gitconfig` 和 `/etc/gitconfig`：
`rebase.updateRefs`、`rebase.autoSquash`、`merge.conflictStyle` 这类个人配置会改变输出。
作者、提交者与时间也固定了，所以同一版本 git 上每次得到的 sha 相同，正文里引用的 sha 就是这样来的。

看 todo 列表用的是 `lib.sh` 里的 `todo_of`：它以 `-i` 启动 rebase，编辑器换成一个小脚本，
脚本把 todo 的非注释行抄出来，再把 todo 清空。todo 为空时 rebase 以 "nothing to do" 退出，
什么也不改。所以 `todo_of <参数…>` 能在不执行的前提下看到"这组参数会搬哪些提交"。

依赖只有 git 与 bash。

## 来源

- git 源码，tag `v2.55.0`：`builtin/rebase.c`（参数解析、默认值、`can_fast_forward`、`get_revision_ranges`）、
  `sequencer.c`（`sequencer_make_script`、`do_pick_commit`、`allow_empty`、`checkout_onto`、收尾、`--update-refs`）、
  `commit.c`（`get_fork_point`）
- 手册：同一 tag 的 `Documentation/git-rebase.adoc`
