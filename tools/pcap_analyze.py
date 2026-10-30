#!/usr/bin/env python3
"""DVR Viewer — 離線封包分析器（純標準函式庫，不上傳任何資料）

用法：
  python3 -I tools/pcap_analyze.py <檔案.pcap|.pcapng> [--dvr <IP>] [--user <帳號>] [--out 報告.md]

功能：
  * 解析 pcap / pcapng（Ethernet、Loopback、Raw IP、Linux SLL）
  * 重組 TCP 串流，列出每條連線的方向、Port、位元組、時間
  * 協定辨識（以內容為證據，不以 Port 推測）：
      HTTP、RTSP（含 SDP 編碼）、TVT IPC "1111"/"head" 封包、NVMS-9000 XML、
      H.264 / H.265 Annex-B NAL、RTP over TCP（$ interleaved）、TLS
  * 未知二進位協定：列出訊息開頭的十六進位與 little-endian u32 欄位，協助逆向
  * 遮蔽：輸出前移除 Keychain 中的 DVR 密碼、XML 中的 password/token/nonce/session 等欄位、
           HTTP/RTSP Authorization/Cookie、URL 內嵌帳密、TVT 登入封包帳密欄位

所有報告預設寫在 pcap 同目錄（captures/，已被 .gitignore 排除）。
"""
from __future__ import annotations

import argparse
import base64
import collections
import ipaddress
import re
import struct
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

MAX_REASM = 16 * 1024 * 1024  # 每個方向最多重組 16 MB 用於內容分析（總量仍完整統計）
KEYCHAIN_SERVICE = "DVRViewer.dev"

# ---------------------------------------------------------------- 遮蔽 ----

class Redactor:
    SENSITIVE_TAGS = (
        "password|pwd|passwd|newPassword|oldPassword|token|nonce|sessionId|session|"
        "auth|authorization|sign|signature|secret|cookie|encryptPwd|userPwd|devPwd|"
        "loginPwd|key|aesKey|daToken|accessToken|refreshToken|salt"
    )

    def __init__(self, secrets: list[bytes]):
        self.secrets = [s for s in secrets if s and len(s) >= 3]
        extra = []
        for s in self.secrets:
            extra.append(base64.b64encode(s))
        self.secrets += extra
        self.xml_re = re.compile(
            rb"(<(" + self.SENSITIVE_TAGS.encode() + rb")(\s[^>]*)?>)(.*?)(</\2>)",
            re.I | re.S,
        )
        self.attr_re = re.compile(
            rb"((?:" + self.SENSITIVE_TAGS.encode() + rb")\s*=\s*[\"'])([^\"']*)([\"'])", re.I
        )
        self.hdr_re = re.compile(
            rb"^((?:Authorization|Proxy-Authorization|Cookie|Set-Cookie|WWW-Authenticate|X-Csrf-Token|Token)\s*:\s*)(.*)$",
            re.I | re.M,
        )
        self.url_re = re.compile(rb"([a-z][a-z0-9+.-]*://)([^/\s:@]+):([^/\s@]+)@", re.I)
        self.json_re = re.compile(
            rb"(\"(?:" + self.SENSITIVE_TAGS.encode() + rb")\"\s*:\s*\")([^\"]*)(\")", re.I
        )

    def bytes(self, b: bytes) -> bytes:
        for s in self.secrets:
            if s in b:
                b = b.replace(s, b"*" * len(s))
        b = self.xml_re.sub(lambda m: m.group(1) + b"[REDACTED]" + m.group(5), b)
        b = self.attr_re.sub(lambda m: m.group(1) + b"[REDACTED]" + m.group(3), b)
        b = self.json_re.sub(lambda m: m.group(1) + b"[REDACTED]" + m.group(3), b)
        b = self.hdr_re.sub(lambda m: m.group(1) + self._auth_scheme(m.group(2)) + b" [REDACTED]", b)
        b = self.url_re.sub(lambda m: m.group(1) + m.group(2) + b":***@", b)
        return b

    @staticmethod
    def _auth_scheme(v: bytes) -> bytes:
        # 保留驗證方式名稱（Basic/Digest）與 realm，供判斷驗證機制
        m = re.match(rb"\s*(Basic|Digest|Bearer|NTLM)\b", v, re.I)
        scheme = m.group(1) if m else b""
        realm = re.search(rb"realm=\"([^\"]*)\"", v)
        algo = re.search(rb"algorithm=\"?([A-Za-z0-9-]+)", v)
        out = scheme
        if realm:
            out += b' realm="' + realm.group(1) + b'"'
        if algo:
            out += b" algorithm=" + algo.group(1)
        return out

    def text(self, b: bytes, limit: int = 2000) -> str:
        b = self.bytes(b[: limit * 2])
        s = b.decode("utf-8", "replace")
        s = "".join(ch if ch.isprintable() or ch in "\n\t" else "·" for ch in s)
        return s[:limit]


