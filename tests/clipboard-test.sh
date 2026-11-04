#!/bin/bash
# 端到端测试本地与远端 Chrome 之间的复制粘贴。用两个容器模拟：
#   client = 你电脑上的浏览器（打开 noVNC），remote = 远端 Chrome
# 操作 client 用的是 xdotool 发出的真实键盘/鼠标事件，这样才会触发浏览器真实的 paste 行为。
# 用法：tests/clipboard-test.sh secure    # 安全上下文（HTTPS / localhost，如 Codespaces 地址、SSH 隧道）
#       tests/clipboard-test.sh insecure  # 普通 HTTP（如 http://ECS公网IP:端口）
set -uo pipefail
MODE=${1:-secure}; PORT=16110; PW=cliptest; IMG=chrome-tun2socks:cliptest
R=cliptest-remote; C=cliptest-client; FAILS=0
GW=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}')

cleanup() { docker rm -f "$R" "$C" >/dev/null 2>&1; }
trap cleanup EXIT; cleanup

docker build -q -t "$IMG" - >/dev/null <<'DOCKERFILE' || exit 1
FROM chrome-tun2socks:latest
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends xclip xdotool imagemagick x11-apps >/dev/null && rm -rf /var/lib/apt/lists/*
DOCKERFILE

start() { # 名字 首页 [docker 额外参数...]
  local name=$1 url=$2; shift 2
  docker run -d --name "$name" --cap-add NET_ADMIN --device /dev/net/tun --security-opt seccomp=unconfined \
    --sysctl net.ipv6.conf.all.disable_ipv6=1 --shm-size 1g "$@" \
    -e PROXY=direct:// -e TZ=UTC -e RESOLUTION=1280x720 -e VNC_PASSWORD=$PW -e FONTS=system -e CPUS=all \
    -e START_URL="$url" "$IMG" >/dev/null
}
start "$R" "data:text/html;charset=utf-8,<textarea%20autofocus%20style='width:98vw;height:90vh;font-size:18px'></textarea><input%20type=password%20oninput='document.title=\"PW:\"+this.value'>" -p "$PORT:6080"
start "$C" "about:blank"
sleep 10
# 对照实验：NO_BRIDGE=1 时去掉桥接（等于原版 noVNC），粘贴和复制两项应当失败
if [ -n "${NO_BRIDGE:-}" ]; then docker exec "$R" sed -i '/clipboard-bridge/d' /usr/share/novnc/vnc.html; fi

x() { local c=$1; shift; docker exec -u chrome -e DISPLAY=:1 -e HOME=/home/chrome "$c" "$@"; }
set_clip() { printf '%s' "$2" | docker exec -i -u chrome "$1" sh -c 'cat > /tmp/clip.txt'; x "$1" sh -c 'xclip -selection clipboard -i /tmp/clip.txt >/dev/null 2>&1'; }
get_clip() { x "$1" timeout 8 xclip -selection clipboard -o 2>/dev/null; }
# 读取远端文本框的真实内容（在远端本地全选复制，不经过 VNC）
textarea() { x "$R" xdotool key ctrl+a; sleep 0.3; x "$R" xdotool key ctrl+c; sleep 0.7; get_clip "$R"; }
check() { if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1"; echo "      期望: ${3:0:80}"; echo "      实际: ${2:0:80}"; FAILS=$((FAILS+1)); fi; }

if [ "$MODE" = secure ]; then
  # http://127.0.0.1 属于安全上下文，和 HTTPS 一样可以使用 navigator.clipboard
  docker exec -d "$C" python3 -I -c "
import asyncio
async def pipe(r, w):
    try:
        while (d := await r.read(65536)):
            w.write(d); await w.drain()
    finally:
        w.close()
async def h(r, w):
    r2, w2 = await asyncio.open_connection('$GW', $PORT)
    await asyncio.gather(pipe(r, w2), pipe(r2, w))
async def main():
    s = await asyncio.start_server(h, '127.0.0.1', $PORT)
    await s.serve_forever()
asyncio.run(main())"
  sleep 1; HOST=127.0.0.1
else
  HOST=$GW
fi
x "$C" google-chrome-stable --user-data-dir=/home/chrome/profile \
  "http://$HOST:$PORT/vnc.html?autoconnect=1&resize=scale&password=$PW" >/dev/null 2>&1
sleep 8
x "$C" xdotool mousemove 640 400 click 1; sleep 1
echo "== 模式: $MODE ($HOST)"

TEXT=$'第一行：中文文档内容\nSecond line 123\n第三行 😀'
set_clip "$C" "$TEXT"; x "$C" xdotool key ctrl+v; sleep 2
check "本地 Ctrl+V 粘贴到远端（中文、多行、emoji）" "$(textarea)" "$TEXT"

check "粘贴后普通输入正常（Ctrl 没有卡住）" "$(x "$C" xdotool key ctrl+a; sleep 0.3; x "$C" xdotool key x; sleep 1; textarea)" "x"

set_clip "$R" "REMOTE-远端内容"; x "$R" xdotool key ctrl+a; sleep 0.3; x "$R" xdotool key ctrl+v; sleep 1
set_clip "$C" "OLD"; x "$C" xdotool key ctrl+a; sleep 0.3; x "$C" xdotool key ctrl+c; sleep 2
check "远端 Ctrl+C 复制到本地" "$(get_clip "$C")" "REMOTE-远端内容"

sleep 4; set_clip "$C" "KEEP-ME"; x "$C" xdotool mousemove 640 300 click --repeat 2 1; x "$C" xdotool key ctrl+a; sleep 2
check "只选中文字、没有复制，本地剪贴板不变" "$(get_clip "$C")" "KEEP-ME"

sleep 4; set_clip "$R" "EVIL-后台改写"; sleep 2
check "远端后台改写剪贴板，不影响本地" "$(get_clip "$C")" "KEEP-ME"

x "$C" xdotool key ctrl+a; sleep 0.3; x "$C" xdotool key x; sleep 1; BEFORE=$(textarea)
docker exec "$C" sh -c 'convert -size 20x20 xc:red /tmp/c.png && chmod 644 /tmp/c.png'
x "$C" sh -c 'xclip -selection clipboard -t image/png -i /tmp/c.png >/dev/null 2>&1'; x "$C" xdotool key ctrl+v; sleep 1.5
x "$C" sh -c 'xwd -root -silent | convert xwd:- png:/tmp/image-paste.png'; docker cp "$C:/tmp/image-paste.png" "/tmp/clip-$MODE-image.png" 2>/dev/null
sleep 1; check "本地是图片时不粘贴旧内容" "$(textarea)" "$BEFORE"

# 网址、账号、密码：单行输入框和地址栏的行为与多行文本框不同。密码框的值通过页面标题读出（Chrome 不允许从密码框复制）
pw_field() { x "$R" xdotool getactivewindow getwindowname | sed 's/ - Google Chrome$//'; }
SECRET=$'P@ss:w/0rd?#&%+="\'\\ 中文$x`y'
x "$C" xdotool mousemove 640 400 click 1; sleep 0.5; x "$C" xdotool key Tab; sleep 0.5
set_clip "$C" "$SECRET"; x "$C" xdotool key ctrl+v; sleep 2
check "粘贴到密码框（含各种特殊字符）" "$(pw_field)" "PW:$SECRET"
x "$C" xdotool key ctrl+a; sleep 0.3; set_clip "$C" $'user.name+tag@example.com\n'; x "$C" xdotool key ctrl+v; sleep 2
check "末尾带换行的账号（如从表格复制）贴进单行框" "$(pw_field)" "PW:user.name+tag@example.com"
URL='https://example.com/login?next=/a%20b&x=1#top'
set_clip "$C" "$URL"; x "$C" xdotool key ctrl+l; sleep 0.5; x "$C" xdotool key ctrl+v; sleep 1.5
x "$R" xdotool key ctrl+a; sleep 0.3; x "$R" xdotool key ctrl+c; sleep 0.7
check "粘贴到地址栏（网址不变形）" "$(get_clip "$R")" "$URL"
x "$R" xdotool key Escape; x "$R" xdotool key Escape; sleep 0.5; x "$C" xdotool mousemove 640 400 click 1; sleep 0.5

big_clip() { # 行数（每行 27 字节）
  docker exec -u chrome "$C" python3 -I -c "import sys; open('/tmp/clip.txt', 'w').write('长文档测试内容 line\\n' * int(sys.argv[1]))" "$1"
  x "$C" sh -c 'xclip -selection clipboard -i /tmp/clip.txt >/dev/null 2>&1'
}
BEFORE=$(textarea); big_clip 410000; x "$C" xdotool key ctrl+v; sleep 1.5
x "$C" sh -c 'xwd -root -silent | convert xwd:- png:/tmp/too-big.png'; docker cp "$C:/tmp/too-big.png" "/tmp/clip-$MODE-too-big.png" 2>/dev/null
sleep 1; check "11MB 超过上限，不粘贴旧内容" "$(textarea)" "$BEFORE"

big_clip 340000; x "$C" xdotool key ctrl+v; sleep 15
check "9MB 文字完整到达远端" "$(x "$R" timeout 40 xclip -selection clipboard -o 2>/dev/null | sha256sum | cut -c1-16)" "$(docker exec "$C" sha256sum /tmp/clip.txt | cut -c1-16)"

echo "失败数: $FAILS"; exit "$FAILS"
