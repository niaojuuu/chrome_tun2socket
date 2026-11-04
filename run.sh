#!/bin/bash
# 多实例管理脚本：每个实例 = 一个 Chrome + 一个独立代理出口 + 一个 noVNC 端口
#
#   ./run.sh start   <名字> <端口> [代理地址] [VNC密码]
#   ./run.sh restart <名字>        # 重启 = 全新会话（清空所有浏览记录）
#   ./run.sh stop    <名字>        # 停止并删除
#   ./run.sh list
#   ./run.sh logs    <名字>
#
# 代理地址可省略：省略（或填 direct）= 直连模式，容器用 ECS 自己的 IP 出网，不经过代理
#
# 可选环境变量（start 时生效）：TZ LANGUAGE RESOLUTION CPUS FONTS START_URL DNS
#   DNS_OVER_TCP CHROME_ARGS BYPASS_CIDRS LOGLEVEL（含义见 README）
#   BIND_ADDR   端口监听地址，默认 0.0.0.0；只想通过 SSH 隧道访问时设为 127.0.0.1
#   SANDBOX     1(默认)=开启 Chrome 沙箱（容器使用 seccomp=unconfined）；0=使用 Docker 默认 seccomp
#   IMAGE       镜像名，默认 chrome-tun2socks:latest
set -euo pipefail

IMAGE=${IMAGE:-chrome-tun2socks:latest}
PREFIX=cb-
LABEL=chrome-tun2socks

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

cmd=${1:-}; shift || true
case "$cmd" in
  start)
    [ $# -ge 2 ] || usage
    name=$1 port=$2; shift 2
    proxy="" vncpass=""
    if [ $# -ge 1 ]; then
      case "$1" in
        *://*) proxy=$1; shift ;;                 # 代理地址
        direct) proxy="direct://"; shift ;;        # 直连，不经过外部代理
        *) echo "第三个参数必须是代理地址（含 ://）或 direct；VNC 密码请放在第四个参数" >&2; usage ;;
      esac
    fi
    [ $# -le 1 ] || { echo "参数过多" >&2; usage; }
    if [ $# -ge 1 ]; then vncpass=$1; fi
    # 放在删除旧实例之前检查，避免环境有问题时把正在运行的实例删掉
    docker info >/dev/null 2>&1 || { echo "无法连接 Docker：请确认已安装并启动，且当前用户有权限（可用 root 执行）" >&2; exit 1; }
    docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "找不到镜像 $IMAGE，请先在本目录构建：docker build -t $IMAGE ." >&2; exit 1; }
    [ -c /dev/net/tun ] || { echo "宿主机没有 /dev/net/tun，请先执行：modprobe tun" >&2; exit 1; }
    args=(
      -d --name "${PREFIX}${name}" --label "$LABEL=1"
      --restart unless-stopped
      --cap-add NET_ADMIN --device /dev/net/tun
      --sysctl net.ipv6.conf.all.disable_ipv6=1
      --sysctl net.ipv6.conf.default.disable_ipv6=1
      --shm-size 2g
      -p "${BIND_ADDR:-0.0.0.0}:${port}:6080"
    )
    # 不传 PROXY = 直连模式，容器内由 entrypoint 默认成 direct://
    if [ -n "$proxy" ]; then args+=(-e PROXY="$proxy"); fi
    [ "${SANDBOX:-1}" = 1 ] && args+=(--security-opt seccomp=unconfined)
    [ -n "$vncpass" ] && args+=(-e VNC_PASSWORD="$vncpass")
    for v in TZ LANGUAGE RESOLUTION CPUS FONTS START_URL DNS DNS_OVER_TCP CHROME_ARGS BYPASS_CIDRS LOGLEVEL; do
      [ -n "${!v:-}" ] && args+=(-e "$v=${!v}")
    done
    docker rm -f "${PREFIX}${name}" >/dev/null 2>&1 || true
    docker run "${args[@]}" "$IMAGE" >/dev/null
    sleep 3
    docker logs "${PREFIX}${name}" 2>&1 | grep '\[entrypoint\]' || true
    echo "已启动：http://<ECS公网IP>:${port}/"
    ;;
  restart)
    [ $# -ge 1 ] || usage
    docker restart "${PREFIX}$1" >/dev/null && echo "已重启（全新会话）：$1"
    ;;
  stop)
    [ $# -ge 1 ] || usage
    docker rm -f "${PREFIX}$1" >/dev/null && echo "已删除：$1"
    ;;
  logs)
    [ $# -ge 1 ] || usage
    docker logs --tail 100 -f "${PREFIX}$1"
    ;;
  list)
    docker ps -a --filter "label=$LABEL" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    ;;
  *) usage ;;
esac
