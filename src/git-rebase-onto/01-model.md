# 01 模型

这一篇讲 `git rebase --onto A B C` 的完整语义：三个参数各决定什么，git 内部按什么顺序执行，每一步对应哪段源码。
后面几篇讲的现象都能从这里推出来。

例子：`examples/01-model/run.sh`。

## 前提词

提交图与可达。每个提交记录它的父提交（parent）。从提交 X 沿父指针一路往回能走到 Y，就说 Y 从 X 可达。
分支名（如 `refs/heads/child`）只是一个 ref，里面存着一个提交的 sha，这个提交就是分支的 tip。
"分支上的提交"指从 tip 可达的全部提交。

`X..Y`。从 Y 可达、从 X 不可达的提交集合。它是集合差，不要求 X 是 Y 的祖先。在实验仓库里：

```text
topic..child   = c1 c2 c3              topic 是 child 的祖先
main..child    = t1 t2 c1 c2 c3        m1 以前的提交两边都可达，被减掉
side..child    = t1 t2 c1 c2 c3        side 不是 child 的祖先，照样成立
```

`X...Y`。在 `git rev-list` / `git log` 里，它是只属于其中一边的提交：从 X 可达或从 Y 可达，但不同时从两边可达。
`--left-only` 只留 X 那一边，`--right-only` 只留 Y 那一边。注意 `...` 在 git 里有三种意思：
在 `rev-list` 里是上面这个对称差；在 `git diff X...Y` 里是"从 merge-base 到 Y 的 diff"；
在 `rebase --onto X...Y` 里是"X 与 Y 的 merge-base 这一个提交"（见 02 篇）。

merge-base。两个提交共同祖先里最近的那个（`git merge-base X Y`）。可能不止一个，`git merge-base --all` 列出全部。

patch-id。把一个提交的 diff 去掉行号和空白后求的哈希（`git show X | git patch-id --stable`）。
提交消息、作者、父提交都不参与。两个提交 patch-id 相同，git 就把它们当成同一个改动。
cherry-pick 出来的副本、rebase 前后的同一个提交，通常 patch-id 相同。

重放一个提交 X（cherry-pick）。做一次三方合并：base = X 的原父 `X^`，ours = 当前 HEAD，theirs = X。
合并结果用 X 的作者、作者时间和提交消息提交，父提交是当前 HEAD。效果是把 "X^ → X" 这段改动加到 HEAD 上。

游离 HEAD（detached HEAD）。平时 `.git/HEAD` 里写的是 `ref: refs/heads/<分支>`，提交会推进那个分支；
游离时 `.git/HEAD` 里直接是一个 sha，新提交不属于任何分支。

`ORIG_HEAD` 与 reflog。`ORIG_HEAD` 是 reset / merge / rebase 这类命令开始前记下的"原来的位置"，下一次这类命令会覆盖它。
reflog 是每个 ref 的变动记录，`child@{1}` 表示 child 上一次变动之前的值，`child@{2}` 再往前一次，依此类推。

## 三个参数

手册里的写法是 `git rebase --onto <newbase> <upstream> <branch>`。这份整理里分别记作 A、B、C：

- C（`<branch>`）：要搬的分支。rebase 结束时它指向新链的末端。省略时取当前 HEAD。
- B（`<upstream>`）：只用来划定要搬哪些提交。要搬的是 `B..C`（再经过几步过滤，见下文）。B 不参与任何一次合并。
  省略时取当前分支配置的 upstream（`branch.<名字>.merge`），并默认打开 `--fork-point`（见 05 篇）。
- A（`<newbase>`）：新的底座，第一个被重放的提交接在 A 上。省略 `--onto` 时 A = B。

实测（01）：固定 B = topic、C = child，A 换成 main、side、main~3、child，四次生成的 todo 都是 `pick c1;pick c2;pick c3`。
A 不影响要搬哪些提交。

## 为什么要把 A 和 B 拆开

不带 `--onto` 的 `git rebase B` 里，B 同时承担两个角色：集合的下界（从哪里切）和新底座（接到哪里）。
这在一种情况下够用：C 原来的底座是 B 的祖先，也就是 B 在 C 的底座之后又往前走了几步，C 要跟上。

两个角色不重合的情况也很常见：

- 把一个基于 topic 的分支改接到 main 上。集合的下界是 topic（topic 的提交不要），新底座是 main。
- 父分支被改写了（rebase 过、amend 过）。集合的下界是父分支的旧 tip，新底座是父分支的新 tip。
  旧 tip 不在新 tip 的历史里。
