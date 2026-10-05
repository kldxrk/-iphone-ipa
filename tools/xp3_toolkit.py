#!/usr/bin/env python3
"""XP3 归档的参考实现 + 往返测试。

用途与 ref_script_parser.py 相同：本机没有 macOS / Xcode，Swift 无法编译验证，
所以先用 Python 把**同一套算法**写出来，用自己生成的合规样本做往返测试，
再把验证过的算法逐行移植成 Swift。写盘侧（write_xp3）还能造出畸形样本，
用来确认读取侧的容错分支真的会被触发。

字节级依据（多来源交叉验证）：
  magic(11) = 58 50 33 0D 0A 20 0A 1A 8B 67 01
  0x0B      = index_offset, u64 LE（绝对偏移）；krkrz 变体把真值放 0x20
  index     = flag(u8) + [size u64] 或 [packed u64, unpacked u64] + zlib
              flag 0x80 = XP3_INDEX_CONTINUE，可能出现多个，必须循环跳过
  index 内  = 一串 chunk: tag(4 ASCII) + size(u64, 不含自身 12 字节) + body
  File 条目 = info(flags u32, 原始大小 u64, 归档大小 u64, 名字字符数 u16, UTF-16LE)
              + segm(每段 28 字节: 压缩标志 u32, 绝对偏移 u64, 原始大小 u64, 归档大小 u64)
              + adlr(u32 adler32) [+ time(u64)]
  段数据    = 压缩标志 u32 == 1 时是 zlib 包装（RFC1950），否则原样

用法：python xp3_toolkit.py
"""

from __future__ import annotations

import struct
import sys
import zlib
from dataclasses import dataclass, field
from pathlib import Path
from tempfile import TemporaryDirectory

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:  # pragma: no cover
    pass

MAGIC = bytes([0x58, 0x50, 0x33, 0x0D, 0x0A, 0x20, 0x0A, 0x1A, 0x8B, 0x67, 0x01])
TAG_FILE = b"File"
TAG_INFO = b"info"
TAG_SEGM = b"segm"
TAG_ADLR = b"adlr"
TAG_TIME = b"time"
TAG_ELIF = b"eliF"
INDEX_CONTINUE = 0x80
ENC_FLAG = 0x80000000          # info.flags 的 bit31：受保护/加密
MAX_NAME_CHARS = 1024
SEGMENT_SIZE = 28


class XP3Error(Exception):
    pass


# ================================================================ 写盘侧

def _chunk(tag: bytes, body: bytes) -> bytes:
    return tag + struct.pack("<Q", len(body)) + body


@dataclass
class Entry:
    name: str
    data: bytes


