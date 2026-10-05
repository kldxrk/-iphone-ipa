import Foundation

/// 统一处理脚本文本编码。
///
/// 真实会遇到的三类文件：
///  * 我们自己写的 .vns —— UTF-8（可能有 BOM）；
///  * 中文 Windows 记事本"ANSI"另存 —— GB18030；
///  * 记事本"Unicode"另存 —— UTF-16LE/BE 带 BOM（1.1 会当成 GBK 解出一堆乱码）。
///
/// 判据刻意保持简单且可解释：只有**原始字节里出现 0x00** 才考虑 UTF-16。
/// GBK 与 UTF-8 文本不会包含 0x00，而无 BOM 的 UTF-16 只要有换行或 `@tag` 就必然出现 0x00。
/// 反过来如果靠"UTF-16 解得干净"来判断，GBK 的中文字节恰好也能解成合法汉字，会误判。
enum ScriptText {
    static func decode(_ data: Data) -> String? {
        // 1) BOM 最可靠，直接按它解
        if data.count >= 2 {
            let b0 = data[data.startIndex]
            let b1 = data[data.index(after: data.startIndex)]
            if b0 == 0xFF, b1 == 0xFE {
                return stripBOM(String(data: data, encoding: .utf16LittleEndian))
            }
            if b0 == 0xFE, b1 == 0xFF {
                return stripBOM(String(data: data, encoding: .utf16BigEndian))
            }
            if data.count >= 3,
               b0 == 0xEF, b1 == 0xBB, data[data.index(data.startIndex, offsetBy: 2)] == 0xBF {
                return stripBOM(String(data: data, encoding: .utf8))
            }
        }

        // 2) 无 BOM 的 UTF-16：靠 0x00 这个强信号
        if data.count % 2 == 0, data.contains(0) {
            let candidates = [String(data: data, encoding: .utf16LittleEndian),
                              String(data: data, encoding: .utf16BigEndian)]
                .compactMap { $0 }
                .filter(plausibleText)
            if let best = candidates.max(by: { textScore($0) < textScore($1) }) {
                return stripBOM(best)
            }
        }

        // 3) UTF-8（含 CJK）
        if let s = String(data: data, encoding: .utf8), !s.contains("\u{0}") {
            return stripBOM(s)
        }

        // 4) GB18030 兜底
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return stripBOM(String(data: data, encoding: String.Encoding(rawValue: gb)))
    }

    /// 解出来的文本不能含 NUL、也不能含除制表/换行以外的控制字符，否则说明挑错了编码。
    static func plausibleText(_ s: String) -> Bool {
        for ch in s.prefix(4096) {
            if ch == "\u{0}" { return false }
            if let ascii = ch.asciiValue, ascii < 0x20, ascii != 0x09, ascii != 0x0A, ascii != 0x0D {
                return false
            }
        }
        return true
    }

    static func textScore(_ s: String) -> Int {
        var score = 0
        for ch in s.prefix(512) {
            if ch == "\u{0}" { score -= 10 }
            else if ch == "\n" || ch == "\r" || ch == "\t" { score += 1 }
            else if let ascii = ch.asciiValue, ascii < 0x20 { score -= 5 }
            else { score += 1 }
        }
        return score
    }

    static func stripBOM(_ s: String?) -> String? {
        guard var s = s else { return nil }
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        return s
    }
}