- 从分支中间删掉一段提交。下界是要删的最后一个，新底座是要删的第一个的父提交。

这时就要用 `--onto` 把两个角色分别指定。实测（02）里第一行 `git rebase main child` 与第二行
`git rebase --onto main topic child` 的 A 都是 main，只有 B 不同：前者搬 t1 t2 c1 c2 c3，后者只搬 c1 c2 c3。

## 执行顺序

手册给了一个简化的四步描述：列出要搬的提交；`git checkout --detach <A>`；逐个 cherry-pick；
`git checkout -B <C>` 把分支指到新链末端（手册：`git-rebase.adoc:70-82`）。源码里的实际顺序更细，按默认的 merge 后端：

1. 解析 C。C 是本地分支名时，记下它的 tip（`orig_head`）和完整 ref 名（`head_name = refs/heads/C`）；
   这个分支如果已被别的 worktree 检出，直接报错退出。C 不是分支名（是 sha、tag、`HEAD~2` 之类）时，
   `head_name` 为空，结束时就不会更新任何分支（代码阅读：`builtin/rebase.c:1694-1716`）。
   省略 C 时取当前 HEAD：HEAD 在分支上就用那个分支，HEAD 游离就用游离的那个提交（`builtin/rebase.c:1717-1735`）。
2. 解析 B。命令行给了就按字面用；没给就取配置的 upstream，并把 fork-point 默认值设为开
   （代码阅读：`builtin/rebase.c:1645-1662`，默认值在 `1654-1655`）。
3. 解析 A。没写 `--onto` 时 A 取 B 的名字（`builtin/rebase.c:1746-1747`）；
   A 的写法里含 `...` 时取两边唯一的 merge-base，有多个就报错（`builtin/rebase.c:1748-1758`）。
4. fork-point 打开时，从 B 的 reflog 里找出 C 的分叉点（`builtin/rebase.c:1771-1773`，见 05 篇）。
5. 判断是否已经是最新：A 就是 A 与 C 的 merge-base，A 也是 B 与 C 的 merge-base，而且 A 到 C 之间没有 merge，
   就打印 `Current branch C is up to date.`，什么也不做；加 `--force-rebase`（`-f`）时跳过这个判断
   （代码阅读：`builtin/rebase.c:894-926` 的 `can_fast_forward`，调用处 `1799-1829`）。
6. 生成 todo 列表：`B...C` 的右边，去掉 merge 提交，去掉与左边 patch-id 相同的提交，按从旧到新排列（下一节细讲）。
7. 把 HEAD 游离到 A，同时把 `ORIG_HEAD` 设成 C 原来的 tip（代码阅读：`sequencer.c:4866-4886` 的 `checkout_onto`，
   标志位 `RESET_HEAD_DETACH | RESET_ORIG_HEAD`）。
8. 逐条执行 todo：每个 `pick X` 做一次三方合并，base = `X^`，ours = HEAD，theirs = X
   （代码阅读：`sequencer.c:2384-2387`）。合并后没有改动的按 `--empty` 处理（03 篇）；冲突时停下（04 篇）。
9. 收尾：`head_name` 非空时，把 `refs/heads/C` 从原来的 tip 更新到当前 HEAD，reflog 记为
   `rebase (finish): refs/heads/C onto <A 的 sha>`；再把 HEAD 接回这个分支，记为 `rebase (finish): returning to refs/heads/C`
   （代码阅读：`sequencer.c:5129-5166`）。`head_name` 为空时跳过这一步，HEAD 留在游离状态。

手册说 `git rebase master topic` 是 `git checkout topic && git rebase master` 的简写（手册：`git-rebase.adoc:35-36`）。
merge 后端实际并不先切过去：它在第 1 步只读出 C 的 tip 和名字，第 7 步直接游离到 A。实测（01）的 HEAD reflog（在 main 上执行 `git rebase --onto main topic child`）：

```text
HEAD@{0} rebase (finish): returning to refs/heads/child
HEAD@{1} rebase (pick): c3
HEAD@{2} rebase (pick): c2
HEAD@{3} rebase (pick): c1
HEAD@{4} rebase (start): checkout main
```

里面没有切到 child 的记录。结果与"先切过去"相同：结束时 HEAD 在 child 上，`--abort` 时也回到 child（04 篇）。

