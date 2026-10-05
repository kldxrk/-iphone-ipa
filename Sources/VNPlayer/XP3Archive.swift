import Foundation
import Compression

/// KiriKiri 的 XP3 归档读取器。
///
/// 只做「容器」：解析索引、按需取出单个文件。不解密、不执行 TJS。
///
/// 格式要点（多来源交叉验证，写下来免得以后改坏）：
///  * magic 11 字节：`58 50 33 0D 0A 20 0A 1A 8B 67 01`
///  * 偏移 0x0B 是 u64 LE 的索引绝对偏移；krkrz 变体把真值放在 0x20，0x0B 填假值 0x17
///  * 索引块首字节是 flag：`0x80` = XP3_INDEX_CONTINUE（**不是压缩位**，可能出现多个，必须循环跳过），
///    `0x00` = 后面跟 u64 长度 + 裸索引，`0x01` = 后面跟 u64 压缩长度 + u64 原始长度 + zlib 流
///  * 索引内部是一串 chunk：`tag(4 ASCII) + size(u64，不含自身 12 字节) + body`
///  * `File` 条目内部又是子 chunk（顺序不保证）：`info` + `segm` + `adlr` [+ `time`]
///      - `info`：flags(u32，**bit31 = 0x80000000 表示受保护**）、原始大小(u64)、归档大小(u64)、
///        名字字符数(u16)、UTF-16LE 名字
///      - `segm`：N 条 28 字节记录 = 压缩标志(u32，**1 表示 zlib 压缩**)、绝对偏移(u64)、
///        原始大小(u64)、归档大小(u64)
///      - `adlr`：整个文件明文的 adler32(u32)
///  * 段数据是 **zlib 包装**（RFC1950），不是 raw deflate；压缩标志与加密位是两回事
final class XP3Archive {
    struct Segment {
        let compressed: Bool
        let offset: UInt64
        let originalSize: Int
        let archivedSize: Int
    }

    struct Entry {
        let name: String
        let originalSize: Int
        let archivedSize: Int
        let isProtected: Bool
        let adler32: UInt32?
        let segments: [Segment]
    }

    let url: URL
    private(set) var entries: [Entry] = []
    /// 解析过程中发现的非致命问题（畸形 chunk、变体头等），交给诊断面板展示。
    private(set) var warnings: [String] = []

    private var handle: FileHandle?
    private let base: UInt64
    /// 归档文件的字节数；XP3Source 用它拼稳定的缓存键。
    let fileSize: UInt64
    private var byName: [String: Entry] = [:]

    /// 内嵌在 exe 里的归档需要整文件扫描，设一个上限避免在手机上把内存吃光。
    private static let embeddedScanLimit = 256 * 1024 * 1024

    init(url: URL) throws {
        self.url = url
        guard let file = try? FileHandle(forReadingFrom: url) else {
            throw VNRuntimeError.archiveDamaged("无法打开文件")
        }
        self.handle = file

        let size = (try? file.seekToEnd()) ?? 0
        self.fileSize = size
        try file.seek(toOffset: 0)
        let head = (try? file.read(upToCount: 19)) ?? Data()
        guard head.count >= 19 else { throw VNRuntimeError.archiveDamaged("文件太小") }

        let bytes = [UInt8](head)
        var resolvedBase: UInt64 = 0
        var startupWarnings: [String] = []

        if !XP3Archive.hasMagic(bytes, at: 0) {
            if bytes.count >= 2, bytes[0] == 0x4D, bytes[1] == 0x5A {   // "MZ"
                guard size <= UInt64(XP3Archive.embeddedScanLimit) else {
                    throw VNRuntimeError.archiveDamaged("归档内嵌在可执行文件中且体积过大，请先单独取出 .xp3")
                }
                try file.seek(toOffset: 0)
                let whole = (try? file.readToEnd()) ?? Data()
                // 直接在 Data 上搜索，不要先转成 [UInt8] —— 上限 256MB 的文件会被完整复制一遍
                let magic = Data([0x58, 0x50, 0x33, 0x0D, 0x0A, 0x20, 0x0A, 0x1A, 0x8B, 0x67, 0x01])
                guard let range = whole.range(of: magic) else {
                    throw VNRuntimeError.archiveDamaged("可执行文件里找不到 XP3 数据")
                }
                let found = range.lowerBound
                resolvedBase = UInt64(found)
                startupWarnings.append("归档内嵌在可执行文件中，基址 0x\(String(found, radix: 16))")
            } else {
                throw VNRuntimeError.archiveDamaged("magic 不匹配，不是 XP3 文件")
            }
        }
        // 类的所有存储属性必须先初始化完，之后才能再改 self 的其它内容
        self.base = resolvedBase
        self.warnings = startupWarnings

        let indexOffset = try XP3Archive.readIndexOffset(handle: file, base: resolvedBase, fileSize: size)
        let index = try XP3Archive.readIndex(handle: file, offset: indexOffset, base: resolvedBase, fileSize: size)
        try parseIndex(index)
    }

