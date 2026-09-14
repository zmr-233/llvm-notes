# 04 远端存储：多台机器、多个 CI 作业共享缓存

> 核对版本：ccache 4.13.6 与 4.14。「实测」指 [`examples/08-remote-storage`](examples/08-remote-storage/run.sh)：
> file 后端、HTTP 内置实现、HTTP 助手程序 ccache-storage-http-go 0.10、分片、`read-only` / `remote_only` /
> `reshare`、`--trim-dir`；4.14 另测了 `@layout=local` 与 `--dry-run`。
> Redis 与 crsh 后端**未实跑**（本机没有 Redis 服务），相关内容出自官方手册，已逐处标注。

## 1. 是什么

本地缓存目录之外，配置项 `remote_storage` 可以再挂一个或多个后端（空白分隔）。查找顺序是**先本地、后远端**。
远端只存条目（manifest 与结果），统计计数器永远记在本地缓存目录里。

`remote_only = false`（默认）时的交互：

| 本地 | 远端 | 发生什么 |
|---|---|---|
| miss | miss | 编译；写本地；写远端（远端为 `read-only` 时不写） |
| miss | hit | 从远端读；回填本地 |
| hit | — | 从本地读；不碰远端（`reshare = true` 时也写远端） |

`remote_only = true` 时本地不读不写：miss 编译后只写远端，命中只从远端读。

**为什么这样分层**：本地命中是一次文件读取，远端命中是一次网络往返，先本地后远端让最常见的情况最快；
回填本地让同一台机器下次不再走网络；默认本地命中不写远端，免得每次命中都产生写流量。

**实测**（08 的 A–D 段，每台「机器」是一个独立的 `CCACHE_DIR`）：

- A：m1 miss 后，远端目录出现 2 个条目（manifest + 结果）；m2 编译同一文件得到 `remote_storage_hit = 1`，
  本地随即多出 2 个条目；m2 再编一次变成 `local_storage_hit = 1`、`remote_storage_hit = 0`；
- B：`read-only` 的 m3 编一个新文件，miss 前后远端条目数不变；但它照样能从远端读到 m1 存的结果；
- C：`remote_only = true` 的 m4 编两次，第二次远端命中，本地条目数始终为 0；
- D：`reshare = true` 时 m1 本地命中，结果被写进了一个原本空的远端。

## 2. 配置语法

```text
remote_storage = <URL> [属性…] [<URL> [属性…]] …
```

- 属性写成 `键=值`；只写键等于 `键=true`；
- `@键=值` 是**自定义属性**，由具体后端或助手程序解释，ccache 本身不认；
- 值里含 `%`、`|` 或空白时要百分号编码；为兼容旧版，`|` 被当成空格；
- 多个后端可以借多行值语法（4.13+）一行写一个，见 [`conf/remote.conf`](conf/remote.conf)。

通用属性：

| 属性 | 默认 | 作用 |
|---|---|---|
| `read-only` | false | 只读这个后端，不写 |
| `shards` | 空 | 分片名列表，见 §6 |
| `helper` | 空 | 指定助手程序（文件名或完整路径），见 §4.2 |
| `data-timeout` | 10s | 收发数据的超时，每有数据流动就重新计时 |
| `request-timeout` | 1m | 整个请求的超时 |
| `idle-timeout` | 10m | 助手进程在没有客户端活动多久后退出；`0s` 表示常驻 |

时间可带后缀 `ms` `s` `m` `h` `d`。两个超时的默认值是 4.13.5 起调高的（NEWS：为了在高负载机器上更稳）。

## 3. file 后端

**URL**：`file:<目录>` 或 `file://[主机]<目录>`，目录必须以 `/` 开头。典型用途是 NFS 之类的共享目录。

**自定义属性**：

| 属性 | 默认 | 作用 |
|---|---|---|
| `@layout` | `subdirs` | `subdirs`：条目分进 256 个子目录；`flat`：全放在一层；`local`（4.14+）：按本地缓存目录的布局读取，后端自动变为只读 |
| `@umask` | 空 | 覆盖写入时的权限掩码，如 `@umask=002` |
| `@update-mtime` | false | 读到条目时刷新其 mtime |

`@layout=local` 的用途：CI 把自己的**本地**缓存目录同步到共享盘，开发机直接把它挂成只读远端，不必转换格式。
要求该目录里的条目是自包含的——开了 `file_clone` 或 `hard_link` 的缓存不行。实测：08 的 H 段把 m1 的本地缓存目录
当远端，m10 得到 `remote_storage_hit = 1`。

**清理**：ccache **不会**清理任何远端。file 后端要定期修剪：

