#!/bin/bash
# 用法：tests/fingerprint-test.sh <容器名> [轮数，默认 3]
# 每一轮：docker restart（模拟全新会话）→ 在容器内真实运行的 Chrome 中打开检测页 → 收集结果
# 最后对比各轮：痕迹应全部为空；指纹项标出“每次相同”的部分（= 可被用于关联的部分）
set -euo pipefail
C=$1; N=${2:-3}; DIR=$(cd "$(dirname "$0")" && pwd); TMP=$(mktemp -d)

collect() {
  for _ in $(seq 60); do
    docker exec "$C" supervisorctl status chrome 2>/dev/null | grep -q RUNNING && break; sleep 1
  done
  sleep 4
  docker exec "$C" mkdir -p /tmp/fp
  docker cp "$DIR/fp.html" "$C:/tmp/fp/fp.html"; docker cp "$DIR/fp_server.py" "$C:/tmp/fp/fp_server.py"
  docker exec "$C" chown -R chrome:chrome /tmp/fp
  docker exec -d -u chrome "$C" python3 /tmp/fp/fp_server.py /tmp/fp/report.json
  sleep 1
  docker exec -u chrome -e DISPLAY=:1 "$C" google-chrome-stable --user-data-dir=/home/chrome/profile \
    http://127.0.0.1:8000/ >/dev/null 2>&1 || true
  for _ in $(seq 60); do
    docker exec "$C" test -s /tmp/fp/report.json 2>/dev/null && break; sleep 1
  done
  docker exec "$C" cat /tmp/fp/report.json > "$TMP/$1.json"
  # 第二次打开：同一会话内痕迹应该存在（证明检测方法本身有效）
  if [ "$1" = 1 ]; then
    docker exec "$C" rm -f /tmp/fp/report.json
    docker exec -u chrome -e DISPLAY=:1 "$C" google-chrome-stable --user-data-dir=/home/chrome/profile \
      http://127.0.0.1:8000/ >/dev/null 2>&1 || true
    for _ in $(seq 60); do docker exec "$C" test -s /tmp/fp/report.json 2>/dev/null && break; sleep 1; done
    docker exec "$C" cat /tmp/fp/report.json > "$TMP/same-session.json"
  fi
}

for i in $(seq 1 "$N"); do
  [ "$i" -gt 1 ] && docker restart "$C" >/dev/null
  echo "第 $i 轮..." >&2; collect "$i"
done
python3 - "$TMP" "$N" <<'PY'
import json, sys
d, n = sys.argv[1], int(sys.argv[2])
runs = [json.load(open(f"{d}/{i}.json")) for i in range(1, n + 1)]
same = json.load(open(f"{d}/same-session.json"))
print("== 检测方法自检（同一会话内第二次打开，应能看到痕迹）:", same["previousSessionTraces"])
print("\n== 重启后上次会话的痕迹（应全部为 None/False）")
for i, r in enumerate(runs, 1): print(f"  第{i}轮:", r["previousSessionTraces"])
print("\n== 指纹项对比（SAME = 每次重启都相同，可用于关联）")
for k in runs[0]["fingerprint"]:
    vals = [str(r["fingerprint"].get(k)) for r in runs]
    tag = "SAME" if len(set(vals)) == 1 else "diff"
    print(f"  [{tag}] {k:20s} " + " | ".join(v[:60] for v in vals))
PY
rm -rf "$TMP"
