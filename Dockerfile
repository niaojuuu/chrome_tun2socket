# syntax=docker/dockerfile:1
#
# Google Chrome + noVNC + tun2socks，一次性（无状态）浏览器容器
# 仅支持 x86_64（Google Chrome 官方 Linux 版只有 amd64）
#
ARG TUN2SOCKS_IMAGE=ghcr.io/xjasonlyu/tun2socks:v2.7.0

FROM ${TUN2SOCKS_IMAGE} AS tun2socks

FROM debian:trixie-slim

ARG DEBIAN_FRONTEND=noninteractive
# 国内 ECS 构建可加速：--build-arg APT_MIRROR=mirrors.aliyun.com
ARG APT_MIRROR=

RUN set -eux; \
    if [ -n "$APT_MIRROR" ]; then \
      sed -i "s|deb.debian.org|${APT_MIRROR}|g" /etc/apt/sources.list.d/debian.sources; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl iproute2 procps \
      supervisor \
      tigervnc-standalone-server tigervnc-tools \
      novnc websockify \
      openbox x11-utils \
      locales tzdata \
      fonts-noto-cjk fonts-noto-color-emoji fonts-liberation \
      `# 字体池：每次会话随机启用其中一部分（见 session-profile.py）` \
      fonts-dejavu-core fonts-urw-base35 fonts-freefont-ttf fonts-cantarell \
      fonts-open-sans fonts-lato fonts-roboto-unhinted \
      fonts-crosextra-carlito fonts-crosextra-caladea; \
    curl -fsSL -o /tmp/chrome.deb \
      https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb; \
    apt-get install -y --no-install-recommends /tmp/chrome.deb; \
    rm -f /tmp/chrome.deb; \
    sed -i -e 's/^# *\(zh_CN.UTF-8\)/\1/' -e 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen; \
    locale-gen; \
    useradd -m -u 1000 -s /bin/bash chrome; \
    rm -rf /var/lib/apt/lists/*

COPY --from=tun2socks /usr/bin/tun2socks /usr/local/bin/tun2socks
COPY --chmod=0755 rootfs/ /
# 在 noVNC 启动脚本之前加载剪贴板桥接，确保它先于自动连接生效
RUN sed -i 's|^\( *\)<script type="module">$|\1<script type="module" src="clipboard-bridge.js"></script>\n&|' /usr/share/novnc/vnc.html; \
    grep -q clipboard-bridge /usr/share/novnc/vnc.html

# 运行时可覆盖的参数（详见 README）
# random / auto = 每次会话随机 / 跟随代理出口自动匹配
ENV DNS="1.1.1.1,8.8.8.8" \
    DNS_OVER_TCP=1 \
    BYPASS_CIDRS="" \
    RESOLUTION="random" \
    CPUS="random" \
    FONTS="random" \
    START_URL="https://ipinfo.io/json" \
    CHROME_ARGS="" \
    TZ="Etc/UTC" \
    LANG="en_US.UTF-8" \
    LANGUAGE="en_US:en" \
    LOGLEVEL="warn"

EXPOSE 6080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
