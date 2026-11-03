#!/usr/bin/env python3
"""每次容器启动生成一份随机但合理的“会话画像”，让每次会话的浏览器指纹不同：
  - 屏幕分辨率（按常见分辨率的占比抽取）
  - CPU 核数（navigator.hardwareConcurrency，通过 taskset 限制）
  - 字体集合、默认 sans/serif/mono 字体、字体微调方式（影响字体列表与 Canvas 指纹）
stdout 输出 shell export 语句供 entrypoint eval；fontconfig 配置写入 chrome 用户目录。
"""
import os
import pwd
import random
import shlex
import subprocess
import sys

rnd = random.SystemRandom()
env = os.environ.get
exports = {}
summary = []

# ---------------------------------------------------------------- 分辨率
COMMON_RES = {"1920x1080": 35, "1536x864": 12, "1366x768": 12, "1440x900": 8,
              "1600x900": 8, "1280x800": 5, "1680x1050": 5, "1280x720": 4}
res = env("RESOLUTION", "random")
if res == "random":
    res = rnd.choices(list(COMMON_RES), weights=list(COMMON_RES.values()))[0]
exports["RESOLUTION"] = res
summary.append(f"screen={res}")

# ---------------------------------------------------------------- CPU 核数
cpus = sorted(os.sched_getaffinity(0))
want = env("CPUS", "random")
if want == "random":
    n = rnd.choice([n for n in (2, 4, 6, 8, 12, 16) if n <= len(cpus)] or [len(cpus)])
elif want in ("", "all"):
    n = len(cpus)
else:
    n = max(1, min(int(want), len(cpus)))
exports["CHROME_CPUS"] = ",".join(map(str, sorted(rnd.sample(cpus, n))))
summary.append(f"cpus={n}")

# ---------------------------------------------------------------- 字体
home = pwd.getpwnam("chrome").pw_dir
conf_dir = os.path.join(home, ".config", "fontconfig")
mode = env("FONTS", "random")

if mode == "random":
    installed = set()
    for line in subprocess.run(["fc-list", ":", "family"], capture_output=True, text=True).stdout.splitlines():
        installed.update(f.strip() for f in line.split(",") if f.strip())

    # 可选字体组：(出现概率, 家族名前缀)。Liberation / Noto CJK SC / Emoji 始终保留
    optional = {
        "dejavu":    (0.8, ["DejaVu"]),
        "urw":       (0.5, ["Nimbus", "C059", "P052", "URW ", "Z003", "D050000L", "Standard Symbols"]),
        "freefont":  (0.4, ["FreeSans", "FreeSerif", "FreeMono"]),
        "cantarell": (0.4, ["Cantarell"]),
        "opensans":  (0.4, ["Open Sans"]),
        "lato":      (0.4, ["Lato"]),
        "roboto":    (0.4, ["Roboto"]),
        "office":    (0.5, ["Carlito", "Caladea"]),
        "cjk-tc":    (0.5, ["Noto Sans CJK TC", "Noto Serif CJK TC", "Noto Sans Mono CJK TC"]),
        "cjk-hk":    (0.4, ["Noto Sans CJK HK", "Noto Serif CJK HK", "Noto Sans Mono CJK HK"]),
        "cjk-jp":    (0.5, ["Noto Sans CJK JP", "Noto Serif CJK JP", "Noto Sans Mono CJK JP"]),
        "cjk-kr":    (0.5, ["Noto Sans CJK KR", "Noto Serif CJK KR", "Noto Sans Mono CJK KR"]),
    }
    rejected, kept_groups = set(), []
    for name, (p, prefixes) in optional.items():
        fams = {f for f in installed if any(f.startswith(x) for x in prefixes)}
        if not fams:
            continue
        if rnd.random() < p:
            kept_groups.append(name)
        else:
            rejected |= fams
    available = installed - rejected

    def pick(cands):
        c = [f for f in cands if f in available]
        return rnd.choice(c) if c else None

    sans = pick(["DejaVu Sans", "Liberation Sans", "Nimbus Sans", "FreeSans", "Cantarell",
                 "Open Sans", "Lato", "Roboto"])
    serif = pick(["DejaVu Serif", "Liberation Serif", "Nimbus Roman", "FreeSerif"])
    mono = pick(["DejaVu Sans Mono", "Liberation Mono", "Nimbus Mono PS", "FreeMono"])
    hint = rnd.choices(["hintslight", "hintnone", "hintfull"], weights=[5, 2, 3])[0]

    x = ['<?xml version="1.0"?>', '<!DOCTYPE fontconfig SYSTEM "fonts.dtd">', "<fontconfig>"]
    if rejected:
        x.append("  <selectfont><rejectfont>")
        for f in sorted(rejected):
            x.append(f'    <pattern><patelt name="family"><string>{f}</string></patelt></pattern>')
        x.append("  </rejectfont></selectfont>")
    for generic, fam in (("sans-serif", sans), ("serif", serif), ("monospace", mono)):
        if fam:
            x.append(f'  <alias binding="strong"><family>{generic}</family>'
                     f"<prefer><family>{fam}</family></prefer></alias>")
    x += ['  <match target="font">',
          '    <edit name="antialias" mode="assign"><bool>true</bool></edit>',
          f'    <edit name="hinting" mode="assign"><bool>{"false" if hint == "hintnone" else "true"}</bool></edit>',
          f'    <edit name="hintstyle" mode="assign"><const>{hint}</const></edit>',
          "  </match>", "</fontconfig>"]

    os.makedirs(conf_dir, exist_ok=True)
    with open(os.path.join(conf_dir, "fonts.conf"), "w") as fh:
        fh.write("\n".join(x) + "\n")
    uid, gid = pwd.getpwnam("chrome").pw_uid, pwd.getpwnam("chrome").pw_gid
    for d in (os.path.join(home, ".config"), conf_dir, os.path.join(conf_dir, "fonts.conf")):
        os.chown(d, uid, gid)
    summary.append(f"fonts=[{','.join(kept_groups)}] sans={sans} serif={serif} mono={mono} {hint}")
else:
    summary.append("fonts=system")

print("[session] " + " ".join(summary), file=sys.stderr)
for k, v in exports.items():
    print(f"export {k}={shlex.quote(v)}")
