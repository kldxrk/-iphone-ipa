#!/usr/bin/env python3
"""GameStore.detect 的等价移植 + 测试集。

为什么存在：detect() 决定"这个文件夹是目录游戏、封包游戏，还是两者并存"，一旦判断错，
症状是"游戏打不开"或"封包里的素材完全没被用上"，而这类问题靠肉眼审查很难发现——
我在写完之后就靠推理发现过两个真 bug（脚本在子目录时 root 指错、外部脚本会让封包被忽略）。

**必须与 GameStore.detect 保持逐行等价；改了 Swift 就要同步改这里。**
用法：python ref_game_detect.py
"""

from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).parent))
from xp3_toolkit import Entry, XP3Archive, _split_ext, write_xp3  # noqa: E402

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:  # pragma: no cover
    pass

SCRIPT = "@title 测试\n[角色] 台词\n@end"


@dataclass
class Detected:
    root: Path
    archive: Path | None
    script_path: str
    title: str | None
    warnings: list[str]


def _subdirs(folder: Path) -> list[Path]:
    return sorted([p for p in folder.iterdir() if p.is_dir() and not p.name.startswith(".")])


def _archives(directory: Path) -> list[Path]:
    items = [p for p in directory.iterdir() if p.suffix.lower() == ".xp3"]
    return sorted(items, key=lambda p: p.name)


def _title_in(source: str) -> str | None:
    for line in source.splitlines():
        t = line.strip(" \t")
        if t.lower().startswith("@title "):
            value = t[7:].strip(" \t")
            if value:
                return value
    return None


def _read_title(url: Path) -> str | None:
    try:
        data = url.read_bytes()
    except OSError:
        return None
    # Swift 侧用 ScriptText.decode（UTF-8 → GBK 兜底）；测试样本都是 UTF-8
    return _title_in(data.decode("utf-8", errors="replace"))


def _choose_script(archive: XP3Archive):
    exact = archive.entry("script.vns")
    if exact is not None:
        return exact
    candidates = sorted([e for e in archive.entries if e.name.lower().endswith(".vns")],
                        key=lambda e: (len(e.name), e.name))
    return candidates[0] if candidates else None


def _inventory(archive: XP3Archive) -> str:
    """与 GameStore.inventory 等价：按扩展名统计，让用户看出这是什么包。"""
    counts: dict[str, int] = {}
    for entry in archive.entries:
        name = entry.name.rsplit("/", 1)[-1]
        ext = _split_ext(name)[1]
        counts["无扩展名" if not ext else "." + ext] = counts.get("无扩展名" if not ext else "." + ext, 0) + 1
    top = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))[:6]
    listing = "、".join(f"{k}×{v}" for k, v in top)
    scripts = sum(1 for e in archive.entries if _split_ext(e.name.rsplit("/", 1)[-1])[1] in ("ks", "tjs"))
    if scripts:
        return listing + f"；其中 {scripts} 个 .ks/.tjs——看起来是原版 KiriKiri 脚本，需要 TJS2/KAG3 引擎才能执行"
    return listing


def detect(folder: Path) -> tuple[Detected | None, str | None]:
    subs = _subdirs(folder)

    script_directory = None
    for candidate in [folder] + subs:
        if (candidate / "script.vns").is_file():
            script_directory = candidate
            break

    archive_candidates: list[Path] = []
    if script_directory is not None:
        archive_candidates += _archives(script_directory)
    archive_candidates += _archives(folder)
    for sub in subs:
        archive_candidates += _archives(sub)
    seen = set()
    archive_url = None
    for candidate in archive_candidates:
        key = str(candidate.resolve())
        if key not in seen:
            seen.add(key)
            archive_url = candidate
            break

    if script_directory is None and archive_url is None:
        return (None, "没有 script.vns，也没有 .xp3 封包")

    root = script_directory or (archive_url.parent if archive_url else folder)

    if archive_url is None:
        return (Detected(root, None, "script.vns",
                         _read_title(root / "script.vns"), []), None)

    try:
        archive = XP3Archive(archive_url)
        warnings = list(archive.warnings)
        if script_directory is not None:
            entry = None
            title = _read_title(root / "script.vns")
        else:
            entry = _choose_script(archive)
            if entry is None:
                warnings.append("包内没有 .vns 脚本")
            title = _title_in(archive.read(entry.name).decode("utf-8", errors="replace")) if entry else None

        if entry is None and script_directory is None:
            return (None, f"{archive_url.name}：包内没有 .vns 脚本"
                         f"（{len(archive.entries)} 个文件：{_inventory(archive)}）")

        script_path = "script.vns" if script_directory is not None else (entry.name if entry else "script.vns")
        return (Detected(root, archive_url, script_path, title, warnings), None)
    except Exception as exc:                      # noqa: BLE001 —— 对应 Swift 的 catch
        if script_directory is not None:
            return (Detected(root, None, "script.vns", _read_title(root / "script.vns"),
                             [f"封包 {archive_url.name} 无法读取：{exc}"]), None)
        return (None, f"{archive_url.name}：{exc}")


# ---------------------------------------------------------------- 测试

FAILURES: list[str] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    if cond:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name} {detail}")
        FAILURES.append(name)


def make_archive(path: Path, script: str = SCRIPT, *, name: str = "script.vns") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    write_xp3(path, [Entry(name, script.encode("utf-8")),
                     Entry("bg/room.png", b"\x89PNG" + bytes(400))])


