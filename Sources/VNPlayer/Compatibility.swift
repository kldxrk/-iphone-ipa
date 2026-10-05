import Foundation

/// 一个游戏（封包或文件夹）的兼容性体检报告。
///
/// 存在的理由：用户手上是真实 KR 游戏，而"能不能跑、要哪条路线"取决于几个客观事实——
/// 封包是否受保护、脚本是不是明文 KAG、有多少处依赖 TJS、素材里有多少 iOS 解不了的格式。
/// 这些都能在**不解密、不执行脚本**的前提下测出来，先测再决定投入，避免白干。
struct CompatibilityReport {
    enum Verdict {
        /// 有 .vns，当前版本直接能玩
        case playable
        /// 未加密 + 明文 KAG + 没有 TJS 构造：转换器（路线 A）与 App 内 KAG 解释器（路线 B）都可行
        case routeAB
        /// 明文 KAG，但存在需要 TJS 的构造：只能走路线 A，且那 N 处要人工处理
        case routeA
        /// 找不到明文脚本（编译过的 / 只有 .tjs / 结构不认识）：只能走引擎级方案（路线 C）
        case routeC
        /// 受保护或读不出：任何路线都拿不到内容
        case blocked

        var title: String {
            switch self {
            case .playable: return "结论：可以直接玩（当前版本已支持）"
            case .routeAB: return "结论：可以做——路线 A（PC 转换器）与 B（App 内 KAG 解释器）都可行"
            case .routeA: return "结论：只能走路线 A（PC 转换器），且含 TJS 的部分需要人工处理"
            case .routeC: return "结论：需要引擎级方案（路线 C），转换器与 KAG 子集解释器都不够"
            case .blocked: return "结论：读不出内容——受保护封包，任何路线都无解"
            }
        }

        var level: VNDiagnostic.Level {
            switch self {
            case .playable, .routeAB: return .info
            case .routeA, .routeC: return .warning
            case .blocked: return .error
            }
        }
    }

    var fileName: String = ""
    var entryCount = 0
    var totalBytes = 0
    var protectedCount = 0
    var extensionCounts: [String: Int] = [:]
    var scriptNames: [String] = []
    var sampledScripts = 0
    var plainTextScripts = 0
    var hasVNSScript = false

    // 需要 TJS2 的构造计数（在明文本脚本里按 ASCII 字节模式统计，不受 Shift-JIS/UTF-8 影响）
    var expCount = 0
    var condCount = 0
    var expressionValueCount = 0
    var iscriptCount = 0
    var macroCount = 0
    var embeddedCount = 0

    var verdict: Verdict = .routeC
    var notes: [String] = []

    // 插件依赖：这决定"引擎级路线能不能跑这款游戏"。
    // Windows 插件是 .dll/.tpm，Android/iOS 移植只能靠静态 stub 替换，覆盖不到的游戏就是跑不了。
    var pluginBinaryCount = 0
    var pluginMentions: [String: Int] = [:]

    var pluginKeywords: [String] { pluginMentions.keys.sorted() }

    var tjsConstructs: Int {
        expCount + condCount + expressionValueCount + iscriptCount + macroCount + embeddedCount
    }

    /// 供诊断面板直接展示。
    var diagnostics: [VNDiagnostic] {
        var out: [VNDiagnostic] = [VNDiagnostic(level: verdict.level, text: verdict.title)]
        out.append(VNDiagnostic(level: .info, text: "目标：\(fileName)，\(entryCount) 个文件，合计 \(CompatibilityReport.sizeText(totalBytes))"))
        if protectedCount > 0 {
            out.append(VNDiagnostic(level: .error,
                                    text: "受保护（加密）条目：\(protectedCount)/\(entryCount)——这些内容读不出来，密钥不在文件格式里"))
        }
        if !scriptNames.isEmpty {
            let shown = scriptNames.prefix(12).joined(separator: "、")
            let more = scriptNames.count > 12 ? " 等 \(scriptNames.count) 个" : ""
            out.append(VNDiagnostic(level: .info, text: "脚本文件：\(shown)\(more)"))
        }
        out.append(VNDiagnostic(level: plainTextScripts > 0 ? .info : .warning,
                                text: "抽检 \(sampledScripts) 个文本类脚本，其中 \(plainTextScripts) 个是明文 KAG"))
        if tjsConstructs > 0 {
            out.append(VNDiagnostic(level: .warning,
                                    text: "需要 TJS2 的构造共 \(tjsConstructs) 处（exp= \(expCount)、cond= \(condCount)、=& \(expressionValueCount)、[iscript] \(iscriptCount)、宏 \(macroCount)、[eval]/[emb] \(embeddedCount)）——这些原理上无法用文本转换或子集解释器处理"))
        } else if plainTextScripts > 0 {
            out.append(VNDiagnostic(level: .info, text: "未发现需要 TJS2 的构造"))
        }
        if let line = extensionSummary() {
            out.append(VNDiagnostic(level: .info, text: "内容构成（按扩展名）：\(line)"))
        }
        if let needs = transcodeSummary() {
            out.append(VNDiagnostic(level: .warning, text: "iOS 解不了、需要转码的素材：\(needs)"))
        }
        if pluginBinaryCount > 0 || !pluginMentions.isEmpty {
            let names = pluginMentions.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                .prefix(10).map { "\($0.key)×\($0.value)" }.joined(separator: "、")
            out.append(VNDiagnostic(level: .error,
                                    text: "检测到插件依赖：包内插件二进制 \(pluginBinaryCount) 个；脚本里提到 \(names)。"
                                        + "引擎级方案（路线 C）在手机上必须用静态 stub 替代这些 Windows 插件，覆盖不到就跑不了"))
        }
        for note in notes {
            out.append(VNDiagnostic(level: .warning, text: note))
        }
        return out
    }