def write_xp3(path: Path, entries: list[Entry], *,
              compress_index: bool = True,
              compress_segments: bool = True,
              continue_flags: int = 0,
              junk_top_chunk: bool = False,
              trailing_nul_name: bool = False,
              nul_in_count: bool = False,
              encrypted_flag: bool = False,
              multi_segment: int = 0,
              mz_prefix: bool = False,
              krkrz_header: bool = False,
              split_index: bool = False,
              hostile_index_offset: bool = False,
              hostile_segment_offset: bool = False,
              hostile_segment_size: bool = False,
              hostile_name_length: bool = False,
              zlib_compresslevel: int = 6) -> Path:
    """写一个合规的 XP3。各种开关用来生成边界 / 畸形 / 恶意样本。

    偏移约定：文件内记录的偏移（索引偏移、段偏移）都**相对归档起点**。
    `mz_prefix=True` 时会在归档前加 `MZ` + 垃圾字节，读取侧必须把 base 加到这两处偏移上——
    这正是要验证的那条约定（曾经 Swift 只给段加 base、不给索引加）。
    """
    # krkrz 变体需要 0x20 处能放 8 字节，所以头是 0x28 而不是 19
    header = bytearray(MAGIC + bytes(max(0, (0x28 if krkrz_header else 19) - 11)))
    body = bytearray()
    segments: list[list[tuple[int, int, int, int]]] = []   # (cflag, off, orig, arch)

    for e in entries:
        raw = e.data
        parts: list[bytes] = []
        if multi_segment > 1 and len(raw) > 0:
            step = max(1, len(raw) // multi_segment)
            parts = [raw[i:i + step] for i in range(0, len(raw), step)]
        elif len(raw) > 0:
            parts = [raw]

        segs: list[tuple[int, int, int, int]] = []
        for part in parts:
            off = len(header) + len(body)          # 相对归档起点
            # 谎报"解压后大小"：读取侧必须先验证这个数字是否物理上可能，再据此分配内存
            declared = 0xFFFFFFFFFF if hostile_segment_size else len(part)
            if compress_segments and len(part) > 0:
                packed = zlib.compress(part, zlib_compresslevel)
                if len(packed) < len(part):
                    segs.append((1, off, declared, len(packed)))
                    body += packed
                    continue
            segs.append((0, off, declared, len(part)))
            body += part
        if not segs:                               # 合法的空文件：一段长度全 0
            segs = [(0, len(header) + len(body), 0xFFFFFFFFFF if hostile_segment_size else 0, 0)]
        if hostile_segment_offset:                 # 段偏移是任意 u64
            segs = [(c, 0xFFFFFFFFFFFFFFFF, o, a) for (c, _o, o, a) in segs]
        segments.append(segs)

    index = bytearray()
    if junk_top_chunk:
        index += _chunk(b"Hxv4", b"junk-data-to-be-skipped")

    for e, segs in zip(entries, segments):
        name_bytes = e.name.encode("utf-16-le")
        name_chars = len(name_bytes) // 2
        if nul_in_count:
            # 有的实现把结尾的 NUL 也算进字符数：读取侧必须能容忍
            name_bytes = name_bytes + b"\x00\x00"
            name_chars += 1
        if hostile_name_length:
            name_chars = 0xFFFF              # u16 上限：读取侧应忽略该条目，而不是按此长度去读
        info_body = struct.pack("<IQQH", ENC_FLAG if encrypted_flag else 0,
                                len(e.data), len(e.data), name_chars) + name_bytes
        if trailing_nul_name:
            info_body += b"\x00\x00"         # NUL 在字符数之外
        file_body = _chunk(TAG_INFO, info_body)
        segm_body = b"".join(struct.pack("<IQQQ", *s) for s in segs)
        file_body += _chunk(TAG_SEGM, segm_body)
        file_body += _chunk(TAG_ADLR, struct.pack("<I", zlib.adler32(e.data) & 0xFFFFFFFF))
        file_body += _chunk(TAG_TIME, struct.pack("<Q", 1700000000))
        index += _chunk(TAG_FILE, bytes(file_body))

    if compress_index:
        packed = zlib.compress(bytes(index), zlib_compresslevel)
        block = bytes([INDEX_CONTINUE]) * continue_flags + bytes([1]) \
            + struct.pack("<QQ", len(packed), len(index)) + packed
    else:
        block = bytes([INDEX_CONTINUE]) * continue_flags + bytes([0]) \
            + struct.pack("<Q", len(index)) + bytes(index)

    index_offset = len(header) + len(body)
    tail = block
    if split_index:
        # 旧式「分裂索引」：索引偏移处是 u32 0x80，真索引偏移在 +9。
        # stub 自身长 17 字节，所以真索引块从 stub 之后开始（写成 index_offset 会指向 stub 自己，
        # 读取侧跟着跳回来就会再次解析 stub —— 这正是第一版样本写错的地方）。
        stub = struct.pack("<I", 0x80) + bytes(5) + struct.pack("<Q", index_offset + 17)
        tail = stub + block
    if hostile_index_offset:
        index_offset = 0xFFFFFFFFFFFFFF00     # 索引偏移是任意 u64

    if krkrz_header:
        struct.pack_into("<Q", header, 0x0B, 0x17)       # 假值
        struct.pack_into("<Q", header, 0x20, index_offset)  # 真值
    else:
        struct.pack_into("<Q", header, 0x0B, index_offset)

    prefix = b"MZ" + bytes(64) if mz_prefix else b""
    path.write_bytes(prefix + bytes(header) + bytes(body) + tail)
    return path


# ================================================================ 读取侧

@dataclass
class XP3Segment:
    compressed: bool
    offset: int
    original_size: int
    archived_size: int


@dataclass
class XP3Entry:
    name: str
    original_size: int
    archived_size: int
    protected: bool
    adler32: int | None = None
    segments: list[XP3Segment] = field(default_factory=list)


class Reader:
    """带边界检查的游标读取器；任何越界都抛 XP3Error 而不是崩掉。"""

    def __init__(self, data: bytes | bytearray, start: int = 0, end: int | None = None):
        self.data = data
        self.pos = start
        self.end = len(data) if end is None else end

    def need(self, n: int) -> None:
        if n < 0 or self.pos + n > self.end:
            raise XP3Error(f"数据越界：需要 {n} 字节，剩余 {self.end - self.pos}")

    def u8(self) -> int:
        self.need(1)
        v = self.data[self.pos]
        self.pos += 1
        return v

    def u16(self) -> int:
        self.need(2)
        v = struct.unpack_from("<H", self.data, self.pos)[0]
        self.pos += 2
        return v

    def u32(self) -> int:
        self.need(4)
        v = struct.unpack_from("<I", self.data, self.pos)[0]
        self.pos += 4
        return v

    def u64(self) -> int:
        self.need(8)
        v = struct.unpack_from("<Q", self.data, self.pos)[0]
        self.pos += 8
        return v

    def take(self, n: int) -> bytes:
        self.need(n)
        v = bytes(self.data[self.pos:self.pos + n])
        self.pos += n
        return v

    def skip(self, n: int) -> None:
        self.need(n)
        self.pos += n

    @property
    def remaining(self) -> int:
        return self.end - self.pos


def _split_dir(path: str) -> tuple[str, str]:
    """对应 NSString.deletingLastPathComponent / lastPathComponent。"""
    idx = path.rfind("/")
    return (path[:idx], path[idx + 1:]) if idx >= 0 else ("", path)


def _split_ext(basename: str) -> tuple[str, str]:
    """对应 NSString.deletingPathExtension / pathExtension。

    取**最后**一个点（"archive.tar.gz" → ("archive.tar", "gz")），
    并且前导点不算扩展名分隔符（".gitignore" → (".gitignore", "")）——与 NSString 语义一致。
    """
    idx = basename.rfind(".")
    if idx <= 0:
        return basename, ""
    return basename[:idx], basename[idx + 1:]


def inflate_zlib(raw: bytes, expected: int) -> bytes:
    """XP3 用 zlib 包装（RFC1950），不是 raw deflate。

    Swift 侧会按 expected 预分配内存，所以两边都先用 deflate 的物理压缩比上界挡一道
    （理论最大约 1032:1），免得一个 1KB 的压缩流谎称解压后有 8GB。
    """
    if expected and expected > len(raw) * 1032:
        raise XP3Error(f"声明的解压大小不合理：{expected} 字节 / 压缩后 {len(raw)} 字节")
    try:
        out = zlib.decompress(raw)
    except zlib.error as exc:
        raise XP3Error(f"zlib 解压失败：{exc}") from exc
    if expected and len(out) != expected:
        raise XP3Error(f"解压后大小不符：期望 {expected}，实际 {len(out)}")
    return out


class XP3Archive:
    def __init__(self, path: Path):
        self.data = path.read_bytes()
        self.path = path
        self.entries: list[XP3Entry] = []
        self.warnings: list[str] = []
        self._by_name: dict[str, XP3Entry] = {}
        self._parse()

    # ------------------------------------------------ 头部 & 索引

    def _index_offset(self) -> int:
        if len(self.data) < 19:
            raise XP3Error("文件太小，不是 XP3")
        if self.data[:11] != MAGIC:
            # 有些归档整个塞在 exe 里（MZ 头），在文件里搜 magic 得到归档起点
            found = self.data.find(MAGIC)
            if found < 0:
                raise XP3Error("magic 不匹配")
            self.warnings.append(f"归档内嵌在可执行文件中，基址 0x{found:X}")
            self.base = found
        else:
            self.base = 0
        # 与 Swift 一致：文件里记录的偏移一律相对归档起点，所以统一加 base
        value = struct.unpack_from("<Q", self.data, self.base + 11)[0]
        if value == 0x17 and len(self.data) >= self.base + 0x28:
            candidate = struct.unpack_from("<Q", self.data, self.base + 0x20)[0]
            if 0 < candidate < len(self.data):
                self.warnings.append("使用 krkrz 变体头（真索引偏移在 0x20）")
                return self.base + candidate
        return self.base + value

    def _index_bytes(self, offset: int) -> bytes:
        r = Reader(self.data, offset)
        flag = r.u8()
        guard = 0
        while flag == INDEX_CONTINUE and guard < 64:
            flag = r.u8()
            guard += 1
        if flag == 1:
            packed_size = r.u64()
            unpacked_size = r.u64()
            raw = r.take(packed_size)
            return inflate_zlib(raw, unpacked_size)
        if flag == 0:
            size = r.u64()
            return r.take(size)
        raise XP3Error(f"无法识别的索引标志 0x{flag:02X}")

    def _split_index_bytes(self, offset: int) -> bytes:
        """旧式「分裂索引」：index_offset 处是 u32 0x80，真索引偏移在 +9。

        必须只在前 4 字节确实等于 0x80 时尝试，并且每一步都要边界检查——
        否则一个被截断的普通归档会走到这里越界读取（Swift 里就是数组越界崩溃）。
        """
        if offset < 0 or offset + 17 > len(self.data):
            raise XP3Error("分裂索引头部越界")
        if struct.unpack_from("<I", self.data, offset)[0] != 0x80:
            raise XP3Error("不是分裂索引")
        target = struct.unpack_from("<Q", self.data, offset + 9)[0] + self.base
        if not 0 < target < len(self.data):
            raise XP3Error("分裂索引偏移越界")
        return self._index_bytes(target)

    def _parse(self) -> None:
        offset = self._index_offset()
        try:
            index = self._index_bytes(offset)
        except XP3Error as first:
            try:
                index = self._split_index_bytes(offset)
                self.warnings.append("使用旧式分裂索引跳转")
            except XP3Error:
                raise first

        r = Reader(index)
        while r.remaining >= 12:
            tag = r.take(4)
            size = r.u64()
            if size > r.remaining:
                # 已知实现只容忍 info 的尺寸写错，这里对顶层 chunk 直接截断到剩余长度
                self.warnings.append(f"chunk {tag!r} 尺寸越界，已截断")
                size = r.remaining
            body_start = r.pos
            if tag == TAG_FILE:
                entry = self._parse_file(Reader(index, body_start, body_start + size))
                if entry is not None:
                    self.entries.append(entry)
                    self._by_name[entry.name.lower()] = entry
            else:
                # Hxv4 / yuz: / sen: / dls: / hnfn / smil / eliF / Yuzu … 一律跳过
                pass
            r.pos = body_start + size

        if not self.entries:
            raise XP3Error("索引里没有可用的文件条目")

    def _parse_file(self, r: Reader) -> XP3Entry | None:
        name = None
        original_size = 0
        archived_size = 0
        protected = False
        adler = None
        segments: list[XP3Segment] = []
        encrypted_record: tuple[int, str] | None = None

        while r.remaining >= 12:
            tag = r.take(4)
            size = r.u64()
            if size > r.remaining:
                if tag != TAG_INFO:
                    break
                size = r.remaining            # 只容忍 info 的尺寸不准
            body_start = r.pos
            sub = Reader(r.data, body_start, body_start + size)

            if tag == TAG_INFO:
                flags = sub.u32()
                original_size = sub.u64()
                archived_size = sub.u64()
                name_chars = sub.u16()
                name_bytes = sub.take(min(name_chars * 2, sub.remaining))
                name = name_bytes.decode("utf-16-le", errors="replace")
                if name_bytes.endswith(b"\x00\x00"):     # 某些实现多写一个终止符
                    name = name[:-1]
                protected = bool(flags & ENC_FLAG)
                if name_chars > MAX_NAME_CHARS:
                    self.warnings.append(f"文件名过长（{name_chars} 字符），已忽略该条目")
                    return None
            elif tag == TAG_SEGM:
                while sub.remaining >= SEGMENT_SIZE:
                    cflag = sub.u32()
                    offset = sub.u64()
                    seg_orig = sub.u64()
                    seg_arch = sub.u64()
                    segments.append(XP3Segment(cflag == 1, offset, seg_orig, seg_arch))
                if sub.remaining:
                    self.warnings.append(f"segm 尾部有 {sub.remaining} 字节余量，已忽略")
            elif tag == TAG_ADLR:
                adler = sub.u32()
            elif tag == TAG_ELIF:
                # 文件名被挪到 File 之前的 eliF 记录：u64 size + u32 adler + u16 字符数 + UTF-16LE
                elif_size = sub.u64()
                elif_adler = sub.u32()
                elif_chars = sub.u16()
                elif_name = sub.take(min(elif_chars * 2, sub.remaining)).decode("utf-16-le", errors="replace").rstrip("\x00")
                encrypted_record = (elif_adler, elif_name)
                if elif_size == 0 or elif_name:
                    pass
            elif tag == TAG_TIME:
                pass
            else:
                pass

            r.pos = body_start + size

        if name is None or not name:
            if encrypted_record is not None:
                adler, name = encrypted_record
                self.warnings.append(f"条目名来自 eliF 记录：{name}")
            else:
                return None
        return XP3Entry(name=name, original_size=original_size, archived_size=archived_size,
                        protected=protected, adler32=adler, segments=segments)

    # ------------------------------------------------ 读取

    def list_files(self) -> list[str]:
        return sorted(e.name for e in self.entries)

    @staticmethod
    def normalize(name: str) -> str:
        """与 Swift 的 XP3Archive.normalize 逐行一致：只剥离开头的 "./" 与 "/"。"""
        value = name.replace("\\", "/")
        while value.startswith("./"):
            value = value[2:]
        while value.startswith("/"):
            value = value[1:]
        return value.lower()

    def entry(self, name: str) -> XP3Entry | None:
        """与 Swift 一致：精确匹配，否则「去掉扩展名后唯一匹配」，且目录/扩展名必须相容。"""
        key = self.normalize(name)
        if not key:
            return None
        if key in self._by_name:
            return self._by_name[key]

        wanted_dir, wanted_base = _split_dir(key)
        wanted_stem, wanted_ext = _split_ext(wanted_base)
        matches = []
        for entry in self.entries:
            candidate = self.normalize(entry.name)
            cand_dir, cand_base = _split_dir(candidate)
            cand_stem, cand_ext = _split_ext(cand_base)
            if cand_stem != wanted_stem:
                continue
            if wanted_ext and cand_ext != wanted_ext:
                continue
            if wanted_dir and cand_dir != wanted_dir:
                continue
            matches.append(entry)
        return matches[0] if len(matches) == 1 else None

    def open(self, entry: XP3Entry) -> bytes:
        if entry.protected:
            raise XP3Error(f"{entry.name} 被标记为受保护（flags bit31），密钥不在格式里")
        out = bytearray()
        for seg in entry.segments:
            # 与 Swift 一致：段偏移同样要加 base（内嵌在 exe 里的归档）
            start = self.base + seg.offset
            if start + seg.archived_size > len(self.data):
                raise XP3Error(f"{entry.name} 的段越界")
            raw = self.data[start:start + seg.archived_size]
            if seg.archived_size == 0:            # 合法的空文件/空段
                continue
            if seg.compressed:
                out += inflate_zlib(raw, seg.original_size)
            else:
                # 未压缩段的"原始大小"字段若与实际长度不符，只记录：内容按实际长度读，是对的
                if seg.original_size != seg.archived_size:
                    self.warnings.append(
                        f"{entry.name} 的未压缩段声明大小与实际不符"
                        f"（{seg.original_size} vs {seg.archived_size}），按实际长度读取")
                out += raw
        if entry.original_size and len(out) != entry.original_size:
            raise XP3Error(f"{entry.name} 大小不符：期望 {entry.original_size}，实际 {len(out)}")
        if entry.adler32 is not None and (zlib.adler32(bytes(out)) & 0xFFFFFFFF) != entry.adler32:
            raise XP3Error(f"{entry.name} 的 adler32 校验失败")
        return bytes(out)

    def read(self, name: str) -> bytes:
        entry = self.entry(name)
        if entry is None:
            raise XP3Error(f"归档里没有 {name}")
        return self.open(entry)


# ================================================================ 测试

FAILURES: list[str] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    if cond:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name} {detail}")
        FAILURES.append(name)


