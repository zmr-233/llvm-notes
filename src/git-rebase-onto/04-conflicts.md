# 04 冲突与恢复

rebase 停在冲突上时，base / ours / theirs 各是谁；进行中的状态存在哪；四种继续或放弃的方式各做什么；
做完以后后悔了怎么撤销。

例子：`examples/04-conflicts/run.sh`。例子把实验仓库改成这样：main 多一个 m4，把 `o0.txt` 改成 `o0 main`；
child 的 c2 把 `o0.txt` 改成 `o0 child`。执行 `git rebase --onto main topic child`，c1 顺利重放，停在 c2 上。

## base / ours / theirs

重放提交 X 是一次三方合并（代码阅读：`sequencer.c:2384-2387` 设 `base = parent`、`next = commit`；
`sequencer.c:765-767` 设三个标签）：

```text
base   = X^ 里的内容               标签 "parent of <X> (<X 的标题>)"
ours   = HEAD，正在建的新链         标签 "HEAD"
theirs = X，正在重放的旧提交        标签 "<X> (<X 的标题>)"
```

停在 c2 上时，index 里的三个 stage（实测）：

```text
:1:o0.txt = o0          base   = c2 的原父 c1 里的内容
:2:o0.txt = o0 main     ours   = HEAD = main 加上已经重放好的 c1
:3:o0.txt = o0 child    theirs = c2
```

`git show :1:o0.txt` 里的 `:1:` 表示 index 的 stage 1，`:2:`、`:3:` 同理；没有冲突的文件只有 stage 0。

这与 `git merge` 时的直觉正好相反。merge 时你站在自己的分支上，ours 是自己的改动；
rebase 时你"站"在新底座上，自己分支上的提交是被搬过来的那个，所以是 theirs。实测：

```text
git checkout --ours o0.txt     → o0 main       main 那边
git checkout --theirs o0.txt   → o0 child      child 自己的提交
```

`git checkout --ours <文件>` / `--theirs <文件>`：用 stage 2 / stage 3 的内容覆盖工作区里的这个文件。

工作区里的冲突标记，用 `-c merge.conflictStyle=diff3` 时（多出 `|||||||` 一段 base）：

```text
<<<<<<< HEAD
o0 main
||||||| parent of 778b25d (c2)
o0
=======
o0 child
>>>>>>> 778b25d (c2)
```

- `-c merge.conflictStyle=diff3`：这一次把冲突标记换成三段式，中间列出 base 的内容。默认的 `merge` 风格没有 `|||||||` 这一段。
  看得到 base 才能判断"两边各改了什么"，冲突多时建议在配置里长期打开。另有 `zdiff3`，与 diff3 相同，
  但把冲突区开头和结尾两边相同的行移出冲突区（手册：`Documentation/config/merge.adoc`）。

## 停住时的状态

实测，停在 c2 上时：

- `git branch --show-current` 输出为空：HEAD 游离，在已经重放好的 c1 上（`o0 m1 m2 m3 m4 c1`）。
- `REBASE_HEAD` 指向正在重放的旧 c2（`778b25d`）。`git show REBASE_HEAD` 可以看这个提交原本改了什么。
  （代码阅读：`sequencer.c:1711` 的 `write_rebase_head`。）
- `.git/rebase-merge/` 下保存了全部进度：

```text
onto        A 的 sha（这里是 main）
orig-head   C 原来的 tip
head-name   refs/heads/child；C 写成 sha 时是 "detached HEAD"（代码阅读：builtin/rebase.c:315-317）
done        已经执行（包括正在执行）的 todo 行：c1 c2
git-rebase-todo   还没执行的 todo 行：c3
```

`onto` 与 `orig-head` 是后面 `--abort` 与收尾用的；`head-name` 决定收尾时更新哪个分支。
`git status` 读的也是这些文件（"You are currently rebasing branch 'child' on '…'"）。

## 四种继续或放弃的方式

`--continue`。把冲突解决好，`git add` 标记为已解决，然后继续：

```bash
echo "o0 main+child" > o0.txt
git add o0.txt
git rebase --continue
```

- `git add o0.txt`：把工作区的内容写进 index 的 stage 0，三个冲突 stage 随之清掉，文件算作已解决。
- `git rebase --continue`：用当前 index 提交，作者沿用 c2。因为这次提交经过了人工解决，git 会打开编辑器
  （编辑 `.git/COMMIT_EDITMSG`），预填 c2 的消息，让你有机会改（实测：例子里换了一个记录参数的编辑器）。
  提交后继续执行 todo 剩下的 c3。

结果 child = o0 m1 m2 m3 m4 c1 c2 c3，`o0.txt` 是 `o0 main+child`（实测）。

`--skip`。丢掉正在重放的提交，继续下一个：

```bash
git rebase --skip
```

c2 不进结果，child = o0 m1 m2 m3 m4 c1 c3，`o0.txt` 保持 `o0 main`（实测）。`--skip` 会把工作区和 index 恢复到 HEAD，
解了一半的冲突也一起丢掉（实测：例子在 `--skip` 前往 `o0.txt` 写了别的内容，之后工作区里是 `o0 main`）。

`--abort`。放弃整个 rebase，把 C 恢复到 `orig-head`：

```bash
git rebase --abort
```

child 回到原来的 tip，sha 逐位相同（实测）。注意 HEAD 回到的是 child，而不是执行 rebase 时所在的分支：
例子在 main 上开始，`--abort` 之后在 child 上（实测）。这与 01 篇讲的"逻辑上先切到 C"一致。

`--quit`。只删掉 `.git/rebase-merge/`，其余什么都不动：

```bash
git rebase --quit
```

HEAD 留在原地，也就是游离在重放了一半的链上（`o0 m1 m2 m3 m4 c1`），child 分支不动（实测）。
用在"已经手动把事情处理好了，只想让 git 忘掉这次 rebase"的时候。HEAD 离开之后，重放了一半的那条链只能从 HEAD 的 reflog 找回。

## 做完以后撤销

rebase 成功结束后，原来的提交还在对象库里，从两个地方能找到（实测）：

- `ORIG_HEAD`：rebase 开始时设成 C 原来的 tip（01 篇第 7 步）。下一次 reset / merge / rebase 会覆盖它，
  中途执行过 `git reset` 之类的命令时也可能已经被改掉（手册：`git-rebase.adoc:85-90`）。
- `child@{1}`：child 的 reflog 往回一步。rebase 只在收尾时更新 child 一次，所以刚做完时 `child@{1}` 就是原 tip：

```text
child@{0} rebase (finish): refs/heads/child onto 1f4c0e6c0c1cff19fab6308480ca22a30e7d9a90
child@{1} commit: c3
```

  之后 child 每动一次（提交、amend、再 rebase），编号都会往后推，这时要看 `git reflog child` 找对应的那一行，
  不要按编号猜（05 篇有一个例子）。

撤销：

```bash
git reset --hard ORIG_HEAD
```

- `--hard`：把当前分支、index、工作区都改成目标提交。工作区里没提交的修改会丢，执行前确认 `git status` 干净。
- `ORIG_HEAD`：目标提交，也可以换成 `child@{1}` 或 reflog 里查到的 sha。

执行时 HEAD 要在 child 上（rebase 刚结束时就是）。实测：`git reset --hard ORIG_HEAD` 之后 child 回到原 tip。
