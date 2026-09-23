# 03 重复提交与空提交

C 上的某个提交，它的改动已经以别的形式存在了（比如被 cherry-pick 到了别处），rebase 会怎么处理？
git 有两套互相独立的机制：生成 todo 时的预检，和重放之后的空提交处理。
两者看的东西不同，`--onto` 下的差别就出在这里。

例子：`examples/03-duplicates/run.sh`。

## 两套机制

预检。生成 todo 时，拿 `B...C` 右边（C 这边）每个提交的 patch-id，与左边（B 这边：在 B 上、不在 C 上）逐个比较。
右边某个提交在左边有 patch-id 相同的提交，就不进 todo，并打印 `warning: skipped previously applied commit <sha>`
（代码阅读：`sequencer.c:6172` 设 `cherry_mark`，`6215-6221` 跳过并警告）。
这一步只看 patch-id，不看合并结果。A 不参与。`--reapply-cherry-picks` 关掉这一步（`sequencer.c:6172`）。

重放后变空。todo 里的提交逐个三方合并后，如果结果与 HEAD 完全相同（index 没有变化），这个提交"变空"了。
处理方式由 `--empty` 决定（代码阅读：`sequencer.c:1787-1817` 的 `allow_empty`，丢弃时在 `2496-2511` 打印
`dropping <sha> <标题> -- patch contents already upstream`）：

- `drop`：丢弃。非交互时的默认。
- `stop`：停下来让人决定。`-i` 时的默认。
- `keep`：保留为空提交。带 `--exec` 且不带 `-i` 时的默认。

默认值在 `builtin/rebase.c:1626-1633`：显式 `-i` 取 stop，有 `--exec` 取 keep，其余取 drop。

本来就是空的提交（`git commit --allow-empty` 做出来的）不走这两套：默认保留，`--no-keep-empty` 才去掉（手册）。

## 副本在 B 那边

例子先在 main 末尾加一个 c1copy，它的改动与 c1 完全相同（新增 `c1.txt`，内容 `c1`），只是提交消息不同。
提交消息不参与 patch-id，所以两者 patch-id 相同（实测）：

```text
c1     ec9b136979add920c52f1bc08963cb92e82632df
c1copy ec9b136979add920c52f1bc08963cb92e82632df
```

```bash
git rebase main child
```

B = main，`main...child` 的左边是 m2 m3 c1copy，右边是 t1 t2 c1 c2 c3。c1 与左边的 c1copy patch-id 相同，预检时剔除：

```text
要搬: pick t1;pick t2;pick c2;pick c3
warning: skipped previously applied commit fd05a98
hint: use --reapply-cherry-picks to include skipped commits
```

结果 child = o0 m1 m2 m3 c1copy t1 t2 c2 c3。

## 副本只在 A 上

```bash
git rebase --onto main topic child
```

A = main（有 c1copy），B = topic。`topic...child` 的左边是空的（topic 上没有不在 child 上的提交），
预检没有东西可比，c1 进了 todo：

```text
要搬: pick c1;pick c2;pick c3
Rebasing (1/3)
dropping fd05a98634b4cf7526a61ebd64b77153b3afe123 c1 -- patch contents already upstream
Rebasing (2/3)
Rebasing (3/3)
```

c1 被重放到 main 上：base = t2（没有 c1.txt），ours = main（有 c1.txt，内容 c1），theirs = c1（新增 c1.txt，内容 c1）。
三方合并的结果与 ours 相同，c1 变空，被 `--empty=drop` 丢弃。结果 child = o0 m1 m2 m3 c1copy c2 c3。

这一节与上一节结果看起来一样，但走的是两套机制。消息也不同：一个是 `skipped previously applied commit`，
一个是 `dropping … -- patch contents already upstream`。

## `-i` 下会停住

```bash
git -c sequence.editor=true rebase -i --onto main topic child
```

- `-c sequence.editor=true`：这一次把编辑 todo 用的编辑器换成 `true` 命令（什么都不做、返回成功），todo 原样执行。
- `-i`：交互模式。`--empty` 的默认值因此变成 stop。

重放 c1 后变空，rebase 停下：

```text
The previous cherry-pick is now empty, possibly due to conflict resolution.
If you wish to commit it anyway, use:
    git commit --allow-empty
Otherwise, please use 'git rebase --skip'
```

此时 `REBASE_HEAD` 指向 c1。`git rebase --skip` 丢掉它，继续 c2 c3，结果与非交互时相同。
`git commit --allow-empty` 则留下一个空提交再 `--continue`。