    deinit {
        try? handle?.close()
    }

    // MARK: - 查询

    var count: Int { entries.count }
    var entryNames: [String] { entries.map(\.name) }

    func listFiles() -> [String] { entryNames.sorted() }

    /// 查找条目。先做归一化精确匹配（大小写不敏感、`\` 统一成 `/`），
    /// 再退一步做「去掉扩展名后唯一匹配」——KAG 的 `storage` 常常不写扩展名。
    ///
    /// 回退必须同时约束**目录**与**扩展名**：否则 `bgm/theme` 可能命中 `voice/theme.ogg`
    /// 这种毫不相干的文件，而 `bgm/theme.ogg` 可能命中 `theme.mp3`。
    /// 还有一点很重要：只有唯一命中时才认，宁可不给也不要给错。
    func entry(named name: String) -> Entry? {
        let key = XP3Archive.normalize(name)
        if key.isEmpty { return nil }
        if let hit = byName[key] { return hit }

        let wanted = key as NSString
        let wantedBase = wanted.lastPathComponent as NSString
        let wantedStem = wantedBase.deletingPathExtension
        let wantedExtension = wantedBase.pathExtension
        let wantedDirectory = wanted.deletingLastPathComponent

        let matches = entries.filter { entry in
            let candidate = XP3Archive.normalize(entry.name) as NSString
            let base = candidate.lastPathComponent as NSString
            guard base.deletingPathExtension == wantedStem else { return false }
            if !wantedExtension.isEmpty, base.pathExtension != wantedExtension { return false }
            if !wantedDirectory.isEmpty, candidate.deletingLastPathComponent != wantedDirectory { return false }
            return true
        }
        return matches.count == 1 ? matches[0] : nil
    }

    func data(named name: String) throws -> Data {
        guard let e = entry(named: name) else {
            throw VNRuntimeError.archiveDamaged("归档里没有 \(name)")
        }
        return try data(for: e)
    }

