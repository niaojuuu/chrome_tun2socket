#!/bin/bash
# 等待 X server (:1) 就绪
for _ in $(seq 1 100); do
  xdpyinfo -display :1 >/dev/null 2>&1 && exit 0
  sleep 0.2
done
echo "X server :1 not ready" >&2
exit 1