SAMPLE = [
    Entry("script.vns", "@title 测试\n[爱丽丝] 你好\\n第二行\n@end".encode("utf-8")),
    Entry("bg/school.jpg", bytes(range(256)) * 8),
    Entry("bg/roof.jpg", b"\xff\xd8\xff" + b"x" * 5000),      # 高压缩比 → 会走 zlib 段
    Entry("char/alice.png", b"\x89PNG" + bytes(300)),
    Entry("bgm/theme.ogg", b"OggS" + bytes(2000)),
    Entry("empty.txt", b""),
    Entry("说明.txt", "中文文件名与内容".encode("utf-8")),
]


def roundtrip(label: str, path: Path) -> XP3Archive:
    arc = XP3Archive(path)
    check(f"{label}: 条目数", len(arc.entries) == len(SAMPLE), f"{len(arc.entries)} != {len(SAMPLE)}")
    for e in SAMPLE:
        got = arc.read(e.name)
        check(f"{label}: 内容一致 {e.name}", got == e.data,
              f"{len(got)} != {len(e.data)}")
    check(f"{label}: 列表排序", arc.list_files() == sorted(e.name for e in SAMPLE))
    return arc


def run_tests() -> int:
    with TemporaryDirectory() as tmp:
        tmp = Path(tmp)

        print("基本往返（压缩索引 + 压缩段）")
        p = write_xp3(tmp / "a.xp3", SAMPLE)
        roundtrip("压缩", p)

        print("未压缩索引 + 未压缩段")
        p = write_xp3(tmp / "b.xp3", SAMPLE, compress_index=False, compress_segments=False)
        roundtrip("未压缩", p)

        print("多个 0x80 continue 标志")
        p = write_xp3(tmp / "c.xp3", SAMPLE, continue_flags=3)
        roundtrip("continue", p)

        print("索引里夹杂未知顶层 chunk")
        p = write_xp3(tmp / "d.xp3", SAMPLE, junk_top_chunk=True)
        roundtrip("跳过未知 chunk", p)

        print("info 名字多一个 NUL 终止符的变体")
        p = write_xp3(tmp / "e.xp3", SAMPLE, trailing_nul_name=True)
        roundtrip("NUL 变体", p)

        print("NUL 也算进字符数的变体（读取侧必须容忍）")
        p = write_xp3(tmp / "e2.xp3", SAMPLE, nul_in_count=True)
        roundtrip("NUL 计入", p)

        print("多段条目（必须按顺序拼接）")
        p = write_xp3(tmp / "e3.xp3", SAMPLE, multi_segment=4)
        arc = XP3Archive(p)
        check("多段：条目数不变", len(arc.entries) == len(SAMPLE))
        check("多段：至少有条目被切成多段",
              any(len(e.segments) > 1 for e in arc.entries),
              str([len(e.segments) for e in arc.entries]))
        for e in SAMPLE:
            check(f"多段：内容一致 {e.name}", arc.read(e.name) == e.data)

        print("内嵌在 exe 里（MZ 前缀，所有偏移加 base）")
        p = write_xp3(tmp / "e4.xp3", SAMPLE, mz_prefix=True)
        arc = XP3Archive(p)
        check("MZ：识别出基址", any("基址" in w for w in arc.warnings), str(arc.warnings))
        for e in SAMPLE:
            check(f"MZ：内容一致 {e.name}", arc.read(e.name) == e.data)

        print("旧式分裂索引（真偏移在 +9）")
        p = write_xp3(tmp / "e5.xp3", SAMPLE, split_index=True)
        roundtrip("分裂索引", p)

        print("krkrz 变体头（0x0B 是假值 0x17，真值在 0x20）")
        p = write_xp3(tmp / "e6.xp3", SAMPLE, krkrz_header=True)
        arc = XP3Archive(p)
        check("krkrz：认出了变体头", any("krkrz" in w for w in arc.warnings), str(arc.warnings))
        check("krkrz：内容一致", arc.read("script.vns") == SAMPLE[0].data)

        print("查找与容错")
        arc = XP3Archive(tmp / "a.xp3")
        check("大小写不敏感", arc.entry("BG/School.JPG") is not None)
        check("反斜杠归一化", arc.entry("bg\\school.jpg") is not None)
        check("查不到返回 None", arc.entry("nope.png") is None)
        check("空名字返回 None", arc.entry("") is None)
        check("省略扩展名能唯一命中", arc.entry("script") is not None)
        check("扩展名不符则不命中", arc.entry("script.png") is None)
        check("目录不符则不命中", arc.entry("other/school.jpg") is None)

        print("损坏样本")
        bad = tmp / "bad.xp3"
        bad.write_bytes(b"not an xp3 file at all")
        try:
            XP3Archive(bad)
            check("magic 不符要报错", False)
        except XP3Error:
            check("magic 不符要报错", True)

        truncated = tmp / "trunc.xp3"
        full = (tmp / "a.xp3").read_bytes()
        truncated.write_bytes(full[:len(full) // 2])
        try:
            XP3Archive(truncated)
            check("截断文件报错而不是崩", False, "竟然解析成功了")
        except XP3Error:
            check("截断文件报错而不是崩", True)

        print("受保护条目标记")
        p = write_xp3(tmp / "f.xp3", SAMPLE, encrypted_flag=True)
        arc = XP3Archive(p)
        check("识别 bit31 受保护", all(e.protected for e in arc.entries))
        try:
            arc.read("script.vns")
            check("受保护条目拒绝解密", False)
        except XP3Error:
            check("受保护条目拒绝解密", True)

        print("恶意样本：只能报错，不能崩也不能静默读出错数据")
        # 索引偏移是任意 u64
        p = write_xp3(tmp / "evil1.xp3", SAMPLE, hostile_index_offset=True)
        try:
            XP3Archive(p)
            check("索引偏移越界要报错", False, "竟然成功了")
        except XP3Error:
            check("索引偏移越界要报错", True)

        # 段偏移是任意 u64（索引本身仍然合法，所以能打开，但读取必须失败）
        p = write_xp3(tmp / "evil2.xp3", SAMPLE, hostile_segment_offset=True)
        arc = XP3Archive(p)
        try:
            arc.read("script.vns")
            check("段偏移越界读取要报错", False, "读出了数据")
        except XP3Error:
            check("段偏移越界读取要报错", True)

        # 文件名长度字段撒谎（u16 上限）
        p = write_xp3(tmp / "evil3.xp3", SAMPLE, hostile_name_length=True)
        try:
            XP3Archive(p)
            check("超长文件名要忽略条目", False, "竟然成功了")
        except XP3Error:
            check("超长文件名要忽略条目", True)

        # 谎报解压后大小：压缩段必须拒绝（读取侧会按这个数字预分配内存，不挡就是 DoS）
        p = write_xp3(tmp / "evil4.xp3", SAMPLE, hostile_segment_size=True)
        arc = XP3Archive(p)
        try:
            arc.read("bg/roof.jpg")            # 高压缩比样本，一定是压缩段
            check("压缩段谎报解压大小要报错", False, "竟然读出了数据")
        except XP3Error:
            check("压缩段谎报解压大小要报错", True)
        # 存储段谎报大小：内容按实际长度读是对的，只记录警告（空段直接跳过，不产生噪音）
        check("存储段谎报大小仍能读对", arc.read("script.vns") == SAMPLE[0].data)
        check("存储段谎报大小会产生警告", any("未压缩段声明大小与实际不符" in w for w in arc.warnings),
              str(arc.warnings))

    if FAILURES:
        print(f"\n{len(FAILURES)} 个断言失败：{FAILURES}")
        return 1
    print("\n全部断言通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(run_tests())