def keychain_secrets(user: str | None, dvr: str | None) -> list[bytes]:
    if not (user and dvr):
        return []
    try:
        out = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", f"{user}@{dvr}", "-w"],
            capture_output=True, timeout=10,
        )
        if out.returncode == 0:
            pw = out.stdout.rstrip(b"\n")
            return [pw, f"{user}:{pw.decode('utf-8', 'replace')}".encode()]
    except Exception:
        pass
    return []

# ------------------------------------------------------------- pcap 讀取 ----

@dataclass
class Pkt:
    ts: float
    linktype: int
    data: bytes


def read_pcap(path: Path):
    data = path.read_bytes()
    magic = data[:4]
    if magic == b"\x0a\x0d\x0d\x0a":
        yield from _read_pcapng(data)
        return
    if magic in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1"):
        e = "<"
    elif magic in (b"\xa1\xb2\xc3\xd4", b"\xa1\xb2\x3c\x4d"):
        e = ">"
    else:
        raise SystemExit(f"無法辨識的檔案格式：{magic.hex()}")
    nsec = magic in (b"\x4d\x3c\xb2\xa1", b"\xa1\xb2\x3c\x4d")
    linktype = struct.unpack(e + "I", data[20:24])[0]
    off = 24
    while off + 16 <= len(data):
        sec, frac, incl, _orig = struct.unpack(e + "IIII", data[off:off + 16])
        off += 16
        yield Pkt(sec + frac / (1e9 if nsec else 1e6), linktype, data[off:off + incl])
        off += incl


def _read_pcapng(data: bytes):
    off = 0
    e = "<"
    ifaces: list[tuple[int, float]] = []
    while off + 12 <= len(data):
        btype = struct.unpack(e + "I", data[off:off + 4])[0]
        if btype == 0x0A0D0D0A:
            bom = data[off + 8:off + 12]
            e = "<" if bom == b"\x4d\x3c\x2b\x1a" else ">"
            ifaces = []
        blen = struct.unpack(e + "I", data[off + 4:off + 8])[0]
        if blen < 12:
            break
        body = data[off + 8:off + blen - 4]
        if btype == 1:  # IDB
            lt = struct.unpack(e + "H", body[0:2])[0]
            res = 1e-6
            o = 8
            while o + 4 <= len(body):
                code, ln = struct.unpack(e + "HH", body[o:o + 4])
                if code == 0:
                    break
                if code == 9 and ln >= 1:
                    v = body[o + 4]
                    res = 2 ** -(v & 0x7F) if v & 0x80 else 10 ** -v
                o += 4 + ((ln + 3) & ~3)
            ifaces.append((lt, res))
        elif btype == 6:  # EPB
            iid, hi, lo, cap, _orig = struct.unpack(e + "IIIII", body[:20])
            lt, res = ifaces[iid] if iid < len(ifaces) else (1, 1e-6)
            yield Pkt(((hi << 32) | lo) * res, lt, body[20:20 + cap])
        elif btype == 3:  # SPB
            lt, _ = ifaces[0] if ifaces else (1, 1e-6)
            yield Pkt(0.0, lt, body[4:])
        off += blen


def strip_link(p: Pkt) -> bytes | None:
    d, lt = p.data, p.linktype
    if lt == 1:  # Ethernet
        if len(d) < 14:
            return None
        et = struct.unpack(">H", d[12:14])[0]
        o = 14
        while et in (0x8100, 0x88A8) and len(d) >= o + 4:
            et = struct.unpack(">H", d[o + 2:o + 4])[0]
            o += 4
        return d[o:] if et in (0x0800, 0x86DD) else None
    if lt in (0, 108):  # BSD loopback
        return d[4:]
    if lt in (12, 101, 228, 229):  # Raw IP
        return d
    if lt == 113:  # Linux SLL
        return d[16:]
    if lt == 276:  # SLL2
        return d[20:]
    if lt in (149, 258):  # Apple PKTAP
        if len(d) < 8:
            return None
        hl, inner = struct.unpack("<II", d[:8])
        return strip_link(Pkt(p.ts, inner, d[hl:]))
    return None


