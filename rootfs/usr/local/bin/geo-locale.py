#!/usr/bin/env python3
"""TZ=auto / LANGUAGE=auto 时，经代理查询出口 IP 所在地，输出匹配的 TZ / LANGUAGE（shell export 语句）。
结果缓存在 /tmp（每次容器启动都会被清空），同一会话内 Chrome 重开不会重复查询。"""
import json
import os
import shlex
import sys
import time
import urllib.request

CACHE = "/tmp/session-geo.json"
LANG_BY_COUNTRY = {
    "CN": "zh_CN:zh", "TW": "zh_TW:zh", "HK": "zh_HK:zh_TW:zh", "MO": "zh_TW:zh",
    "JP": "ja_JP:ja", "KR": "ko_KR:ko", "VN": "vi_VN:vi", "TH": "th_TH:th", "ID": "id_ID:id",
    "DE": "de_DE:de", "AT": "de_AT:de", "CH": "de_CH:de", "FR": "fr_FR:fr", "BE": "fr_BE:fr",
    "IT": "it_IT:it", "ES": "es_ES:es", "MX": "es_MX:es", "AR": "es_AR:es", "CO": "es_CO:es",
    "CL": "es_CL:es", "BR": "pt_BR:pt", "PT": "pt_PT:pt", "NL": "nl_NL:nl", "PL": "pl_PL:pl",
    "RU": "ru_RU:ru", "UA": "uk_UA:uk", "TR": "tr_TR:tr", "SE": "sv_SE:sv", "NO": "nb_NO:nb",
    "DK": "da_DK:da", "FI": "fi_FI:fi", "CZ": "cs_CZ:cs", "GR": "el_GR:el", "HU": "hu_HU:hu",
    "RO": "ro_RO:ro", "IL": "he_IL:he", "SA": "ar_SA:ar", "GB": "en_GB:en", "IE": "en_GB:en",
    "AU": "en_AU:en", "NZ": "en_NZ:en", "IN": "en_IN:en", "CA": "en_CA:en",
}
SOURCES = [  # (url, ip 字段, 国家字段, 时区字段)
    ("https://ipinfo.io/json", "ip", "country", "timezone"),
    ("http://ip-api.com/json/?fields=query,countryCode,timezone", "query", "countryCode", "timezone"),
]


def lookup():
    if os.path.exists(CACHE):
        return json.load(open(CACHE))
    deadline = time.time() + 40
    while time.time() < deadline:
        for url, k_ip, k_cc, k_tz in SOURCES:
            try:
                req = urllib.request.Request(url, headers={"User-Agent": "curl/8"})
                d = json.load(urllib.request.urlopen(req, timeout=6))
                geo = {"ip": d.get(k_ip), "country": d.get(k_cc), "timezone": d.get(k_tz)}
                if geo["timezone"]:
                    json.dump(geo, open(CACHE, "w"))
                    return geo
            except Exception:
                pass
        time.sleep(2)
    return None


geo = lookup()
tz, lang = os.environ.get("TZ", "auto"), os.environ.get("LANGUAGE", "")
if tz == "auto":
    tz = geo["timezone"] if geo else "UTC"
if lang == "auto":
    lang = LANG_BY_COUNTRY.get(geo["country"], "en_US:en") if geo else "en_US:en"
if geo:
    print(f"[session] 出口 IP {geo['ip']} ({geo['country']}) -> TZ={tz} LANGUAGE={lang}", file=sys.stderr)
else:
    print(f"[session] 无法查询出口 IP 所在地（代理不通？），使用 TZ={tz} LANGUAGE={lang}", file=sys.stderr)
print(f"export TZ={shlex.quote(tz)}")
print(f"export LANGUAGE={shlex.quote(lang)}")