## 要搬哪些提交

第 6 步生成的列表，等于下面这条命令的输出（实测（01）：五组 B / C 下与 `-i` 生成的 todo 逐条相同）：

```bash
git rev-list --reverse --topo-order --no-merges --right-only --cherry-pick B...C
```

逐个参数：

- `B...C`：只属于 B 或只属于 C 的提交。左边是"在 B 上、不在 C 上"，右边是"在 C 上、不在 B 上"。
- `--right-only`：只输出右边，也就是 `B..C`。左边只用于下面的 `--cherry-pick` 比较。
- `--cherry-pick`：计算两边每个提交的 patch-id，右边某个提交如果在左边有 patch-id 相同的提交，就去掉它。
  比较对象是左边（B 那边），不是 A。03 篇讲这带来的后果。
- `--no-merges`：去掉有多个父提交的 merge 提交。merge 带进来的普通提交仍在集合里，结果被拍平（06 篇）。
- `--topo-order`：保证每个提交都排在它的子提交之前。
- `--reverse`：从旧到新输出，也就是重放的顺序。

源码里对应的是：`get_revision_ranges` 拼出 `"%s...%s"`，左边取 `upstream ? upstream : onto`，即有 B 时用 B
（代码阅读：`builtin/rebase.c:244-269`，关键在 `248` 与 `251`）；fork-point 找到分叉点时再追加一个 `^<分叉点>`
（`builtin/rebase.c:304-306`）；`sequencer_make_script` 设置 `max_parents = 1`、`cherry_mark`、`right_only`、
`reverse`、`topo_order`（代码阅读：`sequencer.c:6170-6177`），遍历时把带 `PATCHSAME` 标记的提交跳过并打印
`skipped previously applied commit`（`sequencer.c:6215-6221`）。A 在生成列表时完全不出现。

## 用普通命令手工重做一遍

下面这串命令与 `git rebase --onto main topic child` 等价。实测（01）：在固定提交者与时间的前提下，
得到的 child 与 rebase 的结果 sha 逐位相同（都是 `c26d281ba8d7`）。

```bash
old=$(git rev-parse child)
list=$(git rev-list --reverse --topo-order --no-merges --right-only --cherry-pick topic...child)
git switch --detach main
for x in $list; do git cherry-pick --empty=drop "$x"; done
git update-ref refs/heads/child HEAD "$old"
git switch child
```

逐条：

- `git rev-parse child`：把 child 解析成 sha，记下原来的 tip。
- `git rev-list …`：上一节的公式，得到要搬的提交。
- `git switch --detach main`：把 HEAD 游离到 main 指向的提交上。`--detach` 表示不切到分支 main 本身，
  否则后面的 cherry-pick 会推进 main。
- `git cherry-pick --empty=drop "$x"`：重放 X。`--empty=drop` 表示重放后没有改动就不提交，与 rebase 非交互时的默认相同。
- `git update-ref refs/heads/child HEAD "$old"`：把 `refs/heads/child` 改成当前 HEAD 的值。第三个参数是期望的旧值，
  child 此刻不等于它时拒绝更新，防止中途有别人动过 child。
- `git switch child`：把 HEAD 接回 child。

rebase 比这串命令多做的事：冲突时把进度存进 `.git/rebase-merge/`，以便 `--continue`；设置 `ORIG_HEAD`；
写 reflog；`--update-refs` 顺带更新别的分支；执行 `post-rewrite` 钩子等。

## 重放前后什么变了

实测（01），`git rebase --onto main topic child` 之后逐个比较新旧提交：

```text
c3  旧 4b0498f  新 c26d281  patch-id 旧 8ee9071b21a4 新 8ee9071b21a4
c2  旧 b0ee4bb  新 82c50ab  patch-id 旧 106c125e6e5b 新 106c125e6e5b
c1  旧 fd05a98  新 257be3b  patch-id 旧 ec9b136979ad 新 ec9b136979ad
```

- sha 变了：父提交变了，tree 也变了（新 tree 里有 m2.txt、m3.txt，没有 t1.txt、t2.txt）。
- patch-id 没变：各自引入的改动相同。
- 作者、作者时间、提交消息没变。提交者和提交时间取执行 rebase 时的值（例子里被 `lib.sh` 固定了，所以看不出来）。
- 旧提交还在对象库里，从 `ORIG_HEAD` 和 `child@{1}` 都能找到（04 篇讲怎么撤销）。