    func data(for entry: Entry) throws -> Data {
        if entry.isProtected {
            throw VNRuntimeError.unsupportedArchive
        }
        guard let file = handle else { throw VNRuntimeError.archiveDamaged("归档已关闭") }
        var output: [UInt8] = []
        // 不要按声明的大小一次性预留：这个数字来自文件内容，可能被谎报成 Int.max
        output.reserveCapacity(min(entry.originalSize, 64 * 1024 * 1024))
        for segment in entry.segments {
            // 合法的空文件/空段：不要走读取路径（read(upToCount: 0) 的返回值语义不值得依赖）
            if segment.archivedSize == 0 { continue }
            // 偏移来自文件内容，可能是任意 u64：必须用溢出安全的加法，
            // 否则 base + offset 这种表达式在恶意/损坏归档上会直接触发运行时陷阱。
            let (start, startOverflow) = base.addingReportingOverflow(segment.offset)
            guard segment.archivedSize >= 0 else {
                throw VNRuntimeError.archiveDamaged("\(entry.name) 的段长度非法")
            }
            let (end, endOverflow) = start.addingReportingOverflow(UInt64(segment.archivedSize))
            guard !startOverflow, !endOverflow, end <= fileSize else {
                throw VNRuntimeError.archiveDamaged("\(entry.name) 的段越界")
            }
            // 关键：预分配发生在解压之前，所以"声明的大小"必须先用条目自己的总大小夹住，
            // 并且累计不能超过它。否则几百 KB 的压缩数据就能逼 App 申请几百 MB（jetsam 直接杀进程）。
            if entry.originalSize > 0 {
                let (projected, projectedOverflow) = output.count.addingReportingOverflow(segment.originalSize)
                guard !projectedOverflow,
                      segment.originalSize <= entry.originalSize,
                      projected <= entry.originalSize else {
                    throw VNRuntimeError.archiveDamaged("\(entry.name) 的段大小超过条目声明的大小")
                }
            }
            try file.seek(toOffset: start)
            guard let chunk = try file.read(upToCount: segment.archivedSize), chunk.count == segment.archivedSize else {
                throw VNRuntimeError.archiveDamaged("\(entry.name) 数据读取不完整")
            }
            if segment.compressed {
                output += try XP3Archive.inflate([UInt8](chunk), expectedSize: segment.originalSize)
            } else {
                if segment.originalSize != segment.archivedSize {
                    warnings.append("\(entry.name) 的未压缩段声明大小与实际不符（\(segment.originalSize) vs \(segment.archivedSize)），按实际长度读取")
                }
                output += [UInt8](chunk)
            }
        }
        if entry.originalSize > 0 {
            guard output.count == entry.originalSize else {
                throw VNRuntimeError.archiveDamaged("\(entry.name) 大小不符：期望 \(entry.originalSize)，实际 \(output.count)")
            }
        } else if !output.isEmpty {
            warnings.append("\(entry.name) 未声明大小，读出了 \(output.count) 字节")
        }
        if let expected = entry.adler32, !output.isEmpty, output.count <= 8 * 1024 * 1024,
           XP3Archive.adler32(output) != expected {
            // adler 不符只记警告：某些加密封包的文件名/大小是对的，校验值故意对不上
            warnings.append("\(entry.name) 的 adler32 校验不符（数据可能被改过）")
        }
        return Data(output)
    }

    // MARK: - 头部与索引

    private static func hasMagic(_ bytes: [UInt8], at offset: Int) -> Bool {
        let magic: [UInt8] = [0x58, 0x50, 0x33, 0x0D, 0x0A, 0x20, 0x0A, 0x1A, 0x8B, 0x67, 0x01]
        guard offset >= 0, offset + magic.count <= bytes.count else { return false }
        return Array(bytes[offset..<(offset + magic.count)]) == magic
    }

    /// 用已验证的游标读 u64（LE），避免依赖 UnsafeRawBufferPointer 的对齐细节。
    private static func littleEndianU64(_ data: Data) -> UInt64? {
        guard data.count == 8 else { return nil }
        var cursor = ByteCursor([UInt8](data))
        return try? cursor.u64()
    }

    private static func readIndexOffset(handle: FileHandle, base: UInt64, fileSize: UInt64) throws -> UInt64 {
        try handle.seek(toOffset: base + 11)
        guard let raw = try handle.read(upToCount: 8), let value = littleEndianU64(raw) else {
            throw VNRuntimeError.archiveDamaged("读不到索引偏移")
        }
        // 内嵌在 exe 里的归档，文件内记录的偏移是相对归档起点的：必须统一加上 base。
        // 段偏移那边也加了 base，两边约定必须一致，否则索引和素材会读到完全不同的位置。
        func resolved(_ candidate: UInt64) -> UInt64? {
            let (sum, overflow) = candidate.addingReportingOverflow(base)
            guard !overflow, sum > 0, sum < fileSize else { return nil }
            return sum
        }
        // krkrz 变体：0x0B 处是假值 0x17，真值在 0x20
        if value == 0x17, fileSize >= 0x28 {
            try handle.seek(toOffset: base + 0x20)
            if let alt = try handle.read(upToCount: 8), let candidate = littleEndianU64(alt), candidate > 0,
               let target = resolved(candidate) {
                return target
            }
        }
        guard let target = resolved(value) else {
            throw VNRuntimeError.archiveDamaged("索引偏移越界（\(value)）")
        }
        return target
    }