def parse_ip(b: bytes):
    if not b:
        return None
    v = b[0] >> 4
    if v == 4 and len(b) >= 20:
        ihl = (b[0] & 0x0F) * 4
        total = struct.unpack(">H", b[2:4])[0] or len(b)
        proto = b[9]
        src, dst = str(ipaddress.IPv4Address(b[12:16])), str(ipaddress.IPv4Address(b[16:20]))
        return src, dst, proto, b[ihl:total]
    if v == 6 and len(b) >= 40:
        proto = b[6]
        src, dst = str(ipaddress.IPv6Address(b[8:24])), str(ipaddress.IPv6Address(b[24:40]))
        return src, dst, proto, b[40:]
    return None

# ------------------------------------------------------------ TCP 重組 ----

@dataclass
class Dir:
    isn: int | None = None
    segs: list = field(default_factory=list)  # (relseq, ts, payload, psh)
    bytes: int = 0
    pkts: int = 0
    fin: bool = False
    rst: bool = False


@dataclass
class TcpFlow:
    client: tuple[str, int]
    server: tuple[str, int]
    first: float
    last: float
    syn_seen: bool = False
    c2s: Dir = field(default_factory=Dir)
    s2c: Dir = field(default_factory=Dir)

    def reassemble(self, d: Dir) -> tuple[bytes, list[int], int]:
        """回傳 (資料, 每個 PSH 片段起點, 缺口數)"""
        segs = sorted(d.segs, key=lambda s: s[0])
        out = bytearray()
        starts: list[int] = []
        gaps = 0
        nxt = segs[0][0] if segs else 0
        for rel, _ts, pl, _psh in segs:
            if rel + len(pl) <= nxt:
                continue
            if rel > nxt:
                gaps += 1
                nxt = rel
            pl = pl[nxt - rel:]
            starts.append(len(out))
            out += pl
            nxt += len(pl)
            if len(out) >= MAX_REASM:
                break
        return bytes(out), starts, gaps


@dataclass
class UdpFlow:
    a: tuple[str, int]
    b: tuple[str, int]
    first: float
    last: float
    pkts_ab: int = 0
    pkts_ba: int = 0
    bytes_ab: int = 0
    bytes_ba: int = 0
    samples: list = field(default_factory=list)


def build_flows(path: Path):
    tcp: dict[tuple, TcpFlow] = {}
    udp: dict[tuple, UdpFlow] = {}
    t0 = None
    npk = 0
    for p in read_pcap(path):
        npk += 1
        ipb = strip_link(p)
        ip = parse_ip(ipb) if ipb else None
        if not ip:
            continue
        src, dst, proto, l4 = ip
        if t0 is None:
            t0 = p.ts
        ts = p.ts - t0
        if proto == 6 and len(l4) >= 20:
            sp, dp, seq, _ack = struct.unpack(">HHII", l4[:12])
            doff = (l4[12] >> 4) * 4
            flags = l4[13]
            syn, ack, fin, rst, psh = flags & 2, flags & 16, flags & 1, flags & 4, flags & 8
            payload = l4[doff:]
            a, b = (src, sp), (dst, dp)
            key = tuple(sorted([a, b]))
            f = tcp.get(key)
            if f is None:
                if syn and not ack:
                    cli, srv = a, b
                elif syn and ack:
                    cli, srv = b, a
                else:  # 中途開始抓：較大的 port 視為 client
                    cli, srv = (a, b) if sp > dp else (b, a)
                f = TcpFlow(cli, srv, ts, ts)
                tcp[key] = f
            f.last = ts
            d = f.c2s if a == f.client else f.s2c
            if syn:
                f.syn_seen = True
                d.isn = (seq + 1) & 0xFFFFFFFF
            if d.isn is None:
                d.isn = seq
            d.pkts += 1
            d.fin |= bool(fin)
            d.rst |= bool(rst)
            if payload:
                d.bytes += len(payload)
                rel = (seq - d.isn) & 0xFFFFFFFF
                if rel > 0x7FFFFFFF:  # 早於 ISN 的重送
                    continue
                d.segs.append((rel, ts, payload, bool(psh)))
        elif proto == 17 and len(l4) >= 8:
            sp, dp = struct.unpack(">HH", l4[:4])
            payload = l4[8:]
            a, b = (src, sp), (dst, dp)
            key = tuple(sorted([a, b]))
            f = udp.get(key)
            if f is None:
                f = UdpFlow(a, b, ts, ts)
                udp[key] = f
            f.last = ts
            if a == f.a:
                f.pkts_ab += 1; f.bytes_ab += len(payload)
            else:
                f.pkts_ba += 1; f.bytes_ba += len(payload)
            if len(f.samples) < 3 and payload:
                f.samples.append((a == f.a, payload[:32]))
    return tcp, udp, npk

