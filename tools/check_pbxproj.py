#!/usr/bin/env python3
"""VNPlayer.xcodeproj/project.pbxproj 结构自检。

在没有 Mac / Xcode 的环境里，手写 pbxproj 最容易犯的错误是：
  1. 新增的 .swift 只加到 PBXFileReference，忘了加进 PBXSourcesBuildPhase —— Xcode 不会报错，只是那个文件根本没被编译，运行时表现为莫名其妙的 "cannot find in scope"；
  2. ID 重复或长度不是 24 位十六进制 —— Xcode 直接打不开工程；
  3. 引用了不存在的对象 ID（悬空 fileRef / buildConfigurationList 等）。

本脚本以上述三类问题为检查目标，退出码非 0 表示有问题。
用法：python check_pbxproj.py <project.pbxproj 路径>
"""

from __future__ import annotations

import re
import sys
from collections import Counter
from pathlib import Path

# 控制台可能是 GBK，输出里带非 GBK 字符会直接抛 UnicodeEncodeError
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:  # pragma: no cover
    pass

ID_RE = re.compile(r"\b[0-9A-F]{24}\b")
# 形如 `\t\tA1...01 /* xxx */ = {isa = PBXBuildFile; ...` 的定义行
DEF_RE = re.compile(r"^[ \t]*([0-9A-F]{24})\s*(?:/\*.*?\*/)?\s*=\s*\{", re.M)
# 形如 `fileRef = B1...01 /* x */;` 的属性引用
ATTR_REF_RE = re.compile(r"(\w+)\s*=\s*([0-9A-F]{24})\b")
# 形如 `files = (A1...,A1...,);`
LIST_RE = re.compile(r"(\w+)\s*=\s*\((.*?)\);", re.S)
ISA_RE = re.compile(r"isa\s*=\s*(\w+)")

problems: list[str] = []
checked = 0          # 模块级：闭包里要用 global 才能改


def fail(msg: str) -> None:
    problems.append(msg)


