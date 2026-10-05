#!/usr/bin/env python3
"""CompatibilityAnalyzer 的等价移植 + 测试集。

为什么存在：这份报告要替用户回答"这个真实 KR 游戏该走哪条路线"，判定逻辑一旦写错，
用户就会朝错误的方向投入（比如明明有 800 处 TJS 却以为 KAG 子集能跑）。
真机无法编译，所以照样先在 Python 里把同一套逻辑跑通。

**必须与 Compatibility.swift 保持逐行等价；改了 Swift 就要同步改这里。**
用法：python ref_compat_report.py
"""

from __future__ import annotations

import sys
from dataclasses import dataclass, field
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:  # pragma: no cover
    pass

SCRIPT_EXTENSIONS = {"ks", "tjs", "vns", "asd", "txt"}
IMAGE_NEEDS_WORK = {"tlg", "pimg", "eri", "tft", "jxr"}
AUDIO_NEEDS_WORK = {"ogg", "oga", "opus", "mio"}
VIDEO_NEEDS_WORK = {"mpg", "mpeg", "wmv", "avi", "swf"}
# Windows 插件二进制：手机上（含任何引擎移植）只能靠静态 stub 替代
PLUGIN_BINARY_EXTENSIONS = {"dll", "tpm"}
PLUGIN_KEYWORD_LIST = ["loadplugin", "motionplayer", "live2d", "emote", "psbfile", "psdfile",
                       "kagparser", "layerex", "windowex", "drawdevice", "fstat", "xp3filter",
                       "savestruct", "csvparser", "textrender", "kirikiroid", "extrans", "alphamovie"]
MAX_SAMPLED_SCRIPTS = 24
MAX_BYTES_PER_SCRIPT = 512 * 1024

PLAYABLE, ROUTE_AB, ROUTE_A, ROUTE_C, BLOCKED = "playable", "routeAB", "routeA", "routeC", "blocked"

VERDICT_TITLE = {
    PLAYABLE: "结论：可以直接玩（当前版本已支持）",
    ROUTE_AB: "结论：可以做——路线 A（PC 转换器）与 B（App 内 KAG 解释器）都可行",
    ROUTE_A: "结论：只能走路线 A（PC 转换器），且含 TJS 的部分需要人工处理",
    ROUTE_C: "结论：需要引擎级方案（路线 C），转换器与 KAG 子集解释器都不够",
    BLOCKED: "结论：读不出内容——受保护封包，任何路线都无解",
}
VERDICT_LEVEL = {PLAYABLE: "info", ROUTE_AB: "info", ROUTE_A: "warning", ROUTE_C: "warning", BLOCKED: "error"}


@dataclass
class Item:
    name: str
    size: int
    protected: bool
    data: bytes | None            # 对应 Swift 里的 read() 闭包；None 表示读不到


@dataclass
class Report:
    file_name: str = ""
    entry_count: int = 0
    total_bytes: int = 0
    protected_count: int = 0
    extension_counts: dict[str, int] = field(default_factory=dict)
    script_names: list[str] = field(default_factory=list)
    sampled_scripts: int = 0
    plain_text_scripts: int = 0
    has_vns_script: bool = False
    exp_count: int = 0
    cond_count: int = 0
    expression_value_count: int = 0
    iscript_count: int = 0
    macro_count: int = 0
    embedded_count: int = 0
    verdict: str = ROUTE_C
    notes: list[str] = field(default_factory=list)
    plugin_binary_count: int = 0
    plugin_mentions: dict[str, int] = field(default_factory=dict)

    @property
    def tjs_constructs(self) -> int:
        return (self.exp_count + self.cond_count + self.expression_value_count
                + self.iscript_count + self.macro_count + self.embedded_count)

    def extension_summary(self) -> str | None:
        if not self.extension_counts:
            return None
        top = sorted(self.extension_counts.items(), key=lambda kv: (-kv[1], kv[0]))[:8]
        return "、".join(f"{k}×{v}" for k, v in top)

    def transcode_summary(self) -> str | None:
        wanted = IMAGE_NEEDS_WORK | AUDIO_NEEDS_WORK | VIDEO_NEEDS_WORK
        hits = {k: v for k, v in self.extension_counts.items() if k.lstrip(".") in wanted}
        if not hits:
            return None
        return "、".join(f"{k}×{v}" for k, v in sorted(hits.items(), key=lambda kv: -kv[1]))