# -------------------------------------------------------------- 協定辨識 ----

TVT_CMDS = {
    0x101: "CMD_REQUEST_LOGIN", 0x102: "CMD_REQUEST_LOGOUT", 0x103: "CMD_REQUEST_STREAM_BRIEF",
    0x201: "CMD_REQUEST_STREAM_START", 0x202: "CMD_REQUEST_STREAM_STOP", 0x203: "CMD_REQUEST_KEYFRAME",
    0x206: "CMD_REQUEST_CLIENT_INFO", 0x20E: "CMD_REQUEST_JPEG_DATA", 0x211: "CMD_REQUEST_MULTI_STREAM_INFO",
    0x401: "CMD_REQUEST_CFG_DEFAULT", 0x501: "CMD_REQUEST_DATA_SD_ALL_DATE",
    0x502: "CMD_REQUEST_DATA_SD_SEARCH_NAME", 0x904: "CMD_REQUEST_DATA_SD_SEARCH_EVENT",
    0x906: "CMD_REQUEST_PLAY_EVENT_STREAM", 0x907: "CMD_REQUEST_SUSPEND_EVENT_STREAM",
    0x908: "CMD_REQUEST_STOP_EVENT_STREAM", 0x909: "CMD_REQUEST_PULL_ENENT_STREAM",
    0x1000101: "CMD_REPLY_LOGIN_SUCC", 0x1000102: "CMD_REPLY_LOGIN_FAIL",
    0x1000103: "CMD_REPLY_STREAM_BRIEF", 0x100020D: "CMD_REPLY_REQUEST_STREAM_START",
    0x100020E: "CMD_REPLY_MULTI_STREAM_INFO", 0x1000405: "CMD_REPLY_CFG_DATA",
    0x1000501: "CMD_REPLY_DATA_SD_ALL_DATE", 0x1000502: "CMD_REPLY_DATA_SD_SEARCH_NAME",
    0x1000906: "CMD_REPLY_DATA_SD_SEARCH_EVENT", 0x1000C01: "CMD_REPLY_LIVE_STREAM",
    0x1000C02: "CMD_REPLY_PLAY_STREAM", 0x1000C04: "CMD_REPLY_STREAM_NULL",
    0x1010D00: "CMD_HTTP_REQUEST",
}

H264_NAL = {1: "slice", 5: "IDR", 6: "SEI", 7: "SPS", 8: "PPS", 9: "AUD"}
H265_NAL = {1: "TRAIL_R", 19: "IDR_W_RADL", 20: "IDR_N_LP", 21: "CRA", 32: "VPS", 33: "SPS", 34: "PPS", 35: "AUD", 39: "SEI"}


def nal_stats(b: bytes) -> dict:
    """統計 Annex-B start code 後的 NAL 類型，並判斷 H.264 / H.265"""
    h264 = collections.Counter()
    h265 = collections.Counter()
    i = 0
    n = 0
    while n < 200000:
        i = b.find(b"\x00\x00\x01", i)
        if i < 0 or i + 2 >= len(b) - 1:
            break
        hdr = b[i + 3]
        n += 1
        if hdr & 0x80 == 0:
            h264[hdr & 0x1F] += 1
            if i + 4 < len(b):
                h265[(hdr >> 1) & 0x3F] += 1
        i += 3
    score264 = h264[7] + h264[8] + h264[5]
    score265 = h265[32] + h265[33] + h265[34]
    # H.265 的 VPS/SPS/PPS 首位元組為 0x40/0x42/0x44，對應 H.264 的 nal type 0/2/4 → 不合理值
    if score265 and score265 >= score264 and h265[32]:
        return {"codec": "H.265/HEVC", "counts": {H265_NAL.get(k, str(k)): v for k, v in h265.most_common(8)}}
    if score264:
        return {"codec": "H.264/AVC", "counts": {H264_NAL.get(k, str(k)): v for k, v in h264.most_common(8)}}
    return {}