enum ScriptParser {
    /// 解析脚本。**只有整份脚本完全不可用时才抛错**；单行写错会记进 `warnings` 并跳过，
    /// 这样第三方脚本（尤其是从 KiriKiri 那边转过来的）不会因为一处笔误就整个打不开。
    static func parse(_ source: String, origin: String = "script.vns") throws -> VNScript {
        var commands: [VNCommand] = []
        var labels: [String: Int] = [:]
        var title: String? = nil
        /// 每条命令对应的源码行号，让警告能指回真正的位置而不是命令序号。
        var cmdLines: [Int] = []
        var parseLine = 0

        // 警告按"消息"去重：一份从 KR 转来的脚本可能有几百行同样的未知指令，
        // 逐行记录会把诊断列表刷爆，把真正的问题淹掉。
        var messageOrder: [String] = []
        var messageFirstLine: [String: Int] = [:]
        var messageCount: [String: Int] = [:]
        let maxMessages = 200

        func warn(_ line: Int, _ message: String) {
            if let n = messageCount[message] {
                messageCount[message] = n + 1
                return
            }
            guard messageOrder.count < maxMessages else { return }
            messageOrder.append(message)
            messageFirstLine[message] = line
            messageCount[message] = 1
        }

        func emit(_ cmd: VNCommand) {
            commands.append(cmd)
            cmdLines.append(parseLine)
        }

        var text = source
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")

        var lineNo = 0
        for rawLine in text.components(separatedBy: "\n") {
            lineNo += 1
            parseLine = lineNo

            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { continue }

            if line.hasPrefix("@") {
                let tokens = tokenize(String(line.dropFirst()))
                guard let first = tokens.first else { continue }
                let name = first.lowercased()
                let args = Array(tokens.dropFirst())

                func arg(_ i: Int, _ what: String) -> String? {
                    guard i < args.count, !args[i].isEmpty else {
                        warn(lineNo, "@\(name) 缺少\(what)，已跳过")
                        return nil
                    }
                    return args[i]
                }

                switch name {
                case "title":
                    title = args.joined(separator: " ")
                case "label":
                    guard let l = arg(0, "名称") else { break }
                    if labels[l] != nil { warn(lineNo, "标签 \(l) 重复定义") }
                    labels[l] = commands.count
                    emit(.label(l))
                case "bg":
                    if let f = arg(0, "图片文件名") { emit(.bg(f)) }
                case "bgm":
                    if let f = arg(0, "音乐文件名（或 stop）") {
                        emit(.bgm(f.lowercased() == "stop" ? nil : f))
                    }
                case "se":
                    if let f = arg(0, "音效文件名") { emit(.se(f)) }
                case "show":
                    guard let id = arg(0, "角色标识"), let file = arg(1, "图片文件名") else { break }
                    let pos = args.count > 2 ? args[2] : "center"
                    emit(.show(id: id, file: file, pos: pos))
                case "hide":
                    if let id = arg(0, "角色标识（或 all）") { emit(.hide(id)) }
                case "jump":
                    if let l = arg(0, "标签名") { emit(.jump(l)) }
                case "choice":
                    var items: [VNChoice] = []
                    for a in args {
                        guard let eq = a.lastIndex(of: "=") else {
                            warn(lineNo, "选项不是 文字=标签 的写法，已跳过该选项")
                            continue
                        }
                        let t = String(a[a.startIndex..<eq])
                        let target = String(a[a.index(after: eq)...])
                        if t.isEmpty || target.isEmpty {
                            warn(lineNo, "选项不是 文字=标签 的写法，已跳过该选项")
                            continue
                        }
                        items.append(VNChoice(text: t, target: target))
                    }
                    if items.isEmpty {
                        warn(lineNo, "@choice 没有任何有效选项，已跳过")
                    } else {
                        emit(.choice(items))
                    }
                case "end":
                    emit(.end)
                default:
                    warn(lineNo, "未知指令 @\(name)，已跳过")
                }
            } else if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
                let who = String(line[line.index(after: line.startIndex)..<close]).trimmingCharacters(in: .whitespaces)
                let body = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                emit(.say(speaker: who.isEmpty ? nil : who, text: unescape(body)))
            } else {
                emit(.say(speaker: nil, text: unescape(line)))
            }
        }

        // 跳转目标校验：不抛错，只记警告——运行时遇到不存在的标签会原地跳过。
        for (index, cmd) in commands.enumerated() {
            let line = index < cmdLines.count ? cmdLines[index] : index + 1
            switch cmd {
            case .jump(let l):
                if labels[l] == nil { warn(line, "跳转目标 \(l) 不存在") }
            case .choice(let items):
                for c in items where labels[c.target] == nil {
                    warn(line, "选项「\(c.text)」的目标 \(c.target) 不存在")
                }
            default:
                break
            }
        }

        guard !commands.isEmpty else {
            throw VNRuntimeError.scriptSyntax(line: 1, message: "脚本里没有可执行内容（检查编码或文件是否选错）")
        }

        let warnings = messageOrder.map { message -> String in
            let line = messageFirstLine[message] ?? 0
            let n = messageCount[message] ?? 1
            return n > 1 ? "第 \(line) 行：\(message)（同类 \(n) 处）" : "第 \(line) 行：\(message)"
        }
        return VNScript(title: title, commands: commands, labels: labels, warnings: warnings, origin: origin)
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n")
    }

    private static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var hasToken = false
        for ch in s {
            if ch == "\"" {
                inQuote.toggle()
                hasToken = true
                continue
            }
            if (ch == " " || ch == "\t") && !inQuote {
                if hasToken {
                    tokens.append(current)
                    current = ""
                    hasToken = false
                }
                continue
            }
            current.append(ch)
            hasToken = true
        }
        if hasToken { tokens.append(current) }
        return tokens
    }
}