    func extensionSummary() -> String? {
        guard !extensionCounts.isEmpty else { return nil }
        let top = extensionCounts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(8)
        return top.map { "\($0.key)×\($0.value)" }.joined(separator: "、")
    }

    func transcodeSummary() -> String? {
        let wanted = CompatibilityAnalyzer.imageNeedsWork
            .union(CompatibilityAnalyzer.audioNeedsWork)
            .union(CompatibilityAnalyzer.videoNeedsWork)
        // 键是 ".tlg" 这种带点的形式（无扩展名的条目是"无扩展名"），去掉前导点再比对
        let hits = extensionCounts.filter { wanted.contains(String($0.key.drop(while: { $0 == "." }))) }
        guard !hits.isEmpty else { return nil }
        return hits.sorted { $0.value > $1.value }.map { "\($0.key)×\($0.value)" }.joined(separator: "、")
    }

    static func sizeText(_ bytes: Int) -> String {
        if bytes >= 1024 * 1024 * 1024 { return String(format: "%.1f GB", Double(bytes) / 1073741824) }
        if bytes >= 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / 1048576) }
        if bytes >= 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return "\(bytes) B"
    }
}

enum CompatibilityAnalyzer {
    /// 脚本类扩展名；`.ks`/`.tjs` 是 KiriKiri KAG/TJS2，`.vns` 是我们自己的格式。
    static let scriptExtensions: Set<String> = ["ks", "tjs", "vns", "asd", "txt"]
    static let imageNeedsWork: Set<String> = ["tlg", "pimg", "eri", "tft", "jxr"]
    static let audioNeedsWork: Set<String> = ["ogg", "oga", "opus", "mio"]
    static let videoNeedsWork: Set<String> = ["mpg", "mpeg", "wmv", "avi", "swf"]

    /// Windows 插件二进制。手机上（含任何引擎移植）都只能靠静态 stub 替代，
    /// 所以"包里有没有插件"直接决定引擎级路线能不能跑这款游戏。
    static let pluginBinaryExtensions: Set<String> = ["dll", "tpm"]
    /// 脚本里值得警惕的插件/专有运行时关键字（小写形式比对）。
    static let pluginKeywordList: [String] = [
        "loadplugin", "motionplayer", "live2d", "emote", "psbfile", "psdfile", "kagparser",
        "layerex", "windowex", "drawdevice", "fstat", "xp3filter", "savestruct", "csvparser",
        "textrender", "kirikiroid", "extrans", "alphamovie"
    ]

    /// 抽检上限：报告要秒出，不能为了统计把整个封包读一遍。
    static let maxSampledScripts = 24
    static let maxBytesPerScript = 512 * 1024

    struct Item {
        let name: String
        let size: Int
        let isProtected: Bool
        let read: () -> Data?
    }

    static func analyze(folder: URL, archiveURL: URL?) -> CompatibilityReport {
        if let archiveURL, let archive = try? XP3Archive(url: archiveURL) {
            let items = archive.entries.map { entry in
                Item(name: entry.name, size: entry.originalSize, isProtected: entry.isProtected) {
                    try? archive.data(for: entry)
                }
            }
            var report = analyze(items: items, fileName: archiveURL.lastPathComponent)
            for warning in archive.warnings {
                report.notes.append("封包：\(warning)")
            }
            return report
        }

        // 散装文件夹
        let source = DirectorySource(root: folder)
        let names = source.listFiles()
        let items = names.map { name -> Item in
            let url = source.resolve(name)
            let size = url.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0
            return Item(name: name, size: size, isProtected: false) {
                guard let url else { return nil }
                return try? Data(contentsOf: url, options: .mappedIfSafe)
            }
        }
        return analyze(items: items, fileName: folder.lastPathComponent)
    }

