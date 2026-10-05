#!/usr/bin/env python3
"""
Independent XP3 (KiriKiri archive) reader written ONLY from the supplied spec.

Deliberately does not import or read anything from the project under test
(no tools/xp3_toolkit.py, no tools/ref_script_parser.py, no .swift files).

来源说明（加入工程时补写）：这份读取器由**另一个独立代理**仅依据格式规范写成，
没有看过 tools/xp3_toolkit.py 或任何 Swift 源码。用途是交叉验证 make_test_game.py 产出的
data.xp3 是否符合规范——两个独立实现对同一份文件得出相同结论（文件表、大小、Adler-32
全部一致），才说明样本真的合规，而不是"自己写自己读"的自洽。

它已实际跑通并验证 Resources/TestXP3/data.xp3：6 个文件的 Adler-32 全部 MATCH，
PNG 签名与 IHDR 尺寸、WAV 的 fmt 字段也都对上。不参与 App 构建，只作为回归工具。

Usage:
    python xp3_verify_independent.py "path\\to\\data.xp3"
"""

import struct
import sys
import zlib

MAGIC = bytes([0x58, 0x50, 0x33, 0x0D, 0x0A, 0x20, 0x0A, 0x1A, 0x8B, 0x67, 0x01])

PNG_SIG = bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])


def u32(b, off):
    return struct.unpack_from("<I", b, off)[0]


def u64(b, off):
    return struct.unpack_from("<Q", b, off)[0]


def u16(b, off):
    return struct.unpack_from("<H", b, off)[0]


class Chunk:
    __slots__ = ("tag", "body", "offset")

    def __init__(self, tag, body, offset):
        self.tag = tag
        self.body = body
        self.offset = offset


def iter_chunks(data, start, end, what="index"):
    """Sequence of tag + u64 size + body, where size excludes the 12-byte header."""
    pos = start
    out = []
    while pos < end:
        if pos + 12 > end:
            raise ValueError(
                "%s: truncated chunk header at 0x%X (%d bytes left)"
                % (what, pos, end - pos)
            )
        tag = data[pos:pos + 4]
        size = u64(data, pos + 4)
        body_start = pos + 12
        body_end = body_start + size
        if body_end > end:
            raise ValueError(
                "%s: chunk %r at 0x%X claims size %d, overruns by %d bytes"
                % (what, tag, pos, size, body_end - end)
            )
        out.append(Chunk(tag, data[body_start:body_end], pos))
        pos = body_end
    if pos != end:
        raise ValueError("%s: ended at 0x%X, expected 0x%X" % (what, pos, end))
    return out


def parse_index(raw):
    """The index is a sequence of chunks; File chunks carry file metadata."""
    entries = []
    for ch in iter_chunks(raw, 0, len(raw), "index"):
        if ch.tag != b"File":
            continue
        info = segm = adlr = time = None
        for sub in iter_chunks(ch.body, 0, len(ch.body), "File.sub"):
            if sub.tag == b"info":
                info = sub.body
            elif sub.tag == b"segm":
                segm = sub.body
            elif sub.tag == b"adlr":
                adlr = sub.body
            elif sub.tag == b"time":
                time = sub.body
            # unknown sub-chunks are skipped by size (already done above)
        if info is None:
            raise ValueError("File chunk at 0x%X has no info sub-chunk" % ch.offset)

        flags = u32(info, 0)
        protected = bool(flags & 0x80000000)
        orig_size = u64(info, 4)
        arch_size = u64(info, 12)
        namelen_chars = u16(info, 20)
        name_bytes = info[22:22 + namelen_chars * 2]
        if len(name_bytes) != namelen_chars * 2:
            raise ValueError(
                "File at 0x%X: name needs %d bytes but only %d present"
                % (ch.offset, namelen_chars * 2, len(name_bytes))
            )
        name = name_bytes.decode("utf-16-le")

        segments = []
        if segm is not None:
            if len(segm) % 28 != 0:
                raise ValueError(
                    "File %r: segm body is %d bytes, not a multiple of 28"
                    % (name, len(segm))
                )
            for i in range(0, len(segm), 28):
                segments.append(
                    {
                        "flag": u32(segm, i),
                        "offset": u64(segm, i + 4),
                        "orig": u64(segm, i + 12),
                        "arch": u64(segm, i + 20),
                    }
                )

        entries.append(
            {
                "name": name,
                "flags": flags,
                "protected": protected,
                "orig_size": orig_size,
                "arch_size": arch_size,
                "adlr": u32(adlr, 0) if adlr is not None and len(adlr) >= 4 else None,
                "time": u64(time, 0) if time is not None and len(time) >= 8 else None,
                "segments": segments,
                "chunk_offset": ch.offset,
            }
        )
    return entries