    private static func readIndex(handle: FileHandle, offset: UInt64, base: UInt64, fileSize: UInt64) throws -> [UInt8] {
        do {
            return try readIndexBlock(handle: handle, offset: offset, base: base, fileSize: fileSize)
        } catch {
            // 旧式「分裂索引」：该处 4 字节恰好是 u32 0x80，**真索引偏移在这个位置 +9 处**。
            // 必须严格限定条件并逐项做边界检查，否则被截断的普通归档会在这里越界读取崩溃。
            guard offset <= fileSize, fileSize - offset >= 17 else { throw error }
            try handle.seek(toOffset: offset)
            guard let probe = try handle.read(upToCount: 4), probe.count == 4 else { throw error }
            var probeCursor = ByteCursor([UInt8](probe))
            guard (try? probeCursor.u32()) == 0x80 else { throw error }
            try handle.seek(toOffset: offset + 9)          // 不是 +4：探针之后还有 5 字节才到指针
            guard let ptr = try handle.read(upToCount: 8), let raw = littleEndianU64(ptr) else { throw error }
            let (resolved, overflow) = raw.addingReportingOverflow(base)
            guard !overflow, resolved > 0, resolved < fileSize else { throw error }
            return try readIndexBlock(handle: handle, offset: resolved, base: base, fileSize: fileSize)
        }
    }

    private static func readIndexBlock(handle: FileHandle, offset: UInt64, base: UInt64, fileSize: UInt64) throws -> [UInt8] {
        guard offset > 0, offset < fileSize else {
            throw VNRuntimeError.archiveDamaged("索引偏移越界（\(offset)）")
        }
        try handle.seek(toOffset: offset)
        guard let first = try handle.read(upToCount: 1), let flag0 = first.first else {
            throw VNRuntimeError.archiveDamaged("读不到索引标志")
        }
        var flag = flag0
        var guardCount = 0
        while flag == 0x80 {
            guardCount += 1
            guard guardCount < 64 else { throw VNRuntimeError.archiveDamaged("索引 continue 标志异常多") }
            guard let next = try handle.read(upToCount: 1), let value = next.first else {
                throw VNRuntimeError.archiveDamaged("索引标志读取中断")
            }
            flag = value
        }

        func readU64() throws -> UInt64 {
            guard let raw = try handle.read(upToCount: 8), let value = littleEndianU64(raw) else {
                throw VNRuntimeError.archiveDamaged("索引字段读取中断")
            }
            return value
        }

        switch flag {
        case 0:
            let size = try readU64()
            guard size <= fileSize else { throw VNRuntimeError.archiveDamaged("索引长度越界") }
            guard let raw = try handle.read(upToCount: Int(size)), raw.count == Int(size) else {
                throw VNRuntimeError.archiveDamaged("索引数据不完整")
            }
            return [UInt8](raw)
        case 1:
            let packedSize = try readU64()
            let unpackedSize = try readU64()
            guard packedSize <= fileSize else {
                throw VNRuntimeError.archiveDamaged("索引长度越界")
            }
            // 注意：**解压后的索引大小不受文件大小约束**——几千个空/极小条目时，
            // 索引本身会比整个归档还大（实测 117KB 的文件可以有 450KB 的索引）。
            // 用压缩比上界挡一道即可，不要再拿 fileSize 去比。
            let (indexLimit, indexOverflow) = packedSize.multipliedReportingOverflow(by: 1032)
            guard !indexOverflow, unpackedSize <= indexLimit, unpackedSize <= 512 * 1024 * 1024 else {
                throw VNRuntimeError.archiveDamaged("索引声明的解压大小不合理（\(unpackedSize) 字节）")
            }
            guard let raw = try handle.read(upToCount: Int(packedSize)), raw.count == Int(packedSize) else {
                throw VNRuntimeError.archiveDamaged("索引数据不完整")
            }
            return try inflate([UInt8](raw), expectedSize: Int(unpackedSize))
        default:
            throw VNRuntimeError.archiveDamaged(String(format: "无法识别的索引标志 0x%02X", flag))
        }
    }