def count(needle: bytes, haystack: bytes, limit: int = 100_000) -> int:
    """朴素非重叠计数，与 Swift 的 count(_:in:limit:) 等价（命中后跳过整个 needle）。"""
    if not needle or len(haystack) < len(needle):
        return 0
    found = 0
    last = len(haystack) - len(needle)
    i = 0
    while i <= last:
        if haystack[i] == needle[0]:
            if haystack[i:i + len(needle)] == needle:
                found += 1
                if found >= limit:
                    return found
                i += len(needle)
                continue
        i += 1
    return found


def looks_like_plain_kag(data: bytes) -> bool:
    """明文 KAG 判据用 ASCII 关键字，不依赖文本编码（日文脚本多为 Shift-JIS）。"""
    return any(count(m, data, limit=1) > 0 for m in
               (b"storage=", b"[image", b"[playbgm", b"[wait", b"[bg"))


def analyze(items: list[Item], file_name: str) -> Report:
    report = Report(file_name=file_name)
    report.entry_count = len(items)
    report.total_bytes = sum(max(0, i.size) for i in items)
    report.protected_count = sum(1 for i in items if i.protected)

    for item in items:
        ext = _ext(item.name)
        report.extension_counts["无扩展名" if not ext else "." + ext] = \
            report.extension_counts.get("无扩展名" if not ext else "." + ext, 0) + 1

    scripts = [i for i in items if _ext(i.name) in SCRIPT_EXTENSIONS]
    report.script_names = sorted(i.name for i in scripts)[:200]
    report.has_vns_script = any(_ext(i.name) == "vns" for i in scripts)

    for script in scripts[:MAX_SAMPLED_SCRIPTS]:
        if script.protected or script.data is None:
            continue
        report.sampled_scripts += 1
        data = script.data[:MAX_BYTES_PER_SCRIPT]
        # ASCII 小写化：|0x20 只对小写化 ASCII 有意义，我们只找 ASCII 关键字
        lowered = bytes(b | 0x20 for b in data)
        for keyword in PLUGIN_KEYWORD_LIST:
            hits = count(keyword.encode(), lowered)
            if hits:
                report.plugin_mentions[keyword] = report.plugin_mentions.get(keyword, 0) + hits
        if looks_like_plain_kag(data):
            report.plain_text_scripts += 1
            report.exp_count += count(b"exp=", data)
            report.cond_count += count(b"cond=", data)
            report.expression_value_count += count(b"=&", data)
            report.iscript_count += count(b"[iscript", data)
            report.macro_count += count(b"[macro", data)
            report.embedded_count += count(b"[eval", data) + count(b"[emb", data)

    if not report.has_vns_script and len(scripts) > report.sampled_scripts:
        report.notes.append(f"脚本共 {len(scripts)} 个，只抽检了前 {report.sampled_scripts} 个")

    report.plugin_binary_count = sum(1 for i in items if _ext(i.name) in PLUGIN_BINARY_EXTENSIONS)

    # 判定以"脚本能不能读"为准，而不是看受保护条目占比（理由见 Swift 侧注释）
    protected_scripts = sum(1 for i in scripts if i.protected)
    if report.has_vns_script:
        report.verdict = PLAYABLE
    elif scripts and protected_scripts == len(scripts):
        report.verdict = BLOCKED
    elif report.plain_text_scripts > 0:
        report.verdict = ROUTE_A if report.tjs_constructs > 0 else ROUTE_AB
    elif report.protected_count > 0:
        report.verdict = BLOCKED
    else:
        report.verdict = ROUTE_C
    return report


def _ext(name: str) -> str:
    base = name.rsplit("/", 1)[-1]
    idx = base.rfind(".")
    return "" if idx <= 0 else base[idx + 1:].lower()


