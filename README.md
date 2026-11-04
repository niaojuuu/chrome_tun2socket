# chrome-tun2socks：阿里云 ECS 上的一次性 Chrome 容器

- **Google Chrome**：在本地浏览器里打开 `http://ECS公网IP:端口/` 即可使用（noVNC，不需要装客户端）
- **启动时指定代理**：`PROXY=socks5://...`，容器内由 tun2socks 接管**全部流量**（TCP/UDP/DNS），而不只是给浏览器设置代理
- **每次启动都是全新的**：无论是 `docker restart`、ECS 重启还是重建容器，浏览记录、Cookie、缓存都会被清空
- **每次启动指纹都不同**：屏幕、CPU 核数、字体、Canvas 每次随机；时区和语言默认固定为 `Etc/UTC`、美国英语（详见「四、防关联」）

```
 你的电脑浏览器 ──HTTP/WebSocket──▶ ECS:6081 ─▶ 容器[noVNC ─ Xvnc ─ Chrome]
                                                         │ 全部出站流量
                                                         ▼
                                                tun0 ─▶ tun2socks ─▶ 你的代理 ─▶ 互联网
```

---

## 一、ECS 怎么选

| 项目 | 建议 | 原因 |
|---|---|---|
| **方案** | **Docker 容器**，不用虚拟机 | ECS 本身就是虚拟机，再跑 KVM 需要嵌套虚拟化（只有弹性裸金属等少数规格支持），贵且慢。容器秒级启动，天然适合"用完即弃" |
| **CPU 架构** | **x86_64（Intel / AMD）** | Google Chrome 官方 Linux 版只提供 amd64。**不要选倚天 ARM 规格**（g8y / c8y / r8y 等），否则只能退回 Chromium / Firefox |
| **规格族** | 通用算力型 u1、经济型 e，或企业级 c/g 系列（如 c8i、g8i、c8a 等 x86 规格） | **不要选突发性能 t5/t6**：Chrome 很吃 CPU，积分耗尽后会卡到无法使用 |
| **配置** | 每个 Chrome 实例按 **1 vCPU + 2 GiB 内存** 估算：1–2 个实例用 2核4G；3–5 个用 4核8G；6–10 个用 8核16G | 打开很重的网页时适当加配。想让 CPU 核数这一项指纹也每次随机，宿主机至少需要 4 核 |
| **系统盘** | 40 GiB ESSD Entry / PL0 | 镜像约 2 GB，其余空间留给 Docker |
| **操作系统** | Alibaba Cloud Linux 3 或 Ubuntu 22.04 / 24.04 | 都有 Docker 和 tun 支持 |
| **地域** | 代理在海外：选**香港 / 新加坡**；代理和你都在国内：选离你近的国内地域 | 海外地域拉取 Docker Hub、GitHub、Google 的资源不受影响，也免备案。国内地域需要配置镜像加速（见下文） |
| **公网带宽** | 按使用流量计费，峰值 20–100 Mbps | noVNC 每个活跃会话大约需要 1–5 Mbps；阿里云入方向流量免费，出方向按量计费 |
| **省钱** | 不需要长期运行时可以用**抢占式实例** | 本方案无状态，实例被回收也不会丢数据 |
| **安全组** | 入方向只放行**你自己的 IP**：22 端口，以及 noVNC 端口段（如 6081–6099） | noVNC 只有一个 8 位 VNC 密码，不要对 0.0.0.0/0 开放 |

---

## 二、部署

### 1. 安装 Docker

Alibaba Cloud Linux 3：

```bash
dnf -y install dnf-plugins-core
dnf config-manager --add-repo=https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo
dnf -y install dnf-plugin-releasever-adapter --repo alinux3-plus
dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin git --nobest
systemctl enable --now docker
```

Ubuntu：

```bash
apt-get update && apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.aliyun.com/docker-ce/linux/ubuntu $(. /etc/os-release; echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin git
```

确认 tun 设备存在：`ls /dev/net/tun`（如果没有，执行 `modprobe tun`）。