def classify(c2s: bytes, s2c: bytes, server_port: int) -> list[str]:
    tags = []
    head_c, head_s = c2s[:16], s2c[:16]
    if re.match(rb"(GET|POST|PUT|DELETE|HEAD|OPTIONS) [^ ]+ HTTP/1\.[01]", c2s[:64]):
        tags.append("HTTP")
    if re.match(rb"(OPTIONS|DESCRIBE|SETUP|PLAY|PAUSE|TEARDOWN|GET_PARAMETER|ANNOUNCE) [^ ]+ RTSP/1\.0", c2s[:128]):
        tags.append("RTSP")
    if head_c[:3] == b"\x16\x03\x01" or head_c[:3] == b"\x16\x03\x03":
        tags.append("TLS")
    if head_c[:4] in (b"1111", b"head") or head_s[:4] in (b"1111", b"head"):
        tags.append("TVT-IPC(1111/head)")
    if b"NVMS-9000" in c2s[:MAX_REASM] or b"NVMS-9000" in s2c[:MAX_REASM]:
        tags.append("NVMS-9000 XML")
    if b"http://www.ipc.com/ver10" in c2s or b"http://www.ipc.com/ver10" in s2c:
        tags.append("IPC XML(ver10)")
    if s2c[:1] == b"$" or re.search(rb"\r\n\$[\x00-\x07]", s2c[:262144]):
        tags.append("RTP-over-RTSP($)")
    if not tags and (c2s or s2c):
        tags.append("未知二進位")
    return tags


def frame_tvt(b: bytes, limit: int = 400):
    """依 TVT IPC 格式切割：'1111' + u32 len + [cmd u32, id u32, ver u32, dataLen u32, data]"""
    out = []
    o = 0
    while o + 8 <= len(b) and len(out) < limit:
        flag = b[o:o + 4]
        if flag == b"head":
            out.append((o, "CMD_INIT(head)", 64, b[o:o + 64]))
            o += 64
            continue
        if flag != b"1111":
            nxt = b.find(b"1111", o + 1)
            if nxt < 0:
                break
            o = nxt
            continue
        ln = struct.unpack("<I", b[o + 4:o + 8])[0]
        body = b[o + 8:o + 8 + ln]
        if ln == 0:
            out.append((o, "heartbeat", 0, b""))
        elif len(body) >= 4:
            cmd = struct.unpack("<I", body[:4])[0]
            out.append((o, TVT_CMDS.get(cmd, f"0x{cmd:X}"), ln, body))
        o += 8 + ln
    return out


def hexrow(b: bytes, n: int = 32) -> str:
    b = b[:n]
    hx = " ".join(f"{x:02x}" for x in b)
    asc = "".join(chr(x) if 32 <= x < 127 else "." for x in b)
    words = " ".join(f"{struct.unpack('<I', b[i:i+4])[0]:#x}" for i in range(0, len(b) - 3, 4)[:6])
    return f"`{hx}`  |{asc}|  u32le: {words}"


def xml_messages(b: bytes, red: Redactor, limit: int = 40):
    msgs = []
    for m in re.finditer(rb"<\?xml.{0,200000}?</(request|response|config|queryCondition)>", b, re.S):
        msgs.append(m.group(0))
        if len(msgs) >= limit:
            break
    urls = collections.Counter()
    for mm in re.finditer(rb"(?:url|cmdUrl|cmdType)\s*=\s*['\"]([A-Za-z0-9_]+)['\"]", b):
        urls[mm.group(1).decode()] += 1
    return msgs, urls

# ---------------------------------------------------------------- 報告 ----