    // MARK: - 索引解析

    private func parseIndex(_ bytes: [UInt8]) throws {
        var cursor = ByteCursor(bytes)
        while cursor.remaining >= 12 {
            let tag = try cursor.take(4)
            var size = Int(clamping: try cursor.u64())
            if size > cursor.remaining {
                // 已知实现只容忍 info 的尺寸写错；顶层 chunk 越界就截断并记警告
                warnings.append("chunk \(ByteCursor.tagString(tag)) 尺寸越界，已截断")
                size = cursor.remaining
            }
            let bodyStart = cursor.pos
            if tag == ByteCursor.tag("File") {
                let body = ByteCursor(bytes, start: bodyStart, end: bodyStart + size)
                do {
                    if let entry = try parseFileEntry(body) {
                        entries.append(entry)
                        byName[XP3Archive.normalize(entry.name)] = entry
                    }
                } catch {
                    // 单个坏条目不该让整个归档打不开
                    warnings.append("跳过无法解析的条目：\(error.localizedDescription)")
                }
            }
            // Hxv4 / yuz: / sen: / dls: / hnfn / smil / eliF / Yuzu … 一律按 size 跳过
            cursor.pos = bodyStart + size
        }
        if entries.isEmpty {
            throw VNRuntimeError.archiveDamaged("索引里没有可用的文件条目（可能是加密封包）")
        }
    }

    private func parseFileEntry(_ body: ByteCursor) throws -> Entry? {
        var cursor = body
        var name: String?
        var originalSize = 0
        var archivedSize = 0
        var isProtected = false
        var adler: UInt32?
        var segments: [Segment] = []
        var elifRecord: (UInt32, String)?

        while cursor.remaining >= 12 {
            let tag = try cursor.take(4)
            var size = Int(clamping: try cursor.u64())
            if size > cursor.remaining {
                guard tag == ByteCursor.tag("info") else { break }
                size = cursor.remaining           // 只容忍 info 的尺寸不准
            }
            let bodyStart = cursor.pos
            var sub = ByteCursor(cursor.bytes, start: bodyStart, end: bodyStart + size)

            if tag == ByteCursor.tag("info") {
                let flags = try sub.u32()
                originalSize = Int(clamping: try sub.u64())
                archivedSize = Int(clamping: try sub.u64())
                let nameChars = Int(try sub.u16())
                if nameChars > 1024 {
                    warnings.append("文件名过长（\(nameChars) 字符），已忽略该条目")
                    return nil
                }
                let nameBytes = try sub.take(min(nameChars * 2, sub.remaining))
                var decoded = String(bytes: nameBytes, encoding: .utf16LittleEndian) ?? ""
                while decoded.hasSuffix("\u{0}") { decoded.removeLast() }   // 有的实现多写一个终止符
                name = decoded
                isProtected = (flags & 0x8000_0000) != 0
            } else if tag == ByteCursor.tag("segm") {
                while sub.remaining >= 28 {
                    let flag = try sub.u32()
                    let offset = try sub.u64()
                    let segOriginal = Int(clamping: try sub.u64())
                    let segArchived = Int(clamping: try sub.u64())
                    segments.append(Segment(compressed: flag == 1, offset: offset,
                                            originalSize: segOriginal, archivedSize: segArchived))
                }
                if sub.remaining > 0 {
                    warnings.append("segm 尾部有 \(sub.remaining) 字节余量，已忽略")
                }
            } else if tag == ByteCursor.tag("adlr") {
                adler = try sub.u32()
            } else if tag == ByteCursor.tag("eliF") {
                // 受保护条目：文件名被挪到 File 之前的 eliF 记录里
                _ = try? sub.u64()
                let value = (try? sub.u32()) ?? 0
                let chars = Int((try? sub.u16()) ?? 0)
                let nameBytes = (try? sub.take(min(chars * 2, sub.remaining))) ?? []
                let decoded = (String(bytes: nameBytes, encoding: .utf16LittleEndian) ?? "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\u{0}"))
                elifRecord = (value, decoded)
            }

            cursor.pos = bodyStart + size
        }