> **国内地域**：Docker Hub 访问不稳定，需要在「容器镜像服务 ACR → 镜像工具 → 镜像加速器」获取加速地址，写入 `/etc/docker/daemon.json` 的 `registry-mirrors`。
> `ghcr.io`（tun2socks 镜像）如果拉不动，可以在海外机器上构建好镜像，推到 ACR 后再拉取。

### 2. 把代码放到服务器

二选一：

```bash
# 代码已推送到远程仓库
git clone <仓库地址> chrome-tun2socks && cd chrome-tun2socks

# 或者在已有代码的机器上，从项目目录直接复制过去
tar czf - --exclude=.git --exclude=.env . | ssh root@ECS公网IP 'mkdir -p chrome-tun2socks && tar xzf - -C chrome-tun2socks'
```

### 3. 构建镜像

`run.sh` 只负责启动容器，不会自动构建，第一次必须先构建：

```bash
cd chrome-tun2socks
docker build -t chrome-tun2socks:latest .
# 国内地域加速 apt：
docker build --build-arg APT_MIRROR=mirrors.aliyun.com -t chrome-tun2socks:latest .
```

要升级 Chrome 版本，重新执行 `docker build --pull --no-cache ...` 即可。

### 4. 启动（两种方式任选一种）

**方式 A：`run.sh`（推荐，适合多实例、每个实例用不同代理）**

```bash
./run.sh start shop1 6081 'socks5://user:pass@1.2.3.4:1080' Pass1234
./run.sh start shop2 6082 'http://user:pass@5.6.7.8:8080'  Pass5678
TZ=America/Los_Angeles ./run.sh start us1 6083 'socks5://...' Pass0000

./run.sh list               # 查看所有实例
./run.sh restart shop1      # 重启 = 全新会话
./run.sh stop shop1         # 删除
./run.sh logs shop1
```

**方式 B：docker compose**

```bash
cp .env.example .env && vi .env      # 填写 PROXY1、VNC_PASSWORD
docker compose up -d --build
docker compose restart browser1      # 全新会话
```

### 5. 使用

在本地浏览器打开 `http://ECS公网IP:6081/`，输入 VNC 密码，就能看到已经打开的 Chrome。
Chrome 启动时会打开 `START_URL` 里的网址，默认是三个标签页，其中 `https://ipinfo.io/json` 可以用来核对出口 IP 是否是代理的 IP。关掉 Chrome 窗口后它会自动重新打开。

---

## 三、参数（容器环境变量）

| 变量 | 默认值 | 说明 |
|---|---|---|
| `PROXY` | **必填** | tun2socks 代理地址：`socks5://u:p@host:port`、`http://...`、`ss://method:pass@host:port`、`socks4://...`。密码中的特殊字符需要 URL 编码（`@`→`%40`、`:`→`%3A`）。域名会在启动时解析。地址中的 `{SESSION}` 会在每次启动时替换为新的随机串 |
| `VNC_PASSWORD` | 随机 | 只有前 8 位有效。留空时每次启动随机生成，并打印到 `docker logs`；设为 `none` 表示不设密码（仅在使用 SSH 隧道时这样做） |
| `TZ` | `Etc/UTC` | 容器和 Chrome 的时区。可以改成其他时区，如 `America/New_York`；`auto` = 经代理查询出口 IP 所在地并自动匹配 |
| `LANGUAGE` | `en_US:en` | Chrome 界面语言和 Accept-Language，默认美国英语；中文用 `zh_CN:zh`；`auto` = 跟随出口 IP 所在国家 |
| `RESOLUTION` | `random` | 每次会话从常见分辨率中随机选取；也可以写死，如 `1920x1080`。noVNC 会在本地缩放显示 |
| `CPUS` | `random` | 网页看到的 CPU 核数（`navigator.hardwareConcurrency`），从 2/4/6/8… 中随机选取，不超过宿主机的核数；也可以写死，如 `4`，或设为 `all` |
| `FONTS` | `random` | 每次会话随机启用字体池的一部分，并随机选择字体微调方式（影响字体列表和 Canvas 指纹）；`system` = 不做随机 |
| `START_URL` | `https://claude.ai/login https://jjyycccai.cn https://ipinfo.io/json` | Chrome 启动时打开的网址，多个用空格分隔，每个一个标签页 |
| `DNS` | `1.1.1.1,8.8.8.8` | 经由代理访问的 DNS 服务器 |
| `DNS_OVER_TCP` | `1` | 通过 TCP 查询 DNS，兼容不支持 UDP 的 socks5 代理 |
| `BYPASS_CIDRS` | 空 | 不走代理的网段，逗号分隔，例如 VPC 内网 `172.16.0.0/12` |
| `CHROME_ARGS` | 空 | 额外的 Chrome 启动参数，例如 `--incognito`、`--window-size=...` |
| `LOGLEVEL` | `warn` | tun2socks 日志级别 |

