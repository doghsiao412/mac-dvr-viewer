#!/usr/bin/env python3
"""pcap_analyze.py 的自我測試：產生合成 pcap（假資料），確認協定辨識與遮蔽正確。

執行：python3 -I tools/tests/test_pcap_analyze.py
這是 Mock 測試，不代表實體 DVR 驗證。
"""
import importlib.util
import struct
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("pa", HERE.parent / "pcap_analyze.py")
pa = importlib.util.module_from_spec(spec)
sys.modules["pa"] = pa
spec.loader.exec_module(pa)

FAKE_PW = b"Fake-Pw-1234"
CLIENT, DVR = "192.168.1.20", "192.168.1.100"


def ip4(s):
    return bytes(int(x) for x in s.split("."))


def tcp_pkt(src, sp, dst, dp, seq, ack, flags, payload=b""):
    tcp = struct.pack(">HHIIBBHHH", sp, dp, seq, ack, 5 << 4, flags, 65535, 0, 0) + payload
    ip = struct.pack(">BBHHHBBH4s4s", 0x45, 0, 20 + len(tcp), 0, 0, 64, 6, 0, ip4(src), ip4(dst)) + tcp
    eth = b"\x00" * 12 + b"\x08\x00"
    return eth + ip


class Conv:
    def __init__(self, sp, dp):
        self.sp, self.dp = sp, dp
        self.cs, self.ss = 1000, 5000
        self.pkts = [tcp_pkt(CLIENT, sp, DVR, dp, self.cs - 1, 0, 0x02),
                     tcp_pkt(DVR, dp, CLIENT, sp, self.ss - 1, self.cs, 0x12)]

    def c(self, data):
        self.pkts.append(tcp_pkt(CLIENT, self.sp, DVR, self.dp, self.cs, self.ss, 0x18, data))
        self.cs += len(data)

    def s(self, data):
        self.pkts.append(tcp_pkt(DVR, self.dp, CLIENT, self.sp, self.ss, self.cs, 0x18, data))
        self.ss += len(data)


def write_pcap(path, pkts):
    with open(path, "wb") as f:
        f.write(struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 1))
        for i, p in enumerate(pkts):
            f.write(struct.pack("<IIII", 1700000000 + i // 10, (i % 10) * 100000, len(p), len(p)) + p)


H264 = b"\x00\x00\x00\x01\x67\x42\x00\x1f" + b"\x00\x00\x00\x01\x68\xce" + b"\x00\x00\x00\x01\x65" + b"\x88" * 50
H265 = b"\x00\x00\x00\x01\x40\x01\x0c" + b"\x00\x00\x00\x01\x42\x01\x01" + b"\x00\x00\x00\x01\x44\x01" + b"\x00\x00\x00\x01\x26\x01" + b"\xaa" * 50


def build():
    pk = []
    # 1) RTSP + Digest + SDP(H264) + interleaved
    r = Conv(50001, 554)
    r.c(b"DESCRIBE rtsp://admin:" + FAKE_PW + b"@192.168.1.100:554/chID=1&streamType=main RTSP/1.0\r\nCSeq: 2\r\n\r\n")
    r.s(b'RTSP/1.0 401 Unauthorized\r\nCSeq: 2\r\nWWW-Authenticate: Digest realm="RTSP SERVER", nonce="abc123secret"\r\n\r\n')
    sdp = b"v=0\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\n"
    r.c(b'DESCRIBE rtsp://192.168.1.100:554/chID=1&streamType=main RTSP/1.0\r\nCSeq: 3\r\nAuthorization: Digest username="admin", realm="RTSP SERVER", response="deadbeef"\r\n\r\n')
    r.s(b"RTSP/1.0 200 OK\r\nCSeq: 3\r\nContent-Type: application/sdp\r\nContent-Length: %d\r\n\r\n" % len(sdp) + sdp)
    r.s(b"$\x00\x00\x40" + H264)
    pk += r.pkts
    # 2) TVT IPC：head + login + live stream(H265)
    t = Conv(50002, 9008)
    t.s(b"head" + b"\x00" * 60)
    login_data = struct.pack("<I", 1) + b"admin".ljust(32, b"\0") + FAKE_PW.ljust(32, b"\0") + b"\0" * 48
    body = struct.pack("<IIII", 0x101, 1, 1, len(login_data)) + login_data
    t.c(b"1111" + struct.pack("<I", len(body)) + body)
    rep = struct.pack("<IIII", 0x1000101, 1, 1, 0)
    t.s(b"1111" + struct.pack("<I", len(rep)) + rep)
    live = struct.pack("<IIII", 0x1000C01, 2, 1, len(H265)) + H265
    t.s(b"1111" + struct.pack("<I", len(live)) + live)
    pk += t.pkts
    # 3) NVMS-9000 XML 在專有二進位標頭內
    n = Conv(50003, 6036)
    xml = (b"<?xml version='1.0' encoding='utf-8'?><request version='1.0' systemType='NVMS-9000' clientType='MOBILE' url='doLogin'>"
           b"<content><userName>admin</userName><password>" + FAKE_PW + b"</password><token>tok-xyz</token></content></request>")
    n.c(b"\x31\x31\x31\x31" + struct.pack("<I", len(xml) + 16) + b"\x00" * 24 + xml)
    xml2 = b"<?xml version='1.0' encoding='utf-8'?><response><status>success</status><content><sessionId>SESS-999</sessionId></content></response>"
    n.s(b"\x31\x31\x31\x31" + struct.pack("<I", len(xml2) + 16) + b"\x00" * 24 + xml2)
    pk += n.pkts
    return pk


def main():
    with tempfile.TemporaryDirectory() as td:
        p = Path(td) / "fixture.pcap"
        write_pcap(p, build())
        red = pa.Redactor([FAKE_PW, b"admin:" + FAKE_PW])
        rep = pa.analyze(p, DVR, red)
        checks = {
            "辨識 RTSP": "RTSP" in rep,
            "SDP H264": "H264/90000" in rep,
            "RTP interleaved": "RTP-over-RTSP" in rep,
            "辨識 TVT IPC": "TVT-IPC" in rep and "CMD_REQUEST_LOGIN" in rep and "CMD_REPLY_LOGIN_SUCC" in rep,
            "H.265 偵測": "H.265/HEVC" in rep,
            "H.264 偵測": "H.264/AVC" in rep,
            "NVMS XML": "doLogin" in rep,
            "密碼已遮蔽": FAKE_PW.decode() not in rep,
            "token 已遮蔽": "tok-xyz" not in rep and "SESS-999" not in rep,
            "nonce 已遮蔽": "abc123secret" not in rep,
            "Digest response 已遮蔽": "deadbeef" not in rep,
            "保留 Digest realm": 'Digest realm="RTSP SERVER"' in rep,
        }
        ok = all(checks.values())
        for k, v in checks.items():
            print(("✅" if v else "❌"), k)
        if not ok:
            print(rep)
            sys.exit(1)
        print("全部通過（Mock 資料）")


if __name__ == "__main__":
    main()
