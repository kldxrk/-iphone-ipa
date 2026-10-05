#!/usr/bin/env python3
"""生成内置的 XP3 自检游戏。

为什么需要它：开发环境没有 macOS，XP3 代码无法编译验证；而用户手上通常也没有现成的
KiriKiri 封包，于是"XP3 到底通没通"就没人能验证。这个脚本造一个**全部素材都在封包里**
的小游戏（脚本 + 两张背景 + 立绘 + WAV 音乐 + WAV 音效），随 App 一起打包成内置示例。

装上 App 后点「XP3 自检示例（内置）」即可验证整条链路：
    索引解析 → 段级 zlib 解压 → 按名查找素材（含子目录）→ 图片降采样 → 音频物化到缓存 → 播放

用法：python make_test_game.py <输出目录>
默认输出到 Resources/TestXP3/。
"""

from __future__ import annotations

import math
import struct
import sys
import wave
from pathlib import Path

sys.dont_write_bytecode = True          # 不要在源码目录里留下 __pycache__
sys.path.insert(0, str(Path(__file__).parent))
from xp3_toolkit import Entry, XP3Archive, write_xp3  # noqa: E402

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:  # pragma: no cover
    pass

import numpy as np                        # noqa: E402
from PIL import Image, ImageDraw          # noqa: E402

WIDTH, HEIGHT = 1280, 720

SCRIPT = """@title XP3 自检示例
# 这个游戏的全部素材（脚本、图片、音乐、音效）都装在 data.xp3 里，旁边没有任何散装文件。
@bgm bgm/theme.wav
@bg bg/room.png
如果你能看到这张渐变背景，说明封包索引解析和按名查找素材都通了。
@show alice char/alice.png center
[爱丽丝] 这一句来自封包内的 script.vns。
[爱丽丝] 接下来测试音效与选项分支。
@se se/click.wav
@choice 去天台看看=roof 直接结束=ending

@label roof
@bg bg/roof.png
@show alice char/alice.png left
背景换成了另一张封包内图片，立绘也移到了左边——说明 @bg / @show 都正常工作。
[爱丽丝] 如果刚才那声"嗒"是音效，说明封包里的 wav 被成功物化并播放了。
@jump ending

@label ending
@hide all
@bgm stop
——XP3 自检结束——
背景、立绘、音乐、音效、选项都对，就说明容器层是好的。\\n这不代表能运行原版 KiriKiri 游戏：那还需要 TJS2 脚本引擎。
@end
"""


def gradient(top: tuple[int, int, int], bottom: tuple[int, int, int]) -> bytes:
    """用 numpy 造竖直渐变，尺寸小、压缩率高。"""
    ramp = np.linspace(0.0, 1.0, HEIGHT, dtype=np.float32)[:, None]
    rows = np.zeros((HEIGHT, WIDTH, 3), dtype=np.uint8)
    for channel in range(3):
        rows[:, :, channel] = (top[channel] + (bottom[channel] - top[channel]) * ramp).astype(np.uint8)
    image = Image.fromarray(rows, "RGB")
    draw = ImageDraw.Draw(image)
    draw.rectangle([0, int(HEIGHT * 0.78), WIDTH, HEIGHT], fill=(28, 30, 40))
    buffer = _png_bytes(image)
    return buffer


def sprite() -> bytes:
    """一张带透明通道的简易立绘，用来验证 alpha 与缩放。"""
    image = Image.new("RGBA", (420, 860), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.ellipse([150, 40, 270, 160], fill=(255, 226, 205, 255))          # 头
    draw.polygon([(210, 150), (300, 430), (120, 430)], fill=(96, 138, 214, 255))  # 身体
    draw.rectangle([140, 430, 280, 840], fill=(60, 84, 140, 255))          # 裙/腿
    draw.ellipse([168, 88, 196, 116], fill=(40, 44, 60, 255))              # 眼
    draw.ellipse([224, 88, 252, 116], fill=(40, 44, 60, 255))
    draw.arc([180, 116, 240, 150], start=0, end=180, fill=(200, 90, 110, 255), width=4)
    return _png_bytes(image)


def _png_bytes(image: Image.Image) -> bytes:
    import io
    buffer = io.BytesIO()
    image.save(buffer, format="PNG", optimize=True)
    return buffer.getvalue()


def tone(seconds: float, freq: float, sample_rate: int = 22050, volume: float = 0.32,
         fade: bool = True) -> bytes:
    """一段正弦音，写成未压缩 16-bit 单声道 WAV —— AVFoundation 原生支持这种。"""
    import io
    count = int(seconds * sample_rate)
    frames = bytearray()
    for i in range(count):
        amplitude = volume
        if fade:
            # 首尾淡入淡出，避免爆音
            edge = min(i, count - i) / max(1, int(sample_rate * 0.02))
            amplitude *= min(1.0, edge)
        value = int(32767 * amplitude * math.sin(2 * math.pi * freq * i / sample_rate))
        frames += struct.pack("<h", max(-32768, min(32767, value)))
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(sample_rate)
        handle.writeframes(bytes(frames))
    return buffer.getvalue()


def main(out_dir: Path) -> int:
    out_dir.mkdir(parents=True, exist_ok=True)
    entries = [
        Entry("script.vns", SCRIPT.encode("utf-8")),
        Entry("bg/room.png", gradient((36, 48, 92), (208, 148, 96))),
        Entry("bg/roof.png", gradient((18, 24, 58), (232, 122, 84))),
        Entry("char/alice.png", sprite()),
        Entry("bgm/theme.wav", tone(2.0, 220.0, volume=0.22)),
        Entry("se/click.wav", tone(0.12, 900.0, volume=0.5)),
    ]
    target = out_dir / "data.xp3"
    write_xp3(target, entries, compress_index=True, compress_segments=True)

    # 立即读回来验证：生成器自己坏了就不该产出样本
    archive = XP3Archive(target)
    assert len(archive.entries) == len(entries), f"条目数不符：{len(archive.entries)}"
    for item in entries:
        got = archive.read(item.name)
        assert got == item.data, f"{item.name} 往返不一致"
    assert archive.warnings == [], f"生成时产生了警告：{archive.warnings}"

    print(f"已生成 {target}（{target.stat().st_size} 字节，{len(entries)} 个文件）")
    for item in entries:
        print(f"  {item.name:24s} {len(item.data):>8d} 字节")
    print("往返读取验证通过")
    return 0


if __name__ == "__main__":
    destination = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("Resources/TestXP3")
    raise SystemExit(main(destination))
