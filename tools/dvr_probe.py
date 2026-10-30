#!/usr/bin/env python3
"""DVR Viewer — 非破壞性 DVR 服務探測

用法：
  python3 -I tools/dvr_probe.py <DVR IP> [--user <帳號>] [--port 6036] [--channel 1]

只做以下「唯讀」動作：
  1. 對少數已知服務 Port 建立 TCP 連線（不掃描網段、不掃全部 Port）
  2. 被動讀取連線後設備主動送出的 banner（不送任何資料）
  3. HTTP GET /、RTSP OPTIONS、未驗證 RTSP DESCRIBE（取得驗證方式）
  4. ONVIF GetSystemDateAndTime（ONVIF 規範允許未驗證）
  5. 若提供 --user 且 Keychain 有密碼：
       - RTSP DESCRIBE（Digest/Basic）嘗試少數 TVT 常見 URL，取得 SDP 編碼資訊
       - ONVIF GetDeviceInformation / GetProfiles / GetStreamUri（WS-Security UsernameToken）
     任何一次帶憑證的請求回 401（帳密錯誤）就立即停止，避免帳號被鎖。

不修改任何設定、不刪除錄影、不暴力破解。報告寫入 captures/（已排除於 Git），輸出已遮蔽密碼。
密碼請先用 tools/dvr-credentials.sh set <IP> <帳號> 存入 Keychain。
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import os
import re
import socket
import subprocess
import sys
import time
from pathlib import Path

KEYCHAIN_SERVICE = "DVRViewer.dev"
PORTS = {
    80: "HTTP（Web / ONVIF / NVMS-9000 Web API）",
    443: "HTTPS",
    554: "RTSP",
    6036: "TVT NVR/DVR 專有協定（常見）",
    9008: "TVT IPC 專有協定（常見）",
    8000: "HTTP 替代",
    8080: "HTTP 替代",
    8554: "RTSP 替代",
    9000: "其他設備服務",
}
TVT_RTSP_PATHS = [
    "/chID={ch}&streamType={st}&linkType=tcp",
    "/chID={ch:02d}&streamType={st}",
    "/profile{prof}",
    "/",
]

OUT: list[str] = []


def log(s: str = ""):
    print(s)
    OUT.append(s)


def keychain_pw(user: str, host: str) -> str | None:
    r = subprocess.run(["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", f"{user}@{host}", "-w"],
                       capture_output=True, text=True)
    return r.stdout.rstrip("\n") if r.returncode == 0 else None


class Redact:
    def __init__(self, secrets):
        self.secrets = [s for s in secrets if s]

    def __call__(self, s: str) -> str:
        for x in self.secrets:
            s = s.replace(x, "***")
        s = re.sub(r"((?:Authorization|WWW-Authenticate|Cookie|Set-Cookie)\s*:\s*)(Basic|Digest)?[^\r\n]*",
                   lambda m: m.group(1) + (m.group(2) or "") + self._realm(m.group(0)) + " [REDACTED]", s, flags=re.I)
        s = re.sub(r"(<(?:wsse:)?(?:Password|Nonce)[^>]*>)[^<]*", r"\1[REDACTED]", s)
        s = re.sub(r"(rtsp|http)://([^:/@\s]+):([^@\s]+)@", r"\1://\2:***@", s)
        return s

    @staticmethod
    def _realm(h: str) -> str:
        m = re.search(r'realm="([^"]*)"', h)
        q = re.search(r'qop="([^"]*)"', h)
        a = re.search(r'algorithm="?([\w-]+)', h)
        return (f' realm="{m.group(1)}"' if m else "") + (f' qop="{q.group(1)}"' if q else "") + (f" algorithm={a.group(1)}" if a else "")


def tcp_open(host, port, timeout=1.5) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def passive_banner(host, port, wait=1.5) -> bytes:
    try:
        with socket.create_connection((host, port), timeout=2) as s:
            s.settimeout(wait)
            try:
                return s.recv(256)
            except socket.timeout:
                return b""
    except OSError:
        return b""


def request(host, port, data: bytes, timeout=4, maxlen=65536) -> bytes:
    with socket.create_connection((host, port), timeout=timeout) as s:
        s.sendall(data)
        s.settimeout(timeout)
        buf = b""
        t0 = time.time()
        while len(buf) < maxlen and time.time() - t0 < timeout:
            try:
                chunk = s.recv(8192)
            except socket.timeout:
                break
            if not chunk:
                break
            buf += chunk
            m = re.search(rb"\r\n\r\n", buf)
            if m:
                cl = re.search(rb"Content-Length:\s*(\d+)", buf[:m.end()], re.I)
                if cl and len(buf) >= m.end() + int(cl.group(1)):
                    break
                if not cl and not buf.startswith(b"HTTP/1.1 200") and not buf.startswith(b"HTTP/1.0 200"):
                    break
        return buf


def hexrow(b: bytes, n=32):
    return " ".join(f"{x:02x}" for x in b[:n]) + "  |" + "".join(chr(x) if 32 <= x < 127 else "." for x in b[:n]) + "|"


# ------------------------------------------------------------------ RTSP ----

class Rtsp:
    def __init__(self, host, port, user=None, pw=None):
        self.host, self.port, self.user, self.pw = host, port, user, pw
        self.cseq = 0
        self.auth_hdr = None  # (scheme, params)

    def _auth(self, method, uri):
        if not (self.auth_hdr and self.user and self.pw is not None):
            return ""
        scheme, p = self.auth_hdr
        if scheme.lower() == "basic":
            return "Authorization: Basic " + base64.b64encode(f"{self.user}:{self.pw}".encode()).decode() + "\r\n"
        realm, nonce = p.get("realm", ""), p.get("nonce", "")
        ha1 = hashlib.md5(f"{self.user}:{realm}:{self.pw}".encode()).hexdigest()
        ha2 = hashlib.md5(f"{method}:{uri}".encode()).hexdigest()
        resp = hashlib.md5(f"{ha1}:{nonce}:{ha2}".encode()).hexdigest()
        return (f'Authorization: Digest username="{self.user}", realm="{realm}", nonce="{nonce}", '
                f'uri="{uri}", response="{resp}"\r\n')

    def send(self, method, uri, extra=""):
        self.cseq += 1
        req = (f"{method} {uri} RTSP/1.0\r\nCSeq: {self.cseq}\r\nUser-Agent: DVRViewer-Probe/0.1\r\n"
               f"{self._auth(method, uri)}{extra}\r\n").encode()
        raw = request(self.host, self.port, req)
        status = int(raw[9:12]) if raw.startswith(b"RTSP/1.0 ") and raw[9:12].isdigit() else 0
        return status, raw.decode("utf-8", "replace")

    @staticmethod
    def parse_www_auth(raw: str):
        heads = re.findall(r"WWW-Authenticate:\s*(\w+)\s*([^\r\n]*)", raw, re.I)
        # 優先使用 Digest
        heads.sort(key=lambda h: 0 if h[0].lower() == "digest" else 1)
        if not heads:
            return None
        scheme, rest = heads[0]
        params = dict(re.findall(r'(\w+)="?([^",]*)"?', rest))
        return scheme, params


def sdp_summary(raw: str) -> list[str]:
    lines = []
    for ln in raw.splitlines():
        if ln.startswith(("m=", "a=rtpmap", "a=control", "a=framerate", "a=x-dimensions", "a=range", "s=")):
            lines.append(ln.strip())
        elif ln.startswith("a=fmtp"):
            # 只保留 profile/level，不輸出完整 sprop 參數集
            m = re.search(r"profile-level-id=([0-9A-Fa-f]+)", ln)
            lines.append("a=fmtp ... " + (f"profile-level-id={m.group(1)}" if m else "(H.265/其他參數)"))
    return lines


# ------------------------------------------------------------------ ONVIF ---

def onvif_call(host, port, path, body_xml, user=None, pw=None, timeout=5):
    sec = ""
    if user and pw is not None:
        nonce = os.urandom(16)
        created = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
        digest = base64.b64encode(hashlib.sha1(nonce + created.encode() + pw.encode()).digest()).decode()
        sec = (
            '<s:Header><wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" '
            'xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">'
            f"<wsse:UsernameToken><wsse:Username>{user}</wsse:Username>"
            '<wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">'
            f"{digest}</wsse:Password>"
            '<wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-soap-message-security-1.0#Base64Binary">'
            f"{base64.b64encode(nonce).decode()}</wsse:Nonce><wsu:Created>{created}</wsu:Created></wsse:UsernameToken></wsse:Security></s:Header>"
        )
    env = ('<?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" '
           'xmlns:tds="http://www.onvif.org/ver10/device/wsdl" xmlns:trt="http://www.onvif.org/ver10/media/wsdl" '
           'xmlns:tt="http://www.onvif.org/ver10/schema">' + sec + "<s:Body>" + body_xml + "</s:Body></s:Envelope>").encode()
    req = (f"POST {path} HTTP/1.1\r\nHost: {host}:{port}\r\nContent-Type: application/soap+xml; charset=utf-8\r\n"
           f"Content-Length: {len(env)}\r\nConnection: close\r\n\r\n").encode() + env
    raw = request(host, port, req, timeout=timeout, maxlen=262144)
    status = int(raw[9:12]) if raw[:5] == b"HTTP/" and raw[9:12].isdigit() else 0
    return status, raw.decode("utf-8", "replace")


def xml_vals(raw: str, tags: list[str]) -> dict:
    out = {}
    for t in tags:
        m = re.findall(rf"<(?:\w+:)?{t}>([^<]*)</(?:\w+:)?{t}>", raw)
        if m:
            out[t] = m if len(m) > 1 else m[0]
    return out


# ------------------------------------------------------------------ main ----

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("host")
    ap.add_argument("--user")
    ap.add_argument("--channel", type=int, default=1, help="RTSP 測試頻道（從 1 開始）")
    ap.add_argument("--extra-port", type=int, action="append", default=[], help="額外檢查的 Port（例如 SuperLive 設定的 Port）")
    a = ap.parse_args()
    host = a.host
    pw = keychain_pw(a.user, host) if a.user else None
    if a.user and pw is None:
        print(f"⚠️ Keychain 找不到 {a.user}@{host}，只執行未驗證探測。先執行：tools/dvr-credentials.sh set {host} {a.user}")
    red = Redact([pw] if pw else [])

    log(f"# DVR 探測報告：{host}")
    log(f"- 時間：{dt.datetime.now():%Y-%m-%d %H:%M:%S}　帳號：{a.user or '(未提供)'}　密碼：{'Keychain 已提供' if pw else '無'}\n")

    ports = dict(PORTS)
    for p in a.extra_port:
        ports.setdefault(p, "使用者指定")
    log("## 1. 服務 Port（TCP connect）\n")
    open_ports = []
    for p, desc in ports.items():
        ok = tcp_open(host, p)
        log(f"- {p:5d} {'開啟 ✅' if ok else '關閉/無回應'}　{desc}")
        if ok:
            open_ports.append(p)

    log("\n## 2. 被動 banner（連線後不送資料，等待 1.5 秒）\n")
    for p in open_ports:
        if p in (80, 443, 8000, 8080, 554, 8554):
            continue
        b = passive_banner(host, p)
        log(f"- {p}: {'(設備未主動送資料)' if not b else hexrow(b)}")

    log("\n## 3. HTTP\n")
    for p in [x for x in open_ports if x in (80, 8000, 8080)]:
        try:
            raw = request(host, p, f"GET / HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode(), maxlen=32768)
            txt = raw.decode("utf-8", "replace")
            head = txt.split("\r\n\r\n", 1)[0]
            title = re.search(r"<title>([^<]*)</title>", txt, re.I)
            log(f"### Port {p}\n```\n{red(head)[:1500]}\n```")
            log(f"- 網頁標題：{title.group(1).strip() if title else '(無)'}")
            hints = sorted(set(re.findall(r"(NVMS-9000|NVMS|N9000|webPlugin|H5Player|websocket|wasm|SuperLive|ActiveX|ocx)", txt, re.I)))
            if hints:
                log(f"- 網頁內容關鍵字：{hints}")
        except OSError as e:
            log(f"- Port {p} HTTP 失敗：{e}")

    rtsp_port = 554 if 554 in open_ports else (8554 if 8554 in open_ports else None)
    log("\n## 4. RTSP\n")
    if not rtsp_port:
        log("- RTSP Port 未開啟（554/8554）。")
    else:
        r = Rtsp(host, rtsp_port, a.user, pw)
        try:
            st, raw = r.send("OPTIONS", f"rtsp://{host}:{rtsp_port}/")
            log(f"### OPTIONS → {st}\n```\n{red(raw)[:800]}\n```")
            ch = a.channel
            tried_auth = False
            for tpl in TVT_RTSP_PATHS:
                path = tpl.format(ch=ch, st="main", prof=ch)
                uri = f"rtsp://{host}:{rtsp_port}{path}"
                st, raw = r.send("DESCRIBE", uri, "Accept: application/sdp\r\n")
                if st == 401 and not tried_auth:
                    r.auth_hdr = Rtsp.parse_www_auth(raw)
                    scheme = r.auth_hdr[0] if r.auth_hdr else "?"
                    realm = (r.auth_hdr[1] if r.auth_hdr else {}).get("realm", "")
                    log(f"- DESCRIBE {path} → 401，驗證方式：{scheme}，realm=\"{realm}\"")
                    if not pw:
                        log("  （未提供憑證，停止 RTSP 驗證測試）")
                        break
                    tried_auth = True
                    st, raw = r.send("DESCRIBE", uri, "Accept: application/sdp\r\n")
                if st == 401:
                    log(f"- DESCRIBE {path} → 401（帶憑證仍失敗：帳密錯誤或該帳號無 RTSP 權限）。為避免鎖帳號，停止。")
                    break
                if st == 200:
                    log(f"- ✅ DESCRIBE {path} → 200，SDP：")
                    for ln in sdp_summary(raw):
                        log(f"    {ln}")
                    sub = TVT_RTSP_PATHS[TVT_RTSP_PATHS.index(tpl)].format(ch=ch, st="sub", prof=ch + 1)
                    if sub != path:
                        st2, raw2 = r.send("DESCRIBE", f"rtsp://{host}:{rtsp_port}{sub}", "Accept: application/sdp\r\n")
                        log(f"- 子串流 DESCRIBE {sub} → {st2}")
                        if st2 == 200:
                            for ln in sdp_summary(raw2):
                                log(f"    {ln}")
                    break
                log(f"- DESCRIBE {path} → {st or '無回應'}")
        except OSError as e:
            log(f"- RTSP 失敗：{e}")

    log("\n## 5. ONVIF\n")
    onvif_port = next((p for p in (80, 8000, 8080) if p in open_ports), None)
    if not onvif_port:
        log("- 無 HTTP Port，略過 ONVIF。")
    else:
        try:
            st, raw = onvif_call(host, onvif_port, "/onvif/device_service", "<tds:GetSystemDateAndTime/>")
            ok = st == 200 and "SystemDateAndTime" in raw
            log(f"- GetSystemDateAndTime（未驗證）→ HTTP {st} {'✅ 支援 ONVIF' if ok else '（未確認 ONVIF）'}")
            if ok:
                log(f"  {xml_vals(raw, ['TZ', 'Year', 'Month', 'Day', 'Hour', 'Minute'])}")
            if ok and pw:
                st, raw = onvif_call(host, onvif_port, "/onvif/device_service", "<tds:GetDeviceInformation/>", a.user, pw)
                log(f"- GetDeviceInformation → HTTP {st} {xml_vals(raw, ['Manufacturer', 'Model', 'FirmwareVersion', 'HardwareId'])}")
                if st in (400, 401) and "NotAuthorized" in raw:
                    log("  帳密未通過 ONVIF 驗證（可能未啟用 ONVIF 使用者或時間差過大），停止。")
                elif st == 200:
                    st, raw = onvif_call(host, onvif_port, "/onvif/device_service",
                                         '<tds:GetCapabilities><tds:Category>All</tds:Category></tds:GetCapabilities>', a.user, pw)
                    media = re.search(r"<tt:Media>.*?<tt:XAddr>([^<]+)</tt:XAddr>", raw, re.S)
                    media_url = media.group(1) if media else f"http://{host}:{onvif_port}/onvif/media_service"
                    log(f"- Media 服務：{media_url}")
                    replay = "Replay" in raw or "replay" in raw
                    log(f"- 能力回報含 Replay/Recording：{'是' if replay or 'Recording' in raw else '否'}")
                    mp = re.match(r"https?://[^/]+(/.*)", media_url)
                    mpath = mp.group(1) if mp else "/onvif/media_service"
                    st, raw = onvif_call(host, onvif_port, mpath, "<trt:GetProfiles/>", a.user, pw)
                    tokens = re.findall(r'<trt:Profiles[^>]*token="([^"]+)"', raw)
                    log(f"- GetProfiles → HTTP {st}，profiles：{tokens[:16]}")
                    encs = re.findall(r"<tt:Encoding>([^<]+)</tt:Encoding>.*?<tt:Width>(\d+)</tt:Width>\s*<tt:Height>(\d+)</tt:Height>", raw, re.S)
                    if encs:
                        log(f"  編碼/解析度（前 8）：{encs[:8]}")
                    for tok in tokens[:2]:
                        body = ('<trt:GetStreamUri><trt:StreamSetup><tt:Stream>RTP-Unicast</tt:Stream><tt:Transport>'
                                f'<tt:Protocol>RTSP</tt:Protocol></tt:Transport></trt:StreamSetup><trt:ProfileToken>{tok}</trt:ProfileToken></trt:GetStreamUri>')
                        st, raw = onvif_call(host, onvif_port, mpath, body, a.user, pw)
                        uri = xml_vals(raw, ["Uri"]).get("Uri")
                        log(f"- GetStreamUri({tok}) → {red(str(uri))}")
        except OSError as e:
            log(f"- ONVIF 失敗：{e}")

    out_dir = Path(__file__).resolve().parent.parent / "captures"
    out_dir.mkdir(exist_ok=True)
    os.chmod(out_dir, 0o700)
    out = out_dir / f"probe-{host}-{dt.datetime.now():%Y%m%d-%H%M%S}.report.md"
    out.write_text(red("\n".join(OUT)) + "\n", encoding="utf-8")
    os.chmod(out, 0o600)
    print(f"\n報告：{out}", file=sys.stderr)


if __name__ == "__main__":
    main()