# ---------------------------------------------------------------- 测试

FAILURES: list[str] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    if cond:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name} {detail}")
        FAILURES.append(name)


def kag(pairs: int = 0) -> bytes:
    body = "[image storage=bg/school layer=base]\n*start\nこれから始めます。[l]\n"
    for i in range(pairs):
        body += f'[if exp="f.flag=={i}"]\n[elsif cond=&f.other]\n[eval exp="f.x={i}"]\n[macro name=m{i}]\n[iscript]\n'
    return body.encode("cp932", errors="replace")


def run_tests() -> int:
    print("判定：五种结论")
    r = analyze([Item("script.vns", 100, False, b"@title demo\n@end")], "x")
    check("有 .vns → playable", r.verdict == PLAYABLE, r.verdict)

    r = analyze([Item("first.ks", 200, False, kag()), Item("bg/a.png", 10, False, b"x")], "x")
    check("明文 KAG 无 TJS → routeAB", r.verdict == ROUTE_AB, r.verdict)
    check("routeAB 标题正确", VERDICT_TITLE[r.verdict].startswith("结论：可以做"))

    r = analyze([Item("first.ks", 200, False, kag(pairs=2))], "x")
    check("明文 KAG 含 TJS → routeA", r.verdict == ROUTE_A, r.verdict)
    # kag(pairs=2) 每对里有 [if exp=] 与 [eval exp=] 两处 exp=，所以是 4
    check("统计到 exp=", r.exp_count == 4, str(r.exp_count))
    check("统计到 cond=", r.cond_count == 2, str(r.cond_count))
    check("统计到 =&", r.expression_value_count == 2, str(r.expression_value_count))
    check("统计到 [iscript]", r.iscript_count == 2, str(r.iscript_count))
    check("统计到宏", r.macro_count == 2, str(r.macro_count))
    check("统计到 [eval]", r.embedded_count == 2, str(r.embedded_count))
    check("TJS 合计 = 14", r.tjs_constructs == 14, str(r.tjs_constructs))

    r = analyze([Item("startup.tjs", 500, False, b"// KAG config\nvar x = 1;")], "x")
    check("只有 .tjs 且非 KAG → routeC", r.verdict == ROUTE_C, r.verdict)

    r = analyze([Item(f"data{i}", 10, True, None) for i in range(10)], "x")
    check("全部受保护 → blocked", r.verdict == BLOCKED, r.verdict)
    check("blocked 等级是错误", VERDICT_LEVEL[r.verdict] == "error")

    r = analyze([Item("a.tlg", 10, True, None), Item("b.png", 10, False, b"x"),
                 Item("c.ogg", 10, False, b"x")], "x")
    check("少数受保护 + 无明文脚本 → blocked", r.verdict == BLOCKED, r.verdict)

    r = analyze([Item("first.ks", 200, False, kag()), Item("a.png", 10, False, b"x"),
                 Item("b.png", 10, False, b"x"), Item("c.tlg", 10, True, None)], "x")
    check("少数受保护 + 明文脚本 → routeAB", r.verdict == ROUTE_AB, r.verdict)

    r = analyze([Item("first.ks", 200, True, kag()), Item("a.png", 10, False, b"x"),
                 Item("b.png", 10, False, b"x"), Item("c.png", 10, False, b"x")], "x")
    check("唯一脚本受保护（占比很小）→ blocked", r.verdict == BLOCKED, r.verdict)

    r = analyze([Item("first.ks", 200, False, kag()), Item("second.ks", 200, True, kag())], "x")
    check("脚本部分受保护、另有明文脚本 → 仍可做", r.verdict == ROUTE_AB, r.verdict)

    print("编码无关性（日文 KR 脚本常见 Shift-JIS）")
    sjis = "[image storage=bg layer=base]\nこんにちは[l]\n".encode("cp932")
    check("Shift-JIS 也算明文 KAG", looks_like_plain_kag(sjis))
    r = analyze([Item("first.ks", len(sjis), False, sjis)], "x")
    check("Shift-JIS 脚本判为 routeAB", r.verdict == ROUTE_AB, r.verdict)

    print("采样上限与受保护条目")
    many = [Item(f"s{i}.ks", 100, False, kag()) for i in range(30)]
    r = analyze(many, "x")
    check("只抽检 24 个", r.sampled_scripts == MAX_SAMPLED_SCRIPTS, str(r.sampled_scripts))
    check("产生抽样提示", any("只抽检" in n for n in r.notes), str(r.notes))

    mixed = [Item("locked.ks", 100, True, kag())] + [Item(f"s{i}.ks", 100, False, kag()) for i in range(3)]
    r = analyze(mixed, "x")
    check("受保护脚本不被读取", r.sampled_scripts == 3, str(r.sampled_scripts))
    check("plain 计数只含可读的", r.plain_text_scripts == 3, str(r.plain_text_scripts))

    print("素材统计")
    items = ([Item(f"cg{i}.tlg", 10, False, b"x") for i in range(7)]
             + [Item(f"bgm{i}.ogg", 10, False, b"x") for i in range(3)]
             + [Item("op.mpg", 10, False, b"x")]
             + [Item(f"bg{i}.png", 10, False, b"x") for i in range(5)])
    r = analyze(items, "x")
    check("受保护=0", r.protected_count == 0)
    check("扩展名统计排序正确", r.extension_summary().startswith(".tlg×7"), r.extension_summary())
    check("需要转码的素材被列出",
          all(s in (r.transcode_summary() or "") for s in (".tlg×7", ".ogg×3", ".mpg×1")),
          r.transcode_summary())
    check("总字节数累加", analyze([Item("a", 100, False, b"x"), Item("b", 250, False, b"x")], "x").total_bytes == 350)

    print("插件依赖探测（决定引擎级路线能不能跑）")
    script_with_plugins = (
        kag() + b'[loadplugin plugin/motionplayer.dll]\nPlugins.link("motionplayer.dll");\n'
        + b'[loadplugin plugin/Live2D.dll]\n'
    )
    items = [Item("first.ks", len(script_with_plugins), False, script_with_plugins),
             Item("plugin/motionplayer.dll", 4096, False, b"MZ"),
             Item("plugin/Live2D.dll", 8192, False, b"MZ"),
             Item("bg/a.png", 10, False, b"x")]
    r = analyze(items, "x")
    check("统计到插件二进制", r.plugin_binary_count == 2, str(r.plugin_binary_count))
    check("探测到 loadplugin", r.plugin_mentions.get("loadplugin") == 2, str(r.plugin_mentions))
    check("探测到 motionplayer", r.plugin_mentions.get("motionplayer") == 2, str(r.plugin_mentions))
    check("大小写不敏感（Live2D）", r.plugin_mentions.get("live2d") == 1, str(r.plugin_mentions))
    check("插件不影响文本路线的判定", r.verdict == ROUTE_AB, r.verdict)

    r = analyze([Item("first.ks", 100, False, kag()), Item("bg/a.png", 10, False, b"x")], "x")
    check("干净游戏：无插件二进制", r.plugin_binary_count == 0, str(r.plugin_binary_count))
    check("干净游戏：无插件关键字", r.plugin_mentions == {}, str(r.plugin_mentions))

    print("count 边界")
    check("空 needle", count(b"", b"abc") == 0)
    check("needle 比 haystack 长", count(b"abcd", b"abc") == 0)
    check("命中在开头", count(b"ab", b"abab") == 2)
    check("命中在结尾", count(b"bc", b"abc") == 1)
    check("单字节 needle", count(b"a", b"aaa") == 3)
    check("非重叠计数", count(b"aa", b"aaaa") == 2, str(count(b"aa", b"aaaa")))
    check("limit 生效", count(b"a", b"a" * 100, limit=5) == 5)

    if FAILURES:
        print(f"\n{len(FAILURES)} 个断言失败：{FAILURES}")
        return 1
    print("\n全部断言通过")
    return 0

if __name__ == "__main__":
    raise SystemExit(run_tests())
