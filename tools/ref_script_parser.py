#!/usr/bin/env python3
"""ScriptParser.swift 的等价移植 + 测试集。

为什么存在：开发环境没有 macOS / Xcode，Swift 代码无法编译验证。
把解析逻辑逐行移植到 Python 后，至少可以验证"算法本身"是对的——
尤其是编码探测、警告去重与计数、行号对齐这些靠肉眼审查极难发现问题的部分。

**这里必须与 ScriptParser.swift 保持逐行等价；改了 Swift 就要同步改这里。**
用法：python ref_script_parser.py
"""

from __future__ import annotations

import sys
from dataclasses import dataclass, field

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:  # pragma: no cover
    pass


# ---------------------------------------------------------------- 文本解码

def strip_bom(s: str | None) -> str | None:
    if s is None:
        return None
    return s[1:] if s.startswith("\ufeff") else s


def plausible_text(s: str) -> bool:
    """解出来的文本不能含 NUL、也不能含除制表/换行以外的控制字符。"""
    for ch in s[:4096]:
        if ch == "\u0000":
            return False
        if ord(ch) < 0x20 and ch not in "\t\n\r":
            return False
    return True


def text_score(s: str) -> int:
    score = 0
    for ch in s[:512]:
        if ch == "\u0000":
            score -= 10
        elif ch in "\n\r\t":
            score += 1
        elif ord(ch) < 0x20:
            score -= 5
        else:
            score += 1
    return score


def _decode(data: bytes, encoding: str) -> str | None:
    try:
        return data.decode(encoding)
    except (UnicodeDecodeError, LookupError):
        return None


def decode_script(data: bytes) -> str | None:
    """判据刻意保持简单：只有**原始字节里出现 0x00** 才考虑 UTF-16。

    GBK 与 UTF-8 文本不会包含 0x00，而无 BOM 的 UTF-16 只要有换行或 @tag 就必然出现 0x00。
    反过来若靠"UTF-16 解得干净"来判断，GBK 的中文字节恰好也能解成合法汉字，会误判。
    """
    if len(data) >= 2:
        if data[0] == 0xFF and data[1] == 0xFE:
            return strip_bom(_decode(data, "utf-16-le"))
        if data[0] == 0xFE and data[1] == 0xFF:
            return strip_bom(_decode(data, "utf-16-be"))
        if len(data) >= 3 and data[0] == 0xEF and data[1] == 0xBB and data[2] == 0xBF:
            return strip_bom(_decode(data, "utf-8"))

    if len(data) % 2 == 0 and 0 in data:
        candidates = [s for s in (_decode(data, "utf-16-le"), _decode(data, "utf-16-be"))
                      if s is not None and plausible_text(s)]
        if candidates:
            return strip_bom(max(candidates, key=text_score))

    utf8 = _decode(data, "utf-8")
    if utf8 is not None and "\u0000" not in utf8:
        return strip_bom(utf8)

    return strip_bom(_decode(data, "gb18030"))


# ---------------------------------------------------------------- 脚本解析

@dataclass
class Script:
    title: str | None = None
    commands: list = field(default_factory=list)
    labels: dict = field(default_factory=dict)
    warnings: list = field(default_factory=list)
    origin: str = "script.vns"


class ScriptError(Exception):
    pass


def tokenize(s: str) -> list[str]:
    tokens: list[str] = []
    current = ""
    in_quote = False
    has_token = False
    for ch in s:
        if ch == '"':
            in_quote = not in_quote
            has_token = True
            continue
        if ch in " \t" and not in_quote:
            if has_token:
                tokens.append(current)
                current = ""
                has_token = False
            continue
        current += ch
        has_token = True
    if has_token:
        tokens.append(current)
    return tokens


def _trim(line: str) -> str:
    # Swift 的 .whitespaces 不含换行；这里近似为空格/制表/全角空格/不换行空格
    return line.strip(" \t\u3000\u00a0")


def _unescape(s: str) -> str:
    return s.replace("\\n", "\n")


MAX_MESSAGES = 200