---

## 四、防关联：每次重启后，网站能否认出是同一个浏览器？

网站把两次访问关联起来，主要靠三类信息。下面分别说明本方案的处理方式和做不到的地方：

**1. 存储痕迹（Cookie、localStorage、IndexedDB、缓存、HSTS、Service Worker 等）：已完全清除**
- Chrome 只会写 `/home/chrome`、`/tmp`、`/dev/shm` 三个位置（实测扫描全盘确认），每次启动全部清空
- `docker restart`、ECS 重启后自动拉起、重建容器，得到的都是全新会话

**2. 网络身份（IP）：取决于代理**
- 如果每次重启后出口 IP 不变，网站只凭 IP 就能关联，其他措施都没有意义
- 住宅代理一般支持"会话参数"，可以写成 `socks5://user-session-{SESSION}:pass@gw:port`，这样每次重启都会换一个出口 IP
- 时区默认固定为 `Etc/UTC`，不随 IP 变化。如果出口 IP 所在地不用 UTC（比如美国），网站能看到时区和 IP 不一致；想让两者匹配可以设 `TZ=auto`

**3. 设备指纹：部分可变，部分无法改变**

| 指纹项 | 每次重启 | 说明 |
|---|---|---|
| 屏幕分辨率 / 窗口尺寸 | 随机 | 从常见分辨率中按占比抽取；noVNC 使用本地缩放，你电脑的窗口大小不会传到远端 |
| 字体列表 | 随机 | 字体池里约 12 组字体按概率组合 |
| Canvas | 随机 | 字体微调方式随机，只有 3 种取值，所以不同会话可能撞上相同的值。靠原生渲染差异实现，没有注入 JS，因此不存在函数被改写的痕迹（未用第三方检测工具实测） |
| CPU 核数 | 随机 | 宿主机核数需要 ≥ 4 才有变化空间（2 核机器只能是 2） |
| 时区 / 语言 | **默认不变** | 固定为 `Etc/UTC`、`en-US`；设 `TZ=auto`、`LANGUAGE=auto` 后跟随出口 IP |
| **音频指纹、WebGL、UA、内存** | **不变** | 原版 Chrome 无法修改。这些值对同一 Chrome 版本、同类机器的所有用户都相同，信息量较低，但会暴露"这是同一类环境"（Linux 云主机、没有 GPU） |

自检方法：`tests/fingerprint-test.sh <容器名> 3` 会连续重启 3 次，在真实运行的 Chrome 中采集指纹并对比，输出哪些项每次相同。这个脚本只比较常见指纹项的原始值，结果不代表能骗过商业指纹服务。也可以手动打开 browserleaks.com、creepjs、amiunique.org 等网站，在重启前后对比。

**做不到的事，需要知道：**
- **同一宿主机上的多个实例**：音频、WebGL 等不变项是一样的。强力的反欺诈系统（模糊匹配）仍可能把它们归为"同一类环境"，只是无法精确对应到某一次会话
- **WebGL**：新版 Chrome 在没有 GPU 时默认禁用 WebGL。可以用 `CHROME_ARGS=--enable-unsafe-swiftshader` 开启，但渲染器名称会显示为 `SwiftShader`（软件渲染）。两种状态都比较少见
- **要让 Canvas、音频、WebGL 的数值也每次随机**，需要浏览器内核层面的支持：例如 Brave（基于 Chromium，内置按会话、按站点的指纹随机化），或者专门的指纹浏览器。原版 Chrome 做不到；用 JS 扩展去改反而容易被检测出来
- **行为层面**：登录同一个账号、相同的操作习惯、相同的书签或收货信息，都会直接关联，这和浏览器无关