## `--empty=keep`

```bash
git rebase --empty=keep --onto main topic child
```

变空的 c1 保留为空提交：child = o0 m1 m2 m3 c1copy c1 c2 c3，`git diff --stat child~3 child~2` 输出为空（实测）。
一般用不到，除非要保证"一个提交对应一个提交"（比如新旧提交要一一对照）。

## `--reapply-cherry-picks`

```bash
git rebase --reapply-cherry-picks main child
```

关掉预检：c1 进 todo（`pick t1;pick t2;pick c1;pick c2;pick c3`），重放后变空，再被 `--empty=drop` 丢弃。
最终结果与不加时相同。这个选项的实际用处是：上游提交非常多时，预检要读遍左边所有提交算 patch-id，开销大，
关掉可以省时间（手册）。`--keep-base` 默认打开它（`builtin/rebase.c:1507-1513`），因为 `--keep-base` 下
B 那边的提交不会成为新底座的一部分，预检剔除掉的提交就真丢了。

## 副本在 A 上、之后又被改过：冲突

在 c1copy 之后，main 又提交了 m4，把 `c1.txt` 改成 `c1 changed`。

```bash
git rebase main child                  # 预检剔除 c1，没有冲突
git rebase --onto main topic child     # c1 进 todo，重放冲突
```

第一条：c1 被预检剔除，根本不重放。child = o0 m1 m2 m3 c1copy m4 t1 t2 c2 c3，`c1.txt` 内容是 `c1 changed`。

第二条：c1 被重放。base = t2（没有 c1.txt），ours = main（`c1 changed`），theirs = c1（`c1`）。
两边都新增了这个文件而且内容不同，于是：

```text
CONFLICT (add/add): Merge conflict in c1.txt
error: could not apply fd05a98... c1
```

`git status --short` 显示 `AA c1.txt`（两边都新增）。这个冲突的正确解法通常是取 ours（main 的版本）后 `--continue`，
或者直接 `git rebase --skip` 丢掉 c1。

所以用 `--onto` 时，如果 A 上已经有 C 某些提交的副本，并且副本之后又被改过，要预期会有冲突；
不带 `--onto` 时（B = A）这些提交会在预检阶段被安静地剔除。

## 副本只在 B 那边：改动整个丢掉

反过来：副本在 B 那边，A 上没有。

例子在 topic 上补一个与 c1 改动相同的提交 c1copy-on-topic，child 仍然从旧的 t2 分出。

```bash
git rebase --onto main topic child
```

`topic...child` 的左边是 c1copy-on-topic，右边是 c1 c2 c3。c1 与左边 patch-id 相同，预检剔除：

```text
要搬: pick c2;pick c3
warning: skipped previously applied commit fd05a98
```

结果 child = o0 m1 m2 m3 c2 c3，`c1.txt` 不存在（实测）。c1 的改动既不在 A 上，也没有被重放，就这样从结果里消失了。
唯一的提示是那行 warning。

这是 `--onto` 下"预检比 B 不比 A"的直接后果。实际中出现的场景：父分支上有人 cherry-pick 了子分支的某个提交，
然后你要把子分支改接到一个不含父分支的底座上。

## 用 `git cherry` 对着 A 查

预检只比 B 那边。想知道"C 上哪些提交的改动 A 上已经有了"，用 `git cherry`：

```bash
git cherry -v main child
```

- `main`：拿来比较的一边（这里就是 A）。
- `child`：要检查的一边（C）。输出 C 上、不在 main 上的每个提交，前缀 `-` 表示 main 那边（merge-base 之后）已有
  patch-id 相同的提交，`+` 表示没有。
- `-v`：同时显示标题。

副本只在 A 上时（main 有 c1copy），实测输出：

```text
+ 1f7baedb3d6af9ff533591c3bddda953392ef7a9 t1
+ e615b5612435af45c45591471ef481569bdc60bc t2
- fd05a98634b4cf7526a61ebd64b77153b3afe123 c1
+ b0ee4bb52993945b01951cd7531fb1be33e192e7 c2
+ 4b0498fd68f321af9c030e2e8385349dda830f36 c3
```

副本只在 B 那边时（c1copy-on-topic 在 topic 上，main 没有），c1 的前缀是 `+`（实测）。
所以 rebase 打出 `skipped previously applied commit X` 时，跑一次 `git cherry -v A C`：X 前面是 `-`，
改动确实已经在 A 上，跳过没问题；是 `+`，就是上一节的情况，加 `--reapply-cherry-picks` 重做。
