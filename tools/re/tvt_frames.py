#!/usr/bin/env python3
"""TVT NVMS 私有協定（6036）訊息列表 — 開發用逆向工具。

用法：python3 -I tools/re/tvt_frames.py <pcap> --port 6036 [--user <帳號> --dvr <IP>] [--max 80] [--hex 48]
重組 TCP 串流後依 "1111"+u32 長度 切割訊息，列出命令碼與欄位。
會用 Keychain 密碼遮蔽輸出（同 pcap_analyze.py）。
"""
import argparse, collections, importlib.util, struct, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("pa", Path(__file__).resolve().parent.parent / "pcap_analyze.py")
pa = importlib.util.module_from_spec(spec); sys.modules["pa"] = pa; spec.loader.exec_module(pa)

def frames(b):
    o = 0; out = []; frag = {}
    while o + 8 <= len(b):
        if b[o:o+4] == b"head":
            out.append((o, "HEAD", b[o:o+64])); o += 64; continue
        if b[o:o+4] != b"1111":
            n = b.find(b"1111", o + 1)
            if n < 0: break
            out.append((o, "GAP", b[o:n])); o = n; continue
        ln = struct.unpack_from("<I", b, o + 4)[0]
        if ln == 0xFFFFFFFF:  # 分段訊息：id, 分段數, 總長, 第幾段, 本段長度, 0
            mid, cnt, total, idx, flen, _ = struct.unpack_from("<6I", b, o + 8)
            frag.setdefault(mid, bytearray()).extend(b[o+32:o+32+flen])
            if idx >= cnt: out.append((o, "MSG", bytes(frag.pop(mid))))
            o += 32 + flen; continue
        out.append((o, "MSG", b[o+8:o+8+ln])); o += 8 + ln
    return out

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("pcap", type=Path); ap.add_argument("--port", type=int, default=6036)
    ap.add_argument("--user"); ap.add_argument("--dvr"); ap.add_argument("--max", type=int, default=80); ap.add_argument("--hex", type=int, default=48)
    ap.add_argument("--summary", action="store_true")
    a = ap.parse_args()
    red = pa.Redactor(pa.keychain_secrets(a.user, a.dvr))
    tcp, _, _ = pa.build_flows(a.pcap)
    for f in sorted(tcp.values(), key=lambda f: f.first):
        if f.server[1] != a.port: continue
        print(f"## {f.client[1]} → {f.server[1]}  t={f.first:.2f}-{f.last:.2f} handshake={f.syn_seen}")
        seq = []
        for d, lab in ((f.c2s, "C"), (f.s2c, "S")):
            data, _, gaps = f.reassemble(d)
            for off, kind, body in frames(data):
                # 以 PSH 片段時間近似訊息時間
                seq.append((lab, off, kind, body))
            print(f"  {lab} bytes={len(data)} gaps={gaps}")
        stats = collections.Counter()
        for lab, off, kind, body in seq:
            if kind == "MSG" and len(body) >= 16:
                cmd, sub, cid, dl = struct.unpack_from("<IIII", body)
                stats[(lab, hex(cmd), hex(sub & 0xffff))] += 1
            else:
                stats[(lab, kind, len(body))] += 1
        print("  統計（方向, cmd, sub）：")
        for k, v in sorted(stats.items(), key=lambda x: -x[1])[:40]: print("   ", k, v)
        if a.summary: continue
        shown = collections.Counter()
        for lab, off, kind, body in seq:
            if kind == "MSG" and len(body) >= 16:
                cmd, sub, cid, dl = struct.unpack_from("<IIII", body)
                key = (lab, cmd, sub & 0xffff)
                shown[key] += 1
                if shown[key] > 2: continue
                b = red.bytes(body)
                print(f"  [{lab}] @{off} cmd={cmd:#x} sub={sub:#x} id={cid:#x} dataLen={dl} len={len(body)}")
                print(f"      {pa.hexrow(b[16:16+a.hex], a.hex)}")
                if b"<?xml" in b or b"<request" in b or b"<response" in b:
                    i = min(x for x in (b.find(b"<?xml"), b.find(b"<request"), b.find(b"<response")) if x >= 0)
                    print("      XML:", red.text(b[i:i+700], 700).replace("\n", " "))
            elif kind != "MSG":
                print(f"  [{lab}] @{off} {kind} len={len(body)} {pa.hexrow(red.bytes(body[:32]), 32)}")

main()
