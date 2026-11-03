#!/bin/bash
/usr/local/bin/wait-x.sh || exit 1

# 时区 / 语言跟随代理出口所在地（TZ=auto、LANGUAGE=auto），结果按会话缓存
if [ "${TZ:-auto}" = auto ] || [ "${LANGUAGE:-}" = auto ]; then
  geo=$(python3 /usr/local/bin/geo-locale.py) && eval "$geo"
fi

extra=()
# Chrome 自带沙箱需要 user namespace。容器以 --security-opt seccomp=unconfined 启动时可用；
# 不可用时自动降级为 --no-sandbox（--test-type 用于隐藏“不受支持的命令行标记”提示条）
if ! unshare -Ur true 2>/dev/null; then
  echo "[chrome] user namespace 不可用，以 --no-sandbox 运行（建议加 --security-opt seccomp=unconfined）" >&2
  extra+=(--no-sandbox --test-type)
fi

# CHROME_CPUS 由会话画像随机决定，限制可用 CPU = 改变 navigator.hardwareConcurrency
cpus=(); [ -n "${CHROME_CPUS:-}" ] && cpus=(taskset -c "$CHROME_CPUS")

# 用户目录在每次容器启动时由 entrypoint 清空
# shellcheck disable=SC2086
exec "${cpus[@]}" /usr/bin/google-chrome-stable \
  --user-data-dir="$HOME/profile" \
  --no-first-run \
  --no-default-browser-check \
  --password-store=basic \
  --start-maximized \
  --log-level=3 \
  "${extra[@]}" \
  ${CHROME_ARGS:-} \
  "${START_URL:-about:blank}"