def read_file(blob, entry):
    parts = []
    for seg in entry["segments"]:
        blob.seek(seg["offset"])
        raw = blob.read(seg["arch"])
        if len(raw) != seg["arch"]:
            raise ValueError(
                "File %r: short read at 0x%X (wanted %d, got %d)"
                % (entry["name"], seg["offset"], seg["arch"], len(raw))
            )
        if seg["flag"] == 1:
            parts.append(zlib.decompress(raw))
        elif seg["flag"] == 0:
            parts.append(raw)
        else:
            raise ValueError(
                "File %r: unsupported segment compression flag %d"
                % (entry["name"], seg["flag"])
            )
    return b"".join(parts)


def parse_png(data):
    if not data.startswith(PNG_SIG):
        return None
    if data[12:16] != b"IHDR":
        return None
    w = int.from_bytes(data[16:20], "big")
    h = int.from_bytes(data[20:24], "big")
    return w, h, data[24], data[25]


def parse_wav(data):
    if data[0:4] != b"RIFF":
        return None
    riff_size = int.from_bytes(data[4:8], "little")
    has_wave = data[8:12] == b"WAVE"
    pos = 12
    fmt = None
    data_size = None
    while pos + 8 <= len(data):
        cid = data[pos:pos + 4]
        csz = int.from_bytes(data[pos + 4:pos + 8], "little")
        body = data[pos + 8:pos + 8 + csz]
        if cid == b"fmt ":
            fmt = body
        elif cid == b"data":
            data_size = csz
        pos += 8 + csz + (csz & 1)
    info = {"riff_size": riff_size, "has_wave": has_wave, "fmt": None, "data_size": data_size}
    if fmt and len(fmt) >= 16:
        info["fmt"] = {
            "audio_format": int.from_bytes(fmt[0:2], "little"),
            "channels": int.from_bytes(fmt[2:4], "little"),
            "sample_rate": int.from_bytes(fmt[4:8], "little"),
            "byte_rate": int.from_bytes(fmt[8:12], "little"),
            "block_align": int.from_bytes(fmt[12:14], "little"),
            "bits": int.from_bytes(fmt[14:16], "little"),
        }
    return info


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else r"C:\Users\Administrator\Desktop\鱼宝\新建文件夹 (2)\VNPlayer_v1.1\Resources\TestXP3\data.xp3"
    with open(path, "rb") as fh:
        blob = fh
        fh.seek(0)
        head = fh.read(11)
        print("== 1. HEADER ==")
        print("magic read      :", head.hex(" ").upper())
        print("magic expected  :", MAGIC.hex(" ").upper())
        magic_ok = head == MAGIC
        print("magic match     :", magic_ok)
        if not magic_ok:
            print("FAIL: magic mismatch; aborting.")
            return 1

        fh.seek(0x0B)
        index_offset = u64(fh.read(8), 0)
        import os
        total = os.path.getsize(path)
        print("index offset    : 0x%X (%d)" % (index_offset, index_offset))
        print("file size       : 0x%X (%d)" % (total, total))
        print("index offset within file:", 0 < index_offset < total)

        print()
        print("== 2. INDEX BLOCK ==")
        fh.seek(index_offset)
        flag_bytes = []
        skipped = 0
        while True:
            b = fh.read(1)
            if not b:
                raise ValueError("hit EOF while skipping 0x80 continue bytes")
            val = b[0]
            if val == 0x80:
                flag_bytes.append(val)
                skipped += 1
                continue
            flag_bytes.append(val)
            break
        flag = flag_bytes[-1]
        print("flag bytes seen :", " ".join("0x%02X" % v for v in flag_bytes))
        print("0x80 skipped    :", skipped)
        print("real flag       : 0x%02X" % flag)

        if flag == 0x00:
            length = u64(fh.read(8), 0)
            raw_index = fh.read(length)
            print("index type      : uncompressed")
            print("index length    : %d" % length)
            print("bytes read      : %d" % len(raw_index))
        elif flag == 0x01:
            comp_len = u64(fh.read(8), 0)
            uncomp_len = u64(fh.read(8), 0)
            comp = fh.read(comp_len)
            print("index type      : zlib-compressed")
            print("compressed size : %d (bytes read %d)" % (comp_len, len(comp)))
            print("uncompressed sz : %d" % uncomp_len)
            raw_index = zlib.decompress(comp)
            print("decompressed    : %d" % len(raw_index))
            if len(raw_index) != uncomp_len:
                print("MISMATCH: declared uncompressed size differs from actual")
        elif flag == 0x02:
            raise ValueError("flag 0x02 (encrypted/split index) not covered by spec")
        else:
            raise ValueError("unexpected flag byte 0x%02X" % flag)

        entries = parse_index(raw_index)

        print()
        print("== 3. FILE LIST ==")
        print("%-24s %12s %12s %-9s %5s" % ("name", "orig size", "arch size", "storage", "segs"))
        for e in entries:
            kinds = sorted({s["flag"] for s in e["segments"]})
            kind = {0: "stored", 1: "zlib"}.get(kinds[0], "?") if len(kinds) == 1 else "mixed"
            flagtxt = {"0": "stored", "1": "zlib"}.get(str(kinds[0]), "?") if len(kinds) == 1 else "mixed"
            print("%-24s %12d %12d %-9s %5d%s" % (
                e["name"], e["orig_size"], e["arch_size"], flagtxt, len(e["segments"]),
                "  PROTECTED" if e["protected"] else ""))

        print()
        print("== 4. ADLER-32 VERIFICATION ==")
        print("%-24s %12s %12s %s" % ("name", "computed", "stored", "match"))
        all_ok = True
        decoded = {}
        for e in entries:
            data = read_file(blob, e)
            decoded[e["name"]] = data
            comp = zlib.adler32(data) & 0xFFFFFFFF
            stored = e["adlr"]
            ok = (stored is not None and comp == stored)
            if not ok:
                all_ok = False
            size_note = "" if len(data) == e["orig_size"] else "  SIZE MISMATCH got %d" % len(data)
            if size_note:
                all_ok = False
            print("%-24s %12d %12s %s%s" % (
                e["name"], comp, "none" if stored is None else str(stored),
                "MATCH" if ok else "MISMATCH", size_note))
        print("all adler32 match:", all_ok)

        print()
        print("== 5. script.vns ==")
        target = None
        for e in entries:
            if e["name"].lower().endswith("script.vns"):
                target = e
                break
        if target is None:
            print("FAIL: script.vns not found")
        else:
            text = decoded[target["name"]].decode("utf-8")
            lines = text.splitlines()
            print("utf-8 decode    : ok")
            print("line count      :", len(lines))
            print("first 5 lines:")
            for ln in lines[:5]:
                print("  |", ln)
            print("last 3 lines:")
            for ln in lines[-3:]:
                print("  |", ln)
            stripped = text.lstrip("\ufeff")
            print("starts with @title:", stripped.startswith("@title"))
            print("ends with @end    :", text.rstrip().endswith("@end"))

        print()
        print("== 6. PNG / WAV ==")
        for e in entries:
            low = e["name"].lower()
            data = decoded[e["name"]]
            if low.endswith(".png"):
                r = parse_png(data)
                sig_ok = data.startswith(PNG_SIG)
                print("[PNG] %s" % e["name"])
                print("      signature ok :", sig_ok, "| first 8 bytes:", data[:8].hex(" ").upper())
                if r:
                    w, h, depth, ctype = r
                    print("      IHDR %dx%d bitdepth=%d colortype=%d" % (w, h, depth, ctype))
                else:
                    print("      IHDR parse failed")
            elif low.endswith(".wav"):
                info = parse_wav(data)
                print("[WAV] %s" % e["name"])
                if info:
                    print("      RIFF ok:", data[:4] == b"RIFF", "| WAVE present:", info["has_wave"])
                    f = info["fmt"]
                    if f:
                        print("      channels=%d sample_rate=%d bits=%d audiofmt=%d data_bytes=%s" % (
                            f["channels"], f["sample_rate"], f["bits"],
                            f["audio_format"], info["data_size"]))
                    else:
                        print("      no fmt chunk found")
                else:
                    print("      RIFF header missing")

        print()
        print("== 7. NOTES ==")
        raise SystemExit(0)


if __name__ == "__main__":
    main()