def analyze(path: Path, dvr: str | None, red: Redactor, rtsp_show: int = 20) -> str:
    tcp, udp, npk = build_flows(path)
    L: list[str] = []
    w = L.append
    w(f"# 封包分析報告：{path.name}\n")
    w(f"- 封包數：{npk}　TCP 連線：{len(tcp)}　UDP 流：{len(udp)}")
    if dvr:
        w(f"- DVR 主機：{dvr}")
    w("- 已遮蔽：Keychain 密碼、XML/JSON 敏感欄位、Authorization/Cookie、URL 帳密、TVT 登入帳密\n")

    flows = sorted(tcp.values(), key=lambda f: f.first)
    w("## TCP 連線總覽\n")
    w("| # | 開始(s) | 結束(s) | Client → Server | c→s bytes | s→c bytes | 辨識 | 結束方式 |")
    w("|---|---|---|---|---|---|---|---|")
    details = []
    for i, f in enumerate(flows, 1):
        c, _, cg = f.reassemble(f.c2s)
        s, _, sg = f.reassemble(f.s2c)
        tags = classify(c, s, f.server[1])
        end = "RST" if (f.c2s.rst or f.s2c.rst) else ("FIN" if (f.c2s.fin or f.s2c.fin) else "持續中")
        mark = " ⭐" if dvr and dvr in (f.server[0], f.client[0]) else ""
        w(f"| {i} | {f.first:.2f} | {f.last:.2f} | {f.client[0]}:{f.client[1]} → {f.server[0]}:{f.server[1]}{mark} "
          f"| {f.c2s.bytes:,} | {f.s2c.bytes:,} | {', '.join(tags)} | {end} |")
        details.append((i, f, c, s, tags, cg, sg))

    for i, f, c, s, tags, cg, sg in details:
        if dvr and dvr not in (f.server[0], f.client[0]):
            continue
        w(f"\n## 連線 #{i}　{f.client[0]}:{f.client[1]} → {f.server[0]}:{f.server[1]}\n")
        w(f"- 時間 {f.first:.2f}s → {f.last:.2f}s（{f.last - f.first:.1f}s），"
          f"封包 c→s {f.c2s.pkts} / s→c {f.s2c.pkts}，3-way handshake：{'有' if f.syn_seen else '未擷取到'}")
        w(f"- 辨識：{', '.join(tags)}　重組缺口：c→s {cg} / s→c {sg}")
        for label, data in (("c→s", c), ("s→c", s)):
            ns = nal_stats(data)
            if ns:
                w(f"- 影像 {label}：**{ns['codec']}**　NAL 統計 {ns['counts']}")

        if "HTTP" in tags or "RTSP" in tags:
            w("\n### 文字協定交談（已遮蔽）\n")
            w("```")
            for label, data in (("C", c), ("S", s)):
                for m in re.finditer(rb"((?:[A-Z_]+ [^ \r\n]+ (?:RTSP|HTTP)/\d\.\d|(?:RTSP|HTTP)/\d\.\d \d{3}[^\r\n]*)\r\n.*?\r\n\r\n)", data, re.S):
                    hdr = m.group(1)
                    w(f"[{label}] " + red.text(hdr, 1200).strip())
                    clen = re.search(rb"Content-Length:\s*(\d+)", hdr, re.I)
                    if clen and int(clen.group(1)) < 8000:
                        body = data[m.end():m.end() + int(clen.group(1))]
                        if body.strip():
                            w(red.text(body, 3000).strip())
                    w("")
                    rtsp_show -= 1
                    if rtsp_show <= 0:
                        break
            w("```")

        if "TVT-IPC(1111/head)" in tags:
            w("\n### TVT IPC 命令序列\n")
            for label, data in (("C→S", c), ("S→C", s)):
                frames = frame_tvt(data)
                cnt = collections.Counter(n for _, n, _, _ in frames)
                w(f"- {label} 命令統計：{dict(cnt.most_common(15))}")
                shown = 0
                for off, name, ln, body in frames:
                    if name in ("heartbeat",) or name.startswith("CMD_REPLY_LIVE") or name.startswith("CMD_REPLY_PLAY"):
                        continue
                    shown += 1
                    if shown > 25:
                        break
                    b = body
                    if name == "CMD_REQUEST_LOGIN":
                        # data 起點 = 16；connectType(4) 後 username(32)+password(32) 遮蔽
                        b = bytearray(body)
                        for k in range(16 + 4, min(len(b), 16 + 4 + 64)):
                            b[k] = 0x2A
                        b = bytes(b)
                    w(f"  - @{off} {name} len={ln}  {hexrow(red.bytes(b), 32)}")

        if "NVMS-9000 XML" in tags or "IPC XML(ver10)" in tags:
            for label, data in (("C→S", c), ("S→C", s)):
                msgs, urls = xml_messages(data, red)
                if urls:
                    w(f"\n### {label} XML 指令統計\n\n{dict(urls.most_common(40))}")
                if msgs:
                    w(f"\n### {label} XML 範例（前 {min(len(msgs), 12)} 筆，已遮蔽）\n")
                    for mm in msgs[:12]:
                        w("```xml\n" + red.text(mm, 1500) + "\n```")
                # XML 前方的二進位標頭（用於了解專有封裝）
                hdrs = []
                for m in re.finditer(rb"<\?xml", data):
                    if m.start() >= 32:
                        hdrs.append(data[m.start() - 32:m.start()])
                    if len(hdrs) >= 4:
                        break
                if hdrs:
                    w(f"\n{label} XML 前 32 bytes（推測為封裝標頭）：")
                    for h in hdrs:
                        w(f"  - {hexrow(red.bytes(h), 32)}")

        if "未知二進位" in tags or "NVMS-9000 XML" in tags:
            w("\n### 二進位訊息開頭（每個 TCP PSH 片段起點，前 32 bytes）\n")
            for label, d in (("C→S", f.c2s), ("S→C", f.s2c)):
                segs = sorted(d.segs, key=lambda x: x[0])
                prefixes = collections.Counter(pl[:4].hex() for _, _, pl, _ in segs if len(pl) >= 4)
                w(f"- {label} 片段開頭 4 bytes 前五名：{dict(prefixes.most_common(5))}")
                for rel, ts, pl, _ in segs[:10]:
                    w(f"  - t={ts:.3f} rel={rel} len={len(pl)}  {hexrow(red.bytes(pl), 32)}")

    if udp:
        w("\n## UDP 流\n")
        w("| A | B | A→B pkts/bytes | B→A pkts/bytes | 首段樣本 |")
        w("|---|---|---|---|---|")
        for f in sorted(udp.values(), key=lambda f: -(f.bytes_ab + f.bytes_ba))[:40]:
            samp = ""
            if f.samples:
                d, b = f.samples[0]
                kind = ""
                if f.a[1] == 53 or f.b[1] == 53:
                    kind = "DNS "
                elif len(b) >= 2 and (b[0] >> 6) == 2:
                    kind = f"RTP?(pt={b[1] & 0x7F}) "
                samp = kind + b[:16].hex()
            w(f"| {f.a[0]}:{f.a[1]} | {f.b[0]}:{f.b[1]} | {f.pkts_ab}/{f.bytes_ab:,} | {f.pkts_ba}/{f.bytes_ba:,} | {samp} |")
        dns = []
        for f in udp.values():
            if 53 in (f.a[1], f.b[1]):
                for _, b in f.samples:
                    q = _dns_qname(b)
                    if q:
                        dns.append(q)
        if dns:
            w(f"\nDNS 查詢（樣本）：{sorted(set(dns))}")
    return "\n".join(L) + "\n"


def _dns_qname(b: bytes) -> str | None:
    try:
        o = 12
        parts = []
        while o < len(b) and b[o]:
            n = b[o]
            parts.append(b[o + 1:o + 1 + n].decode())
            o += 1 + n
        return ".".join(parts) or None
    except Exception:
        return None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pcap", type=Path)
    ap.add_argument("--dvr", help="DVR IP（只展開與 DVR 相關的連線細節）")
    ap.add_argument("--user", help="DVR 帳號（用來從 Keychain 取密碼做遮蔽）")
    ap.add_argument("--out", type=Path, help="報告輸出路徑（預設：<pcap>.report.md）")
    ap.add_argument("--stdout", action="store_true", help="同時輸出到終端機")
    a = ap.parse_args()
    red = Redactor(keychain_secrets(a.user, a.dvr))
    rep = analyze(a.pcap, a.dvr, red)
    out = a.out or a.pcap.with_suffix(a.pcap.suffix + ".report.md")
    out.write_text(rep, encoding="utf-8")
    out.chmod(0o600)
    if a.stdout:
        print(rep)
    print(f"報告：{out}", file=sys.stderr)


if __name__ == "__main__":
    main()