def make_archive_files(path: Path, files: dict[str, bytes]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    write_xp3(path, [Entry(n, d) for n, d in files.items()])


def run_tests() -> int:
    with TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        rel = lambda p: p.relative_to(tmp).as_posix() if p else None   # noqa: E731

        print("目录游戏")
        g = tmp / "g1"; g.mkdir()
        (g / "script.vns").write_text("@title 纯目录游戏\n@end", encoding="utf-8")
        game, reason = detect(g)
        check("只有 script.vns → 目录游戏", game and game.archive is None and rel(game.root) == "g1", reason)
        check("标题读到", game and game.title == "纯目录游戏")

        g = tmp / "g2"; (g / "S").mkdir(parents=True)
        (g / "S" / "script.vns").write_text("@title 脚本在子目录\n@end", encoding="utf-8")
        game, reason = detect(g)
        check("脚本在子目录 → root 指向子目录（曾经的 bug）",
              game and rel(game.root) == "g2/S", f"{rel(game.root) if game else reason}")
        check("子目录游戏标题读到", game and game.title == "脚本在子目录")

        print("封包游戏")
        g = tmp / "g3"; g.mkdir(); make_archive(g / "data.xp3", "@title 包内脚本\n@end")
        game, reason = detect(g)
        check("只有 data.xp3 → 封包游戏", game and rel(game.archive) == "g3/data.xp3", reason)
        check("scriptPath 取包内条目名", game and game.script_path == "script.vns")
        check("标题从包内脚本读出", game and game.title == "包内脚本")

        g = tmp / "g4"; (g / "sub").mkdir(parents=True); make_archive(g / "sub" / "data.xp3")
        game, reason = detect(g)
        check("封包在子目录 → root 指向该子目录", game and rel(game.root) == "g4/sub", reason)

        g = tmp / "g5"; g.mkdir()
        make_archive(g / "data.xp3", "@title 包内\n@end")
        (g / "script.vns").write_text("@title 外部覆盖\n@end", encoding="utf-8")
        game, reason = detect(g)
        check("外部脚本 + 封包 → 仍然挂载封包（曾经的 bug）",
              game and rel(game.archive) == "g5/data.xp3", f"{rel(game.archive) if game else reason}")
        check("外部脚本决定标题", game and game.title == "外部覆盖")
        check("外部脚本时 scriptPath 是文件夹里的", game and game.script_path == "script.vns")

        g = tmp / "g6"; (g / "S").mkdir(parents=True)
        (g / "S" / "script.vns").write_text("@title 子目录脚本\n@end", encoding="utf-8")
        make_archive(g / "data.xp3", "@title 包内\n@end")
        game, reason = detect(g)
        check("脚本在子目录 + 顶层封包 → 两者都用", game and rel(game.root) == "g6/S"
              and rel(game.archive) == "g6/data.xp3", reason)

        print("异常与边界")
        g = tmp / "g7"; g.mkdir(); make_archive(g / "data.xp3", "没有 title 也没有 vns 结尾", name="readme.txt")
        game, reason = detect(g)
        check("包内没有 .vns → 不识别并说明原因", game is None and "没有 .vns" in (reason or ""), str(reason))

        g = tmp / "g8"; g.mkdir()
        game, reason = detect(g)
        check("空文件夹 → 不识别", game is None and "没有 script.vns" in (reason or ""), str(reason))

        g = tmp / "g9"; g.mkdir()
        (g / "data.xp3").write_bytes(b"this is not an xp3 at all")
        (g / "script.vns").write_text("@title 封包坏了但有脚本\n@end", encoding="utf-8")
        game, reason = detect(g)
        check("坏封包 + 外部脚本 → 退化为目录游戏并记警告",
              game and game.archive is None and any("无法读取" in w for w in game.warnings), str(reason))

        g = tmp / "g10"; g.mkdir()
        (g / "data.xp3").write_bytes(b"broken")
        game, reason = detect(g)
        check("坏封包且没有脚本 → 不识别并报原因", game is None and "broken" not in (reason or ""), str(reason))

        g = tmp / "g11"; g.mkdir()
        make_archive(g / "a.xp3", "@title A\n@end")
        make_archive(g / "b.xp3", "@title B\n@end")
        game, reason = detect(g)
        check("多个封包取名字最小的", game and rel(game.archive) == "g11/a.xp3", reason)

        print("原版 KiriKiri 封包（这是用户最可能扔进来的东西）")
        g = tmp / "g12"; g.mkdir()
        make_archive_files(g / "data.xp3", {
            "first.ks": "[image storage=bg layer=base]\n测试[p]".encode("utf-8"),
            "scene/ch2.ks": "[jump target=*start]".encode("utf-8"),
            "startup.tjs": b"// KAG config",
            "bg/school.tlg": bytes(900),
            "bgm/theme.ogg": b"OggS" + bytes(300),
        })
        game, reason = detect(g)
        check("原版 KR 包不识别，但说明是原版脚本", game is None and "原版 KiriKiri" in (reason or ""), str(reason))
        check("统计出 .ks/.tjs 数量", "3 个 .ks/.tjs" in (reason or ""), str(reason))
        check("统计出主要扩展名", ".tlg×1" in (reason or "") and ".ogg×1" in (reason or ""), str(reason))

    if FAILURES:
        print(f"\n{len(FAILURES)} 个断言失败：{FAILURES}")
        return 1
    print("\n全部断言通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(run_tests())
