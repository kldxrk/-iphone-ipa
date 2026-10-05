import Foundation

struct VNChoice: Codable, Hashable, Identifiable {
    let text: String
    let target: String
    var id: String { text + "->" + target }
}

struct VNSprite: Codable, Hashable, Identifiable {
    let id: String
    let file: String
    let pos: String
}

enum VNCommand {
    case label(String)
    case bg(String)
    case bgm(String?)
    case se(String)
    case show(id: String, file: String, pos: String)
    case hide(String)
    case say(speaker: String?, text: String)
    case choice([VNChoice])
    case jump(String)
    case end
}

struct VNScript {
    var title: String?
    var commands: [VNCommand]
    var labels: [String: Int]
    /// 非致命问题（未知指令、悬空跳转、重复标签……）。载入后在诊断面板里一次性展示，
    /// 不再像 1.1 那样因为一行写错就整个游戏打不开。
    var warnings: [String] = []
    /// 脚本来源，例如 "script.vns" 或 "data.xp3 → script.vns"。
    var origin: String = "script.vns"
}

struct VNSnapshot: Codable {
    var pc: Int
    var background: String?
    var bgm: String?
    var sprites: [VNSprite]
    var speaker: String?
    var text: String
    var choices: [VNChoice]
    /// 1.2 起保存历史记录。旧存档没有这个字段，因此下面的解码器用 decodeIfPresent 兼容，
    /// 否则之前存的档会全部读不出来。
    var log: [VNLogEntry]

    init(pc: Int, background: String?, bgm: String?, sprites: [VNSprite],
         speaker: String?, text: String, choices: [VNChoice], log: [VNLogEntry] = []) {
        self.pc = pc
        self.background = background
        self.bgm = bgm
        self.sprites = sprites
        self.speaker = speaker
        self.text = text
        self.choices = choices
        self.log = log
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pc = try c.decode(Int.self, forKey: .pc)
        background = try c.decodeIfPresent(String.self, forKey: .background)
        bgm = try c.decodeIfPresent(String.self, forKey: .bgm)
        sprites = try c.decodeIfPresent([VNSprite].self, forKey: .sprites) ?? []
        speaker = try c.decodeIfPresent(String.self, forKey: .speaker)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        choices = try c.decodeIfPresent([VNChoice].self, forKey: .choices) ?? []
        log = try c.decodeIfPresent([VNLogEntry].self, forKey: .log) ?? []
    }
}

struct VNSave: Codable {
    let gameId: String
    let title: String
    let preview: String
    let timestamp: Date
    let snapshot: VNSnapshot
}

struct VNGameInfo: Identifiable, Hashable {
    let id: String
    let title: String
    /// 游戏所在目录（内置示例是 App 包内的 Demo 目录）。
    let root: URL
    /// 需要挂载的封包，目前支持 KiriKiri 的 .xp3；为 nil 时只用目录里的散装素材。
    let archive: URL?
    /// 脚本相对路径：目录里就写 "script.vns"，封包里则是包内路径。
    let scriptPath: String
    let folder: URL?
    let isBuiltIn: Bool
    /// 是否由 App 的「导入」功能拷进来的（与用户自己用「文件」App 放进去的分开存放）。
    let isImported: Bool

    init(id: String, title: String, root: URL, archive: URL? = nil, scriptPath: String = "script.vns",
         folder: URL?, isBuiltIn: Bool, isImported: Bool = false) {
        self.id = id
        self.title = title
        self.root = root
        self.archive = archive
        self.scriptPath = scriptPath
        self.folder = folder
        self.isBuiltIn = isBuiltIn
        self.isImported = isImported
    }

    /// 界面上用来描述素材来源的短文本。
    var sourceLabel: String {
        guard let archive = archive else { return isBuiltIn ? "内置示例" : root.lastPathComponent }
        return archive.lastPathComponent
    }
}

struct VNLogEntry: Codable, Identifiable {
    var id = UUID()
    let speaker: String?
    let text: String
}

/// 一条诊断信息，用于游戏库里排查"为什么打不开 / 素材为什么缺"。
struct VNDiagnostic: Identifiable {
    enum Level {
        case info, warning, error

        var symbol: String {
            switch self {
            case .info: return "info.circle"
            case .warning: return "exclamationmark.triangle"
            case .error: return "xmark.octagon"
            }
        }
    }

    let id = UUID()
    let level: Level
    let text: String
}

enum VNRuntimeError: Error {
    case gameNotFound
    case scriptMissing
    case scriptEncoding
    case scriptSyntax(line: Int, message: String)
    case unknownLabel(String)
    case invalidPath
    case saveFailed(String)
    case unsupportedArchive
    case archiveDamaged(String)
}

extension VNRuntimeError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .gameNotFound: return "找不到游戏数据"
        case .scriptMissing: return "缺少脚本（script.vns 或封包内的 .vns）"
        case .scriptEncoding: return "脚本文本编码无法识别（请用 UTF-8 或 GBK）"
        case .scriptSyntax(let line, let message): return "脚本第 \(line) 行：\(message)"
        case .unknownLabel(let name): return "跳转目标不存在：\(name)"
        case .invalidPath: return "非法路径"
        case .saveFailed(let reason): return "存档失败：\(reason)"
        case .unsupportedArchive: return "暂不支持该封包格式"
        case .archiveDamaged(let reason): return "封包损坏或格式不认识：\(reason)"
        }
    }
}