def parse(source: str, origin: str = "script.vns") -> Script:
    script = Script()
    commands = script.commands
    labels = script.labels
    cmd_lines: list[int] = []
    parse_line = 0

    # 警告按"消息"去重并计数：一份从 KR 转来的脚本可能有几百行同样的未知指令
    message_order: list[str] = []
    message_first_line: dict[str, int] = {}
    message_count: dict[str, int] = {}

    def warn(line: int, message: str) -> None:
        if message in message_count:
            message_count[message] += 1
            return
        if len(message_order) >= MAX_MESSAGES:
            return
        message_order.append(message)
        message_first_line[message] = line
        message_count[message] = 1

    def emit(cmd) -> None:
        commands.append(cmd)
        cmd_lines.append(parse_line)

    text = source
    if text.startswith("\ufeff"):
        text = text[1:]
    text = text.replace("\r\n", "\n").replace("\r", "\n")

    line_no = 0
    for raw_line in text.split("\n"):
        line_no += 1
        parse_line = line_no
        line = _trim(raw_line)
        if not line or line.startswith("#") or line.startswith("//"):
            continue

        if line.startswith("@"):
            tokens = tokenize(line[1:])
            if not tokens:
                continue
            name = tokens[0].lower()
            args = tokens[1:]

            def arg(i: int, what: str):
                if i >= len(args) or not args[i]:
                    warn(line_no, f"@{name} 缺少{what}，已跳过")
                    return None
                return args[i]

            if name == "title":
                script.title = " ".join(args)
            elif name == "label":
                l = arg(0, "名称")
                if l is None:
                    continue
                if l in labels:
                    warn(line_no, f"标签 {l} 重复定义")
                labels[l] = len(commands)
                emit(("label", l))
            elif name == "bg":
                if (f := arg(0, "图片文件名")) is not None:
                    emit(("bg", f))
            elif name == "bgm":
                if (f := arg(0, "音乐文件名（或 stop）")) is not None:
                    emit(("bgm", None if f.lower() == "stop" else f))
            elif name == "se":
                if (f := arg(0, "音效文件名")) is not None:
                    emit(("se", f))
            elif name == "show":
                ident = arg(0, "角色标识")
                file = arg(1, "图片文件名")
                if ident is not None and file is not None:
                    pos = args[2] if len(args) > 2 else "center"
                    emit(("show", ident, file, pos))
            elif name == "hide":
                if (i := arg(0, "角色标识（或 all）")) is not None:
                    emit(("hide", i))
            elif name == "jump":
                if (l := arg(0, "标签名")) is not None:
                    emit(("jump", l))
            elif name == "choice":
                items = []
                for a in args:
                    eq = a.rfind("=")
                    if eq < 0 or not a[:eq] or not a[eq + 1:]:
                        warn(line_no, "选项不是 文字=标签 的写法，已跳过该选项")
                        continue
                    items.append((a[:eq], a[eq + 1:]))
                if not items:
                    warn(line_no, "@choice 没有任何有效选项，已跳过")
                else:
                    emit(("choice", items))
            elif name == "end":
                emit(("end",))
            else:
                warn(line_no, f"未知指令 @{name}，已跳过")
        elif line.startswith("[") and "]" in line:
            close = line.index("]")
            who = line[1:close].strip(" \t")
            body = line[close + 1:].strip(" \t")
            emit(("say", who or None, _unescape(body)))
        else:
            emit(("say", None, _unescape(line)))

    for index, cmd in enumerate(commands):
        line = cmd_lines[index] if index < len(cmd_lines) else index + 1
        if cmd[0] == "jump" and cmd[1] not in labels:
            warn(line, f"跳转目标 {cmd[1]} 不存在")
        elif cmd[0] == "choice":
            for text, target in cmd[1]:
                if target not in labels:
                    warn(line, f"选项「{text}」的目标 {target} 不存在")

    if not commands:
        raise ScriptError("脚本里没有可执行内容（检查编码或文件是否选错）")

    script.warnings = [
        f"第 {message_first_line[m]} 行：{m}" + (f"（同类 {message_count[m]} 处）" if message_count[m] > 1 else "")
        for m in message_order
    ]
    script.origin = origin
    return script


# ---------------------------------------------------------------- 测试

FAILURES: list[str] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    if cond:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name} {detail}")
        FAILURES.append(name)