def main(path: Path) -> int:
    text = path.read_text(encoding="utf-8")

    # ---- 1. 括号/花括号平衡（粗暴但能抓到结构性残缺） ----
    for open_ch, close_ch in (("{", "}"), ("(", ")")):
        if text.count(open_ch) != text.count(close_ch):
            fail(f"括号不平衡：{open_ch}={text.count(open_ch)} vs {close_ch}={text.count(close_ch)}")

    defines = DEF_RE.findall(text)
    # 文件的真实定义：{isa = X; 所在行
    isa_by_id: dict[str, str] = {}
    for line in text.splitlines():
        m = DEF_RE.match(line)
        if not m:
            continue
        isa = ISA_RE.search(line)
        isa_by_id.setdefault(m.group(1), isa.group(1) if isa else "?")

    dupes = [i for i, n in Counter(defines).items() if n > 1]
    for d in dupes:
        fail(f"ID 重复定义：{d}")

    # ---- 2. 所有引用的 ID 都必须有定义 ----
    defined = set(defines)
    for line in text.splitlines():
        for attr, ref in ATTR_REF_RE.findall(line):
            if attr in {"isa"}:
                continue
            if ref not in defined:
                fail(f"悬空引用：{attr} = {ref}（该 ID 没有定义）")
        for m in LIST_RE.finditer(line):
            attr, body = m.group(1), m.group(2)
            for ref in ID_RE.findall(body):
                if ref not in defined:
                    fail(f"悬空列表引用：{attr} 中的 {ref} 没有定义")

    # ---- 3. build phase 覆盖检查 ----
    build_files = {i: isa for i, isa in isa_by_id.items() if isa == "PBXBuildFile"}
    file_refs = {i: isa for i, isa in isa_by_id.items() if isa == "PBXFileReference"}
    phases = {i: isa for i, isa in isa_by_id.items() if isa == "PBXSourcesBuildPhase"}

    # PBXBuildFile -> fileRef
    build_to_fileref: dict[str, str] = {}
    for block in re.finditer(r"^\s*([0-9A-F]{24})\s*/\*.*?\*/\s*=\s*\{isa = PBXBuildFile;(.*?)\};", text, re.M):
        bid, body = block.group(1), block.group(2)
        m = re.search(r"fileRef\s*=\s*([0-9A-F]{24})", body)
        if not m:
            fail(f"PBXBuildFile {bid} 没有 fileRef")
            continue
        build_to_fileref[bid] = m.group(1)

    # Sources phase 里列的 build file
    in_sources: set[str] = set()
    for pid in phases:
        m = re.search(
            rf"^\s*{pid}\s*/\*.*?\*/\s*=\s*\{{isa = PBXSourcesBuildPhase;(.*?)\}};",
            text,
            re.M | re.S,
        )
        if not m:
            continue
        fm = re.search(r"files\s*=\s*\((.*?)\);", m.group(1), re.S)
        if fm:
            in_sources.update(ID_RE.findall(fm.group(1)))

    # 每个 .swift 文件引用都应出现在 Sources 阶段
    compiled_filerefs = {build_to_fileref[b] for b in in_sources if b in build_to_fileref}
    for fid, isa in file_refs.items():
        if isa != "PBXFileReference":
            continue
        m = re.search(
            rf"^\s*{fid}\s*/\*.*?\*/\s*=\s*\{{isa = PBXFileReference;(.*?)\}};", text, re.M | re.S
        )
        if not m:
            continue
        body = m.group(1)
        if "sourcecode.swift" not in body:
            continue
        name = re.search(r"path\s*=\s*([^;]+);", body)
        label = name.group(1).strip() if name else fid
        if fid not in compiled_filerefs:
            fail(f"Swift 文件未加入 PBXSourcesBuildPhase：{label}（{fid}）")

    # 进入 Sources 阶段的 build file 必须指向 swift 文件
    for b in in_sources:
        fid = build_to_fileref.get(b)
        if fid is None:
            fail(f"PBXSourcesBuildPhase 引用了不存在的 build file：{b}")

    # 资源文件夹引用（Demo / TestXP3 / Assets.xcassets）必须进入 Resources 阶段，
    # 否则 Xcode 不会报错，只是运行期 Bundle.main.url(forResource:) 找不到东西。
    in_resources: set[str] = set()
    resource_phases = {i for i, isa in isa_by_id.items() if isa == "PBXResourcesBuildPhase"}
    for pid in resource_phases:
        m = re.search(
            rf"^\s*{pid}\s*/\*.*?\*/\s*=\s*\{{isa = PBXResourcesBuildPhase;(.*?)\}};",
            text,
            re.M | re.S,
        )
        if not m:
            continue
        fm = re.search(r"files\s*=\s*\((.*?)\);", m.group(1), re.S)
        if fm:
            in_resources.update(ID_RE.findall(fm.group(1)))
    resource_filerefs = {build_to_fileref[b] for b in in_resources if b in build_to_fileref}

    for fid, isa in file_refs.items():
        if isa != "PBXFileReference":
            continue
        m = re.search(
            rf"^\s*{fid}\s*/\*.*?\*/\s*=\s*\{{isa = PBXFileReference;(.*?)\}};", text, re.M | re.S
        )
        if not m:
            continue
        body = m.group(1)
        if "lastKnownFileType = folder" not in body:
            continue
        name = re.search(r"path\s*=\s*([^;]+);", body)
        label = name.group(1).strip() if name else fid
        if fid not in resource_filerefs:
            fail(f"资源文件夹未加入 PBXResourcesBuildPhase：{label}（{fid}）")

    print(f"对象定义 {len(defined)} 个：{Counter(isa_by_id.values())}")
    print(f"Sources 阶段编译 {len(in_sources)} 个文件；Resources 阶段 {len(in_resources)} 个资源")

    # ---- 4. 引用到的文件是否真的在工程目录里 ----
    # 只验证结构是不够的：新加的文件若没被复制进仓库，Xcode 会报 "cannot find in scope"，
    # 而 pbxproj 本身完全合法。
    root = path.parent.parent
    groups: dict[str, tuple[str, list[str]]] = {}
    for gid, isa in isa_by_id.items():
        if isa != "PBXGroup":
            continue
        m = re.search(rf"^\s*{gid}\s*/\*.*?\*/\s*=\s*\{{isa = PBXGroup;(.*?)\}};", text, re.M | re.S)
        if not m:
            continue
        body = m.group(1)
        gpath = re.search(r"path\s*=\s*([^;]+);", body)
        children = re.search(r"children\s*=\s*\((.*?)\);", body, re.S)
        groups[gid] = (gpath.group(1).strip() if gpath else "",
                       ID_RE.findall(children.group(1)) if children else [])

    missing: list[str] = []

    def resolve(fid: str, prefix: str) -> None:
        global checked
        m = re.search(rf"^\s*{fid}\s*/\*.*?\*/\s*=\s*\{{isa = PBXFileReference;(.*?)\}};", text, re.M | re.S)
        if not m:
            return
        body = m.group(1)
        if "BUILT_PRODUCTS_DIR" in body:
            return
        name = re.search(r"path\s*=\s*([^;]+);", body)
        if not name:
            return
        relative = str(Path(prefix) / name.group(1).strip().strip('"')) if prefix else name.group(1).strip().strip('"')
        checked += 1
        if not (root / relative).exists():
            missing.append(relative)
        if fid in groups:
            child_prefix, child_ids = groups[fid]
            for child in child_ids:
                resolve(child, str(Path(relative) / child_prefix) if child_prefix else relative)

    for gid, (gpath, children) in groups.items():
        for child in children:
            resolve(child, gpath)

    for relative in missing:
        fail(f"pbxproj 引用了不存在的文件：{relative}（没被复制进仓库？）")
    print(f"检查了 {checked} 个文件引用，缺失 {len(missing)} 个")

    if problems:
        print("\n发现 %d 个问题：" % len(problems))
        for p in problems:
            print("  ✗", p)
        return 1
    print("\n✓ pbxproj 结构自检通过")
    return 0


if __name__ == "__main__":
    target = Path(sys.argv[1] if len(sys.argv) > 1 else "VNPlayer.xcodeproj/project.pbxproj")
    if not target.is_file():
        print(f"找不到文件：{target}")
        raise SystemExit(2)
    raise SystemExit(main(target))
