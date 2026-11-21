#!/usr/bin/env python3
"""微泰 MTM-1 帧编解码（12 字节头）。

    python3 mtm1_frames.py parse "01 00 10 00 80 1c 00 01 00 33 ..."
    python3 mtm1_frames.py build  --addr 01 --src 00 --dst 01 --mode 00 --op 02 --param 33 --data "aa bb"

帧结构：
    0 addr | 1 port | 2 length(=12+n) | 3 offset | 4 seq|0x80 | 5 crc8
    6 sourcePort | 7 targetPort | 8..9 crc16(LE) | 10 mode | 11 operation | 12.. data
CRC16 覆盖 byte6..7 + byte10..11 + data。
"""

import sys

CRC8_TABLE = []
for i in range(256):
    c = i
    for _ in range(8):
        c = (c >> 1) ^ 0x8C if c & 1 else c >> 1
    CRC8_TABLE.append(c)

CRC16_TABLE = []
for i in range(256):
    c = i
    for _ in range(8):
        c = (c >> 1) ^ 0xA001 if c & 1 else c >> 1
    CRC16_TABLE.append(c & 0xFFFF)


def crc8(data, init=0):
    c = init
    for b in data:
        c = CRC8_TABLE[(c ^ b) & 0xFF]
    return c


def crc16(data, init=0xFFFF):
    c = init
    for b in data:
        c = (CRC16_TABLE[(c ^ b) & 0xFF] ^ (c >> 8)) & 0xFFFF
    return c


def build(addr, src_port, dst_port, mode, op, data,
          seq=0, offset=0, last=True, port=0):
    body = bytes([src_port & 0xFF, dst_port & 0xFF])
    trailer = bytes([mode & 0xFF, op & 0xFF])
    crc = crc16(body)
    crc = crc16(trailer, crc)
    crc = crc16(data, crc)
    head5 = bytes([addr & 0xFF, port & 0xFF, (12 + len(data)) & 0xFF,
                   offset & 0xFF, (seq & 0x3F) | (0x80 if last else 0)])
    return head5 + bytes([crc8(head5)]) + body + \
        bytes([crc & 0xFF, (crc >> 8) & 0xFF]) + trailer + data


def parse_stream(raw):
    frames, off = [], 0
    while off + 12 <= len(raw):
        length = raw[off + 2]
        if length < 12 or off + length > len(raw):
            print(f"[!] 帧长异常 offset={off} len={length}")
            break
        f = raw[off:off + length]
        data = f[12:]
        crc8_ok = crc8(f[:5]) == f[5]
        calc = crc16(f[6:8])
        calc = crc16(f[10:12], calc)
        calc = crc16(data, calc)
        crc16_ok = calc == int.from_bytes(f[8:10], "little")
        frames.append({
            "offset": off, "addr": f[0], "port": f[1], "len": f[2],
            "fragment": f[3], "seq": f[4] & 0x3F, "last": bool(f[4] & 0x80),
            "crc8_ok": crc8_ok, "crc16_ok": crc16_ok,
            "src": f[6], "dst": f[7], "mode": f[10], "op": f[11],
            "data": data,
        })
        off += length
    return frames


def reassemble(frames):
    buf = bytearray()
    for f in frames:
        buf.extend(f["data"])
    return bytes(buf)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    cmd = sys.argv[1]
    if cmd == "parse":
        raw = bytes.fromhex(sys.argv[2].replace(" ", ""))
        for f in parse_stream(raw):
            print(f"@{f['offset']:04x} addr={f['addr']:02x} src={f['src']:02x} "
                  f"dst={f['dst']:02x} mode={f['mode']} op={f['op']} "
                  f"len={f['len']:3d} frag={f['fragment']:3d} seq={f['seq']:2d} "
                  f"last={f['last']} crc8={'OK' if f['crc8_ok'] else 'BAD'} "
                  f"crc16={'OK' if f['crc16_ok'] else 'BAD'} data={f['data'].hex(' ')}")
        data = reassemble(parse_stream(raw))
        if data:
            print("重组:", data.hex(" "))
    else:
        args = dict(zip(sys.argv[2::2], sys.argv[3::2]))
        payload = bytes.fromhex(args.get("--data", "").replace(" ", ""))
        frame = build(
            int(args.get("--addr", "00"), 16), int(args.get("--src", "00"), 16),
            int(args.get("--dst", "00"), 16), int(args.get("--mode", "00"), 16),
            int(args.get("--op", "00"), 16), payload)
        print(frame.hex(" "))


if __name__ == "__main__":
    main()