```bash
ccache --trim-dir /mnt/shared/ccache --trim-max-size 100GiB --trim-method atime
```

- `--trim-dir <目录>`：要修剪的远端目录；
- `--trim-max-size <大小>`：修剪到不超过这个大小，按最近最少使用（LRU）的顺序删；
- `--trim-method atime|mtime`：LRU 依据访问时间（默认）还是修改时间；
- `--trim-recompress <级别>`：修剪时顺便重压缩到这个 zstd 级别；
- `--dry-run`（4.14+）：只打印会删多少，不真删。实测：加 `--dry-run` 后打印的
  `Trimmed 20.5 kB to 0 bytes (-20.5 kB, -5 files)` 与真删时一模一样，但目录里的条目一个没少。

手册特别提醒：**不要**用 `--trim-dir` 修剪本地缓存目录；修本地用 `CCACHE_MAXSIZE=<大小> ccache -c`。

若共享盘以 `noatime` 挂载、访问时间不可靠，一个自然的组合是读者端设 `@update-mtime=true`、修剪端用
`--trim-method mtime`（这是由两个选项的定义推出的用法，未实测）。

## 4. HTTP

### 4.1 内置实现（4.14 已宣布将移除）

**URL**：`http://主机[:端口][/路径]`。**不支持 https**。服务端需要支持 GET、PUT、DELETE。

| 自定义属性 | 默认 | 作用 |
|---|---|---|
| `@layout` | `subdirs` | `subdirs`：键的前两个字符作目录；`flat`：键直接接在路径后；`bazel`：兼容 Bazel HTTP 缓存协议，存在 `/ac/` 下（服务端可能要关闭对 action cache 内容的校验） |
| `@bearer-token` | 空 | `Authorization: Bearer` 头 |
| `@keep-alive` | true | 复用 HTTP 连接 |
| `@header` | 空 | 追加请求头，如 `@header=Content-Type=application/octet-stream` |

实测（08 的 E 段，服务端是 [`http_server.py`](examples/08-remote-storage/http_server.py)）：服务端日志里是
`PUT /cache/6d/87b2425683…`、`GET /cache/fb/b27cda2629…`——`subdirs` 布局下键的前两位成了目录。
ccache 日志先记下 `Could not find remote storage helper program "ccache-storage-http"`，然后才走内置实现。

4.14 手册原文：内置 HTTP 与 Redis 支持「is deprecated and will be removed in the next non-bug-fix ccache version」，
改用下面的助手程序。

### 4.2 storage helper（4.13+）

**是什么**：一个独立的本地常驻进程，名叫 `ccache-storage-<URL 协议名>`（如 `ccache-storage-http`）。
ccache 通过本地 IPC（Unix 套接字或 Windows 命名管道）把读写请求交给它，由它与远端通信。

**为什么这样设计**：

- 协议实现与 ccache 本体解耦——https、各种鉴权、以后的 S3 之类，都能独立开发、独立发版；
- 常驻进程可以保持与远端的连接，免去每次编译都重新建连（每个编译是一个独立的 ccache 进程，本来无法复用连接）。

**查找顺序**：`helper` 属性 → `libexec_dirs` → ccache 可执行文件所在目录 → `PATH`（4.13.1 起 libexec 优先于 `PATH`）。
都找不到时，若有内置实现就退回内置实现，否则报错。

**生命周期**（实测日志，4.13.6）：

```text
Found remote storage helper …/ccache-storage-http
Failed to connect to existing remote storage helper at /run/user/1000/ccache-tmp/storage-http-6dfbb78e…
Spawning storage helper …/ccache-storage-http for /run/user/1000/ccache-tmp/storage-http-6dfbb78e…
```

先试着连接已在运行的助手，连不上就启动一个；配置相同的所有 ccache 进程共用同一个助手。
注意端点在 `$XDG_RUNTIME_DIR/ccache-tmp` 下——实测时 `temporary_dir` 已被设到别处，端点位置没有跟着变。
助手在 `idle-timeout` 后自行退出；`ccache --stop-storage-helpers` 立即停止所有助手。

**已知的助手程序**（2026-09-13 核对 ccache.dev/storage-helpers.html 与各仓库的发布页）：

| 程序 | 协议 | 最新发布 | 备注 |
|---|---|---|---|
| ccache-storage-http-go | `http` `https` | v0.10 | Go 写的参考实现，提供预编译二进制；08 的 G 段用的就是它 |
| ccache-storage-http-cpp | `http` `https` | v0.11 | C++ 写的参考实现 |
| ccache-storage-redis | `redis` `rediss` `redis+unix` | v0.2 | |