def run_tests() -> int:
    print("编码探测")
    src = "@title 示例\n[爱丽丝] 你好？"
    check("UTF-8 BOM 去掉", decode_script(src.encode("utf-8-sig")) == src)
    check("UTF-16LE BOM", decode_script(("\ufeff" + src).encode("utf-16-le")) == src)
    check("UTF-16BE BOM", decode_script(("\ufeff" + src).encode("utf-16-be")) == src)
    check("无 BOM 的 UTF-16LE 也能认（有换行 → 有 0x00）",
          decode_script(src.encode("utf-16-le")) == src)
    gbk = "@title 示例游戏：放学后\n[爱丽丝] 咦，你还没回去吗？".encode("gb18030")
    check("GB18030 兜底（GBK 字节里没有 0x00）", decode_script(gbk).startswith("@title 示例游戏"))
    check("纯 ASCII 不当成 UTF-16", decode_script(b"@title hello\nworld") == "@title hello\nworld")
    check("UTF-16LE 的字节里确实有 0x00", 0 in src.encode("utf-16-le"))
    check("GBK 的字节里没有 0x00", 0 not in gbk)

    print("解析：正常脚本")
    source = "\n".join([
        "@title 测试：标题",                    # 1
        "# 注释",                               # 2
        "@bg bg/school.jpg",                    # 3
        "[爱丽丝] 你好\\n第二行",                # 4
        "@show alice c.png left",               # 5
        '@choice "选项 A"=roof 别的=home',       # 6
        "@label roof",                          # 7
        "@jump ending",                         # 8
        "@label home",                          # 9
        "@label ending",                        # 10
        "旁白",                                  # 11
        "@end",                                 # 12
    ])
    s = parse(source)
    check("无警告", s.warnings == [], str(s.warnings))
    check("标题", s.title == "测试：标题")
    check("换行转义", ("say", "爱丽丝", "你好\n第二行") in s.commands)
    # 命令序列：bg(0) say(1) show(2) choice(3) label/jump/label/label(4..7) say(8) end(9)
    check("引号内空格成单 token", s.commands[3][1] == [("选项 A", "roof"), ("别的", "home")],
          str(s.commands[3]))
    check("立绘位置", ("show", "alice", "c.png", "left") in s.commands)

    print("解析：容错")
    s2 = parse("\n".join([
        "@bogus x",              # 1 未知指令
        "@bg",                   # 2 缺参数
        "@choice 没有等号",       # 3 选项无效
        "有效对白",               # 4
        "@end",                  # 5
    ]))
    check("未知指令只警告", any("未知指令 @bogus" in w for w in s2.warnings), str(s2.warnings))
    check("未知指令行号=1", s2.warnings[0].startswith("第 1 行"), s2.warnings[0])
    check("缺参数行号=2", any(w.startswith("第 2 行：@bg 缺少") for w in s2.warnings))
    check("无效选项行号=3", any(w.startswith("第 3 行：@choice 没有任何有效选项") for w in s2.warnings))
    check("跳过坏行后脚本仍可用", ("say", None, "有效对白") in s2.commands)

    s3 = parse("\n".join([
        "@label dup",   # 1
        "@label dup",   # 2
        "@jump nowhere",# 3
        "@choice 去=ghost",  # 4
        "@end",         # 5
    ]))
    check("重复标签警告行号=2", any(w.startswith("第 2 行：标签 dup 重复定义") for w in s3.warnings), str(s3.warnings))
    check("悬空跳转行号=3", any(w.startswith("第 3 行：跳转目标 nowhere 不存在") for w in s3.warnings), str(s3.warnings))
    check("悬空选项行号=4", any(w.startswith("第 4 行：选项「去」") for w in s3.warnings), str(s3.warnings))

    s4 = parse("@bogus\n@bogus\n有效")
    bogus = [w for w in s4.warnings if "bogus" in w]
    check("同类警告去重并计数", len(bogus) == 1 and "同类 2 处" in bogus[0], str(s4.warnings))

    print("解析：边界")
    try:
        parse("# 只有注释\n\n")
        check("空脚本报错", False)
    except ScriptError:
        check("空脚本报错", True)

    s5 = parse("@bgm stop\n@bgm a.mp3")
    check("bgm stop → None", s5.commands[0] == ("bgm", None) and s5.commands[1] == ("bgm", "a.mp3"))

    s6 = parse('@choice "含 = 号"=x')
    check("选项文字里的 = 不误切", s6.commands[0][1] == [("含 = 号", "x")], str(s6.commands[0]))

    s7 = parse("[  ] 空名字")
    check("空角色名当旁白", s7.commands[0] == ("say", None, "空名字"), str(s7.commands[0]))

    if FAILURES:
        print(f"\n{len(FAILURES)} 个断言失败：{FAILURES}")
        return 1
    print("\n全部断言通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(run_tests())