        if name == nil || name?.isEmpty == true {
            if let (value, elifName) = elifRecord, !elifName.isEmpty {
                // eliF 记录出现在受保护的封包里：名字被挪出 info。既然我们只认得名字字段、
                // 认不出它的加密方案，就必须按"受保护"处理——绝不能把密文当明文交给上层。
                warnings.append("条目名取自 eliF 记录：\(elifName)（按受保护条目处理）")
                adler = value
                name = elifName
                isProtected = true
            } else {
                return nil
            }
        }
        guard let finalName = name else { return nil }
        return Entry(name: finalName, originalSize: originalSize, archivedSize: archivedSize,
                     isProtected: isProtected, adler32: adler, segments: segments)
    }

    // MARK: - 工具

    static func normalize(_ name: String) -> String {
        var value = name.replacingOccurrences(of: "\\", with: "/")
        while value.hasPrefix("./") { value.removeFirst(2) }
        while value.hasPrefix("/") { value.removeFirst() }
        return value.lowercased()
    }

    /// 解压一段 XP3 数据。
    ///
    /// 关键事实（Apple 官方文档写明 `COMPRESSION_ZLIB` 就是 RFC1951 **raw deflate**，
    /// 内部用 `deflateInit2(..., -15, ...)`）：而 XP3 的段数据是 RFC1950 **包装**过的
    /// （2 字节 CMF/FLG 头 + deflate 数据 + 4 字节 Adler-32 尾）。所以**必须先剥掉头尾**
    /// 再交给 `compression_decode_buffer`。反过来把整包直接丢给 raw 解码器会失败。
    ///
    /// 保留第二条尝试是为了兼容"段里直接放 raw deflate（没有包装头）"的非标准封装，
    /// 这种情况在头校验阶段就会露馅，所以校验不通过时不能直接抛错，要留给回退分支。
    static func inflate(_ wrapped: [UInt8], expectedSize: Int) throws -> [UInt8] {
        guard expectedSize > 0 else { return [] }
        guard wrapped.count >= 2 else { throw VNRuntimeError.archiveDamaged("zlib 数据过短") }
        // 这里会按 expectedSize 预分配内存，而这个数字完全由文件内容决定：
        // 必须先用物理上界挡一道，否则一个 1KB 的压缩流谎称解压后有 8GB 就能把 App 撑崩。
        // deflate 的理论最大压缩比约 1032:1（不再额外 +64：那个加法本身在极端值上会溢出陷阱）。
        let (ratioLimit, ratioOverflow) = wrapped.count.multipliedReportingOverflow(by: 1032)
        guard !ratioOverflow, expectedSize <= ratioLimit else {
            throw VNRuntimeError.archiveDamaged("声明的解压大小不合理（\(expectedSize) 字节 / 压缩后 \(wrapped.count) 字节）")
        }
        guard expectedSize <= 512 * 1024 * 1024 else {
            throw VNRuntimeError.archiveDamaged("单个文件解压后超过 512MB，拒绝解压")
        }

        let cmf = wrapped[0], flg = wrapped[1]
        let hasZlibWrapper = (cmf & 0x0F) == 8 && ((UInt16(cmf) << 8) | UInt16(flg)) % 31 == 0

        if hasZlibWrapper {
            guard flg & 0x20 == 0 else {
                throw VNRuntimeError.archiveDamaged("zlib 使用了预置字典，暂不支持")
            }
            guard wrapped.count >= 6 else { throw VNRuntimeError.archiveDamaged("zlib 数据过短") }
            let stripped = Array(wrapped[2..<(wrapped.count - 4)])
            guard let out = try? rawInflate(stripped, expectedSize: expectedSize) else {
                throw VNRuntimeError.archiveDamaged("zlib 解压失败（期望 \(expectedSize) 字节）")
            }
            // 校验 zlib 尾部 4 字节大端 Adler-32。**不能**在剥离失败后拿整包再当 raw deflate 试一次：
            // CMF=0x78 会被当成 stored 块，后面全是文件内容说了算的字节，
            // 于是"解压成功"却返回一段垃圾数据，比直接报错糟糕得多。
            if out.count <= 32 * 1024 * 1024 {
                let trailer = wrapped.suffix(4)
                let expected = trailer.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard adler32(out) == expected else {
                    throw VNRuntimeError.archiveDamaged("zlib 校验和不符，数据已损坏")
                }
            }
            return out
        }

        // 非标准封装：段里直接就是 raw deflate（没有 RFC1950 头）
        if let out = try? rawInflate(wrapped, expectedSize: expectedSize) { return out }
        throw VNRuntimeError.archiveDamaged("既不是 zlib 流也不是 raw deflate")
    }

    private static func rawInflate(_ raw: [UInt8], expectedSize: Int) throws -> [UInt8] {
        guard !raw.isEmpty, expectedSize > 0 else { throw VNRuntimeError.archiveDamaged("空 deflate 流") }
        // 目标缓冲比声明大小多 1 字节：这样"正好填满"与"被截断"才能区分开——
        // 若缓冲刚好等于声明大小，某些情况下两者都会返回相同的计数，无法判断。
        let capacity = expectedSize + 1
        var output = [UInt8](repeating: 0, count: capacity)
        let written = raw.withUnsafeBufferPointer { source -> Int in
            output.withUnsafeMutableBufferPointer { destination -> Int in
                guard let src = source.baseAddress, let dst = destination.baseAddress else { return 0 }
                return compression_decode_buffer(dst, capacity, src, raw.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else {
            throw VNRuntimeError.archiveDamaged("deflate 解压得到 \(written)/\(expectedSize) 字节")
        }
        output.removeLast()
        return output
    }

    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes {
            a = (a &+ UInt32(byte)) % 65521
            b = (b &+ a) % 65521
        }
        return (b << 16) | a
    }
}

// MARK: - 字节游标

/// 带边界检查的游标读取器。所有越界都抛错误，绝不越界读数组。
struct ByteCursor {
    let bytes: [UInt8]
    var pos: Int
    let end: Int

    init(_ bytes: [UInt8], start: Int = 0, end: Int? = nil) {
        self.bytes = bytes
        self.pos = max(0, min(start, bytes.count))
        self.end = max(self.pos, min(end ?? bytes.count, bytes.count))
    }

    var remaining: Int { end - pos }

    func need(_ n: Int) throws {
        // 不用 pos + n <= end：n 可能是 Int.max（来自文件里的超大长度字段），那会整数溢出陷阱
        guard n >= 0, n <= end - pos else {
            throw VNRuntimeError.archiveDamaged("数据越界（需要 \(n) 字节，剩余 \(remaining)）")
        }
    }

    mutating func u8() throws -> UInt8 {
        try need(1)
        defer { pos += 1 }
        return bytes[pos]
    }

    mutating func u16() throws -> UInt16 {
        try need(2)
        defer { pos += 2 }
        return UInt16(bytes[pos]) | (UInt16(bytes[pos + 1]) << 8)
    }

    mutating func u32() throws -> UInt32 {
        try need(4)
        defer { pos += 4 }
        return UInt32(bytes[pos]) | (UInt32(bytes[pos + 1]) << 8)
            | (UInt32(bytes[pos + 2]) << 16) | (UInt32(bytes[pos + 3]) << 24)
    }

    mutating func u64() throws -> UInt64 {
        try need(8)
        defer { pos += 8 }
        var value: UInt64 = 0
        for i in (0..<8).reversed() { value = (value << 8) | UInt64(bytes[pos + i]) }
        return value
    }

    mutating func take(_ n: Int) throws -> [UInt8] {
        try need(n)
        defer { pos += n }
        return Array(bytes[pos..<(pos + n)])
    }

    static func tag(_ text: String) -> [UInt8] { Array(text.utf8) }

    static func tagString(_ tag: [UInt8]) -> String {
        String(bytes: tag, encoding: .utf8) ?? tag.map { String(format: "%02X", $0) }.joined()
    }
}