安装方式是把二进制放进上面的查找路径，并命名为 `ccache-storage-http`（要支持 https 就再放一份或建链接叫
`ccache-storage-https`）。ccache-storage-http-go 的 README 列出的自定义属性：

| 属性 | 作用 |
|---|---|
| `@bearer-token` / `@bearer-token-file` | Bearer token；后者每次请求从文件读取，token 不必写进配置 |
| `@header` | 追加请求头，可重复 |
| `@use-netrc` / `@netrc-file` | 用 netrc 文件提供的账号密码 |
| `@connection-pool-size` | 最大并发连接数 |
| `@layout` | `subdirs`（默认）/ `flat` / `bazel` |

它还认环境变量 `CRSH_LOGFILE`：把调试日志写到该文件（README 提醒日志不脱敏，含敏感信息）。

### 4.3 crsh 后端（未实跑）

`crsh:<IPC 端点>` 让 ccache 连接一个**由外部启动和管理**的助手进程，而不是自己去启动。手册说用途主要是开发调试助手，
或由服务管理器统一托管助手的特殊部署。storage-helpers 页面给的手动启动方式：

```bash
export CRSH_IPC_ENDPOINT=/tmp/ccache-example.sock   # 助手监听的套接字
export CRSH_URL=http://example.com/cache            # 助手要连接的远端
ccache-storage-http                                  # 前台运行助手
# 另一个终端：
export CCACHE_REMOTE_STORAGE=crsh:/tmp/ccache-example.sock
```

## 5. Redis（未实跑）

内置实现的 URL 形式：`redis://[[用户名:]密码@]主机[:端口][/库号]`、`redis+unix:<套接字路径>[?db=库号]`、
`redis+unix://[[用户名:]密码@localhost]<套接字路径>[?db=库号]`；端口默认 6379，库号默认 0。
ccache 不清理 Redis 里的数据，手册建议在 Redis 侧配置内存上限与 LRU 淘汰策略。内置 Redis 与内置 HTTP 一样已宣布将移除，
替代品是 ccache-storage-redis 助手。

## 6. 分片

```text
remote_storage = http://cache-*.example.com shards=a(3),b(1),c(1.5)
```

URL 里的 `*` 被替换为分片名，得到每个分片的真实地址；括号里是权重，权重为 w 的分片承担 w/总权重 的键空间
（上例 a 占 3/5.5 ≈ 55%），不写默认 1。条目按 rendezvous 哈希（又名最高随机权重哈希）分配：每个键对每个分片算一个分数，
取分数最高者。这种算法的性质是增删一个分片时，只有落在该分片上的键需要换位置。

实测（08 的 F 段）：`http://127.0.0.1:<端口>/shard-* shards=a,b` 下编 8 个文件，产生的对象分落到 `shard-a` 与 `shard-b` 两个目录。

## 7. 不用远端的共享：同机多人共用本地目录（未多账户实测）

手册「Sharing a local cache」给出的条件：同一个缓存目录；`hard_link` 保持 false；所有用户在同一个组；
`umask = 002`；所有人对整个目录可写；目录都设了 setgid 位（`find $CCACHE_DIR -type d | xargs chmod g+s`）；
通常还要设 `base_dir`。配置范例见 [`conf/team-shared.conf`](conf/team-shared.conf)。

把主缓存目录直接放在 NFS 上也可行，但手册提醒可能反而更慢、测试不充分，建议至少把 `temporary_dir` 放在本机；
更推荐的做法是本地缓存 + file 远端。

## 8. 场景速查

| 场景 | 做法 |
|---|---|
| CI 写、开发机只读 | CI：`remote_storage = <URL>`；开发机：`remote_storage = <URL> read-only` |
| 一次性容器，不想留本地缓存 | `remote_only = true` |
| 新搭的远端要先灌数据 | 在已有本地缓存的机器上 `reshare = true` 跑一遍构建 |
| CI 产出的本地缓存目录直接共享 | 4.14+：`remote_storage = file:<目录> @layout=local` |
| https、鉴权 | 装 ccache-storage-http 助手，`@bearer-token-file=<文件>` |

## 9. 安全

- `remote_storage` 在目录级配置文件里属于「不安全」选项，只在 `safe_dirs` 下才允许（[02 §3](02-configuration.md)）；
- 内置 HTTP 是明文；token 用助手的 `@bearer-token-file` 从文件读，而不是写进可能被提交的配置里；
- 远端里的结果会被直接当作编译产物使用，因此**能写远端的人就能往所有读者的构建里放任意目标文件**（由机制推出）。
  给远端设写权限要像给仓库设推送权限一样谨慎；开发机一般只给 `read-only`。

下一篇：[05 诊断与维护](05-diagnostics.md)。
