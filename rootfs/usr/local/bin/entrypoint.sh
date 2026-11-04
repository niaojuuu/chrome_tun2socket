#!/bin/bash
# 容器启动入口：
#   1. 清空浏览器用户目录和临时目录（保证每次启动都是全新状态，无上次会话痕迹）
#   2. 生成本次会话的随机画像（分辨率 / CPU 核数 / 字体），让每次会话的指纹不同
#   3. 配置 tun0 + 策略路由，把所有出站流量交给 tun2socks（$PROXY，留空 = 直连不经过代理）
#   4. 启动 supervisord（tun2socks / Xvnc / openbox / chrome / noVNC）
set -euo pipefail

log() { echo "[entrypoint] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

TUN=tun0
TUN_ADDR=198.18.0.1/15
FWMARK=0x22b       # tun2socks 自身流量打的标记
BYPASS_TABLE=100   # 走 eth0 的路由表
NOVNC_PORT=6080    # 容器内 noVNC 端口（与 supervisor 配置一致）

PROXY=${PROXY:-}
if [ -z "$PROXY" ]; then
  # 不配代理 = 直连：流量照样走 tun0 → tun2socks，只是上游不连外部代理
  PROXY="direct://"
  log "未设置 PROXY，直连模式（不经过外部代理）"
fi
[ -c /dev/net/tun ] || die "/dev/net/tun 不存在，请加 --device /dev/net/tun"
DNS=${DNS:-1.1.1.1,8.8.8.8}
DNS_OVER_TCP=${DNS_OVER_TCP:-1}
BYPASS_CIDRS=${BYPASS_CIDRS:-}

# ---------------------------------------------------------------- 1. 全新会话
reset_session() {
  # Chrome 只会写 /home/chrome、/tmp、/dev/shm 三处（已实测），全部清空
  rm -rf /home/chrome /tmp/* /tmp/.[!.]* /dev/shm/* 2>/dev/null || true
  install -d -o chrome -g chrome -m 700 /home/chrome /home/chrome/.vnc
  install -d -m 1777 /tmp/.X11-unix

  case "${VNC_PASSWORD:-}" in
    none) log "VNC_PASSWORD=none，noVNC 不设密码（请确保只通过 SSH 隧道/白名单访问）" ;;
    "")
      VNC_PASSWORD=$(set +o pipefail; tr -dc 'A-Za-z0-9' </dev/urandom | head -c 8)
      log "未设置 VNC_PASSWORD，已随机生成：${VNC_PASSWORD}" ;;
  esac
  if [ "${VNC_PASSWORD}" != none ]; then
    [ ${#VNC_PASSWORD} -le 8 ] || log "注意：VNC 协议只使用密码的前 8 位"
    printf '%s\n' "$VNC_PASSWORD" | vncpasswd -f > /home/chrome/.vnc/passwd
    chown chrome:chrome /home/chrome/.vnc/passwd
    chmod 600 /home/chrome/.vnc/passwd
  fi
  export VNC_PASSWORD="<hidden>"
}

# ---------------------------------------------------------------- 2. 会话画像
new_session_profile() {
  local profile
  profile=$(python3 /usr/local/bin/session-profile.py) || die "生成会话画像失败"
  eval "$profile"
  # PROXY 中的 {SESSION} 每次启动替换为新的随机串：住宅代理的“粘性会话”参数，
  # 例如 socks5://user-session-{SESSION}:pass@gw.example.com:1080 → 每次重启换一个出口 IP
  if [[ $PROXY == *"{SESSION}"* ]]; then
    PROXY=${PROXY//\{SESSION\}/$(set +o pipefail; tr -dc 'a-z0-9' </dev/urandom | head -c 10)}
  fi
}

# ---------------------------------------------------------------- 3. 网络
is_ipv4() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# 在切换路由之前把代理域名解析成 IP，避免“解析代理地址也要走代理”的死循环
resolve_proxy() {
  local scheme rest userinfo="" after hostport suffix host port="" ip
  scheme=${PROXY%%://*}
  rest=${PROXY#*://}
  if [ "$scheme" = "$PROXY" ]; then die "PROXY 格式错误：$PROXY"; fi
  if [ "$scheme" = direct ] || [ -z "$rest" ]; then PROXY_EFFECTIVE=$PROXY; return; fi

  if [[ $rest == *@* ]]; then userinfo=${rest%@*}; after=${rest##*@}; else after=$rest; fi
  hostport=${after%%[/?]*}
  suffix=${after#"$hostport"}
  if [[ $hostport == *:* ]]; then host=${hostport%:*}; port=${hostport##*:}; else host=$hostport; fi

  if is_ipv4 "$host"; then
    ip=$host
  else
    ip=$(getent ahostsv4 "$host" | awk 'NR==1{print $1}')
    [ -n "$ip" ] || die "无法解析代理地址：$host"
    log "代理域名 $host -> $ip"
  fi
  PROXY_EFFECTIVE="${scheme}://${userinfo:+${userinfo}@}${ip}${port:+:${port}}${suffix}"
}

setup_network() {
  local eth gw eth_cidr eth_ip
  ip rule add pref 1 fwmark 0x1 prohibit 2>/dev/null && ip rule del pref 1 \
    || die "缺少 NET_ADMIN 权限，请加 --cap-add NET_ADMIN"
  gw=$(ip -4 route show default | awk '/ via /{print $3; exit}')
  eth=$(ip -4 route show default | awk '/ via /{print $5; exit}')
  if [ -z "$gw" ]; then  # 同一网络命名空间里重复执行时，从 bypass 表取回网关
    gw=$(ip -4 route show default table "$BYPASS_TABLE" 2>/dev/null | awk '/ via /{print $3; exit}')
    eth=$(ip -4 route show default table "$BYPASS_TABLE" 2>/dev/null | awk '/ via /{print $5; exit}')
  fi
  [ -n "$gw" ] && [ -n "$eth" ] || die "找不到默认网关（容器需要使用 bridge 网络）"
  eth_cidr=$(ip -4 -o addr show dev "$eth" | awk '{print $4; exit}')
  eth_ip=${eth_cidr%/*}
  log "eth=$eth ip=$eth_ip gw=$gw"

  # bypass 表，只有两类流量允许从 eth0 直接出去：
  #   pref 100: tun2socks 自身的流量（带 fwmark，即到代理服务器的连接）
  #   pref 110: noVNC 入站连接的回包（源 eth0 IP + 源端口 6080）
  # 其余流量（包括 WebRTC 绑定 eth0 IP 发出的包）一律进 tun0，不会泄露真实 IP
  ip route flush table "$BYPASS_TABLE" 2>/dev/null || true
  ip route show table main dev "$eth" scope link | while read -r r; do
    ip route add $r dev "$eth" table "$BYPASS_TABLE"
  done
  ip route add default via "$gw" dev "$eth" table "$BYPASS_TABLE"
  ip rule del pref 100 2>/dev/null || true
  ip rule del pref 110 2>/dev/null || true
  ip rule add pref 100 fwmark "$FWMARK" lookup "$BYPASS_TABLE"
  ip rule add pref 110 from "$eth_ip" ipproto tcp sport "$NOVNC_PORT" lookup "$BYPASS_TABLE"

  # 可选：不走代理的网段（例如 VPC 内网），逗号分隔
  local c
  for c in ${BYPASS_CIDRS//,/ }; do
    ip route replace "$c" via "$gw" dev "$eth"
    log "bypass: $c"
  done

  # tun 设备 + 默认路由切到 tun0。tun2socks 挂掉时 tun0 仍在、默认路由仍指向它，
  # 流量会被丢弃而不是直连泄露（fail-closed）
  ip link del "$TUN" 2>/dev/null || true
  ip tuntap add mode tun dev "$TUN" || die "创建 $TUN 失败（检查 --device /dev/net/tun 和 NET_ADMIN）"
  ip addr add "$TUN_ADDR" dev "$TUN"
  ip link set dev "$TUN" up
  ip route del default 2>/dev/null || true
  ip route add default dev "$TUN"

  # DNS：改用公共 DNS，经由 tun → 代理出去；DNS_OVER_TCP=1 时强制 TCP，
  # 兼容不支持 UDP 的 socks5 代理
  local d conf=""
  for d in ${DNS//,/ }; do conf+="nameserver $d"$'\n'; done
  if [ "$DNS_OVER_TCP" = 1 ]; then conf+="options use-vc"$'\n'; fi
  printf '%s' "$conf" > /etc/resolv.conf
}

reset_session
new_session_profile
resolve_proxy
setup_network
export PROXY_EFFECTIVE FWMARK TUN
log "proxy: ${PROXY_EFFECTIVE//\/\/*@/\/\/***@}"
log "noVNC: http://<ECS公网IP>:<映射端口>/"

exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