    /// 纯逻辑部分：只依赖条目列表，便于用 Python 等价移植测试。
    static func analyze(items: [Item], fileName: String) -> CompatibilityReport {
        var report = CompatibilityReport()
        report.fileName = fileName
        report.entryCount = items.count
        report.totalBytes = items.reduce(0) { $0 + max(0, $1.size) }
        report.protectedCount = items.filter(\.isProtected).count

        for item in items {
            let ext = (item.name as NSString).pathExtension.lowercased()
            report.extensionCounts[ext.isEmpty ? "无扩展名" : "." + ext, default: 0] += 1
        }

        let scripts = items.filter { scriptExtensions.contains(($0.name as NSString).pathExtension.lowercased()) }
        report.scriptNames = Array(scripts.map(\.name).sorted().prefix(200))
        report.hasVNSScript = scripts.contains { ($0.name as NSString).pathExtension.lowercased() == "vns" }

        for script in scripts.prefix(maxSampledScripts) {
            guard !script.isProtected, let data = script.read() else { continue }
            report.sampledScripts += 1
            let bytes = Array(data.prefix(maxBytesPerScript))
            // ASCII 小写化（|0x20 只对小写化 ASCII 有效，我们只找 ASCII 关键字；
            // 高位字节会被改掉，但那不影响这些特征词的匹配）
            let lowered = bytes.map { $0 | 0x20 }
            for keyword in pluginKeywordList {
                let hits = count(Array(keyword.utf8), in: lowered)
                if hits > 0 { report.pluginMentions[keyword, default: 0] += hits }
            }
            if looksLikePlainKAG(bytes) {
                report.plainTextScripts += 1
                report.expCount += count(Array("exp=".utf8), in: bytes)
                report.condCount += count(Array("cond=".utf8), in: bytes)
                report.expressionValueCount += count(Array("=&".utf8), in: bytes)
                report.iscriptCount += count(Array("[iscript".utf8), in: bytes)
                report.macroCount += count(Array("[macro".utf8), in: bytes)
                report.embeddedCount += count(Array("[eval".utf8), in: bytes)
                    + count(Array("[emb".utf8), in: bytes)
            }
        }

        report.pluginBinaryCount = items.filter {
            pluginBinaryExtensions.contains(($0.name as NSString).pathExtension.lowercased())
        }.count

        if !report.hasVNSScript, scripts.count > report.sampledScripts {
            report.notes.append("脚本共 \(scripts.count) 个，只抽检了前 \(report.sampledScripts) 个")
        }

        // 判定以"脚本能不能读"为准，而不是简单看受保护条目占比：
        // 90% 素材受保护但 first.ks 是明文，照样能走路线 A；
        // 反过来只有 1/4 条目受保护、但唯一的脚本正好在其中，就完全没戏。
        let protectedScripts = scripts.filter(\.isProtected).count
        if report.hasVNSScript {
            report.verdict = .playable
        } else if !scripts.isEmpty, protectedScripts == scripts.count {
            report.verdict = .blocked
        } else if report.plainTextScripts > 0 {
            report.verdict = report.tjsConstructs > 0 ? .routeA : .routeAB
        } else if report.protectedCount > 0 {
            report.verdict = .blocked
        } else {
            report.verdict = .routeC
        }
        return report
    }

    /// 明文 KAG 的判据用 ASCII 关键字，**不依赖文本编码**：
    /// 日文 KR 脚本多为 Shift-JIS，按编码解可能乱码，但这些标签名是 ASCII，按字节找最稳。
    static func looksLikePlainKAG(_ bytes: [UInt8]) -> Bool {
        let marks: [[UInt8]] = [Array("storage=".utf8), Array("[image".utf8),
                                Array("[playbgm".utf8), Array("[wait".utf8), Array("[bg".utf8)]
        return marks.contains { count($0, in: bytes, limit: 1) > 0 }
    }

    /// 朴素字节查找；`limit` 用于提前收手，避免在超大脚本上白跑。
    static func count(_ needle: [UInt8], in haystack: [UInt8], limit: Int = 100_000) -> Int {
        guard !needle.isEmpty, haystack.count >= needle.count else { return 0 }
        var found = 0
        let last = haystack.count - needle.count
        var i = 0
        while i <= last {
            if haystack[i] == needle[0] {
                var matched = true
                for j in 1..<needle.count where haystack[i + j] != needle[j] {
                    matched = false
                    break
                }
                if matched {
                    found += 1
                    if found >= limit { return found }
                    i += needle.count
                    continue
                }
            }
            i += 1
        }
        return found
    }
}