## 五、实现说明

**全局代理与防泄露**
- 容器内创建 `tun0`，默认路由指向 tun0，所有进程的流量都交给 tun2socks 转发
- 只有两类流量可以从 eth0 直接出去：tun2socks 自己连代理服务器的流量（用 fwmark 区分），以及 noVNC 的回包（源端口 6080）。其余流量，包括 WebRTC 绑定 eth0 地址发出的包，都只能进 tun0
- **fail-closed**：代理断开或 tun2socks 崩溃时网络直接不通，不会退回直连而暴露 ECS 的 IP
- DNS 改为公共 DNS，并通过代理以 TCP 方式查询；IPv6 已关闭；Chrome 策略关闭了 QUIC（避免依赖 UDP），WebRTC 只使用默认路由所在的网卡

**Chrome 沙箱**
- 默认以 `--security-opt seccomp=unconfined` 运行，这样 Chrome 自带的沙箱（user namespace + seccomp-bpf）可以生效。对于访问任意网站的浏览器来说，这比 Docker 的默认 seccomp 更重要
- 如果不加这个选项（`SANDBOX=0 ./run.sh ...`），或者宿主机禁止 user namespace，Chrome 会自动降级为 `--no-sandbox` 运行，日志中会给出提示
- 在 Ubuntu 24.04 宿主机上如果看到降级提示，可以执行 `sysctl -w kernel.apparmor_restrict_unprivileged_userns=0`

---

## 六、常见问题

- **能复制粘贴吗？** 文字可以，本地和远端 Chrome 之间直接用 Ctrl+C / Ctrl+V（macOS 粘贴用 Cmd+V，复制用 Ctrl+C），单次上限 10MB。VNC 协议只能传纯文字，**图片、文件和 Word 里的格式传不过去**。为了防止远端网页在后台改写你电脑的剪贴板，只有在你按下复制键或点击鼠标后的 3 秒内，远端内容才会写回本地；其他时候内容只显示在 noVNC 左侧的「剪贴板」面板里。
- **粘贴账号密码安全吗？** 不要在 `http://ECS公网IP:端口` 这种普通 HTTP 地址上输入或粘贴密码：noVNC 的连接没有加密，VNC 密码只保护登录这一步，之后的屏幕画面、键盘输入和剪贴板内容都是明文传输，途中可以被窃听。请改用 SSH 隧道或 HTTPS（见下面「想要 HTTPS 访问？」）。
- **怎么输入中文？** noVNC 无法使用本地电脑的输入法。可以在本地打好字，再 Ctrl+V 粘贴进去。
- **代理不支持 UDP 会怎样？** 网页浏览不受影响（DNS 走 TCP、QUIC 已关闭）。WebRTC、UDP 游戏之类的功能会失败。
- **Docker 网段和 VPC 网段冲突？** 如果 VPC 交换机用的是 `172.17.x.x`，需要在 `/etc/docker/daemon.json` 中设置 `"bip": "10.200.0.1/24"` 修改 Docker 网段。
- **想要 HTTPS 访问？** 在 ECS 上用 Nginx / Caddy 反向代理到对应端口（需要支持 WebSocket），或者干脆只用 SSH 隧道：`BIND_ADDR=127.0.0.1 ./run.sh start ...`，然后在本地执行 `ssh -L 6081:127.0.0.1:6081 root@ECS`，打开 `http://localhost:6081/`。
- **想换成 Firefox？** 在 x86 机器上不需要。如果一定要用 ARM 实例，可以把 Dockerfile 中的 Chrome 安装改为 `firefox-esr`，并相应修改 `svc-chrome.sh`。
