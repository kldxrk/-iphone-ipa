import Foundation
import SwiftUI

@MainActor
final class VNRuntime: ObservableObject {
    @Published private(set) var info: VNGameInfo?
    @Published private(set) var background: String?
    @Published private(set) var sprites: [VNSprite] = []
    @Published private(set) var speaker: String?
    @Published private(set) var fullText: String = ""
    @Published private(set) var choices: [VNChoice] = []
    @Published private(set) var isFinished = false
    @Published private(set) var log: [VNLogEntry] = []
    @Published private(set) var lineID = 0
    /// 载入过程的事实与问题，供诊断面板展示。
    @Published private(set) var diagnostics: [VNDiagnostic] = []
    @Published var message: String?
    @Published var autoMode = false
    @Published var skipMode = false

    private(set) var assets: AssetLoader?
    private var script: VNScript?
    private var pc = 0
    private var started = false
    private var currentBGM: String?
    private var warnedMissing = Set<String>()
    private let audio = AudioManager()
    private let saves = SaveManager()

    private let maxDiagnostics = 200

    // MARK: - 打开 / 关闭

    @discardableResult
    func open(_ game: VNGameInfo) -> Bool {
        diagnostics = []
        do {
            var startup: [VNDiagnostic] = []
            var sources: [AssetSource] = []
            // 目录优先于封包：这样用户可以把改过的图片/音乐放在 data.xp3 旁边来覆盖包内素材。
            // 脚本的优先级也是同一套道理（见 loadScript）——两处必须一致，否则会出现
            // "脚本读的是文件夹里的、素材读的是包里的"这种自相矛盾的行为。
            sources.append(DirectorySource(root: game.root))
            if let archiveURL = game.archive {
                let archive = try XP3Archive(url: archiveURL)
                sources.append(try XP3Source(archive: archive))
                startup.append(VNDiagnostic(level: .info,
                                            text: "已挂载封包 \(archiveURL.lastPathComponent)：\(archive.count) 个文件"))
                for warning in archive.warnings {
                    startup.append(VNDiagnostic(level: .warning, text: "封包 \(warning)"))
                }
            }
            let loader = AssetLoader(source: CompositeSource(sources))

            let parsed = try loadScript(game, loader: loader)
            startup.append(VNDiagnostic(level: .info, text: "脚本来源：\(parsed.origin)"))
            startup.append(VNDiagnostic(level: .info,
                                        text: "指令 \(parsed.commands.count) 条，标签 \(parsed.labels.count) 个"))
            startup.append(VNDiagnostic(level: .info, text: "素材源：\(loader.sourceDescription)"))
            for warning in parsed.warnings {
                startup.append(VNDiagnostic(level: .warning, text: "脚本 \(warning)"))
            }

            audio.stopBGM()
            currentBGM = nil
            reset()
            diagnostics = startup
            script = parsed
            assets = loader
            info = game
            started = true
            audio.bgmVolume = Float(UserDefaults.standard.object(forKey: "bgmVolume") as? Double ?? 0.7)
            advance()
            return true
        } catch {
            reset()
            diagnose(.error, "载入失败：\(error.localizedDescription)")
            flash("载入失败：\(error.localizedDescription)")
            return false
        }
    }

    func restart() {
        if let i = info { open(i) }
    }

    func close() {
        if info != nil && started && !isFinished { autoSave() }
        audio.stopBGM()
        currentBGM = nil
        reset()
        script = nil
        assets = nil
        info = nil
        started = false
        diagnostics = []
    }

    private func reset() {
        background = nil
        sprites = []
        speaker = nil
        fullText = ""
        choices = []
        isFinished = false
        log = []
        autoMode = false
        skipMode = false
        pc = 0
        lineID = 0
        warnedMissing = []
    }

    // MARK: - 素材源

    private func loadScript(_ game: VNGameInfo, loader: AssetLoader) throws -> VNScript {
        // 1) 文件夹里的脚本优先，方便覆盖包内脚本做调试
        let external = game.root.appendingPathComponent(game.scriptPath)
        if FileManager.default.fileExists(atPath: external.path) {
            let data = try Data(contentsOf: external, options: .mappedIfSafe)
            guard let text = ScriptText.decode(data) else { throw VNRuntimeError.scriptEncoding }
            return try ScriptParser.parse(text, origin: "\(game.scriptPath)（文件夹）")
        }

        // 2) 封包内：走已挂载的 loader，顺带支持脚本在子目录或名字不叫 script.vns 的情况
        if let archiveURL = game.archive, loader.contains(game.scriptPath) {
            let data = try loader.data(for: game.scriptPath)
            guard let text = ScriptText.decode(data) else { throw VNRuntimeError.scriptEncoding }
            return try ScriptParser.parse(text, origin: "\(archiveURL.lastPathComponent) → \(game.scriptPath)")
        }

        throw VNRuntimeError.scriptMissing
    }

    // MARK: - 推进剧情

    func next() {
        guard !isFinished, choices.isEmpty else { return }
        advance()
    }

    func choose(_ c: VNChoice) {
        guard let script = script, let idx = script.labels[c.target] else { return }
        log.append(VNLogEntry(speaker: nil, text: "▶ " + c.text))
        pc = idx
        choices = []
        advance()
    }

    private func advance() {
        guard let script = script else { return }
        choices = []
        // 两道保护分开计数：一段脚本里连续几千条 @bg/@show 是合法的，
        // 只有"跳转"次数异常才说明是死循环。1.1 把两者混在一起，正常脚本也可能被误判。
        var steps = 0
        var jumps = 0
        while pc < script.commands.count {
            steps += 1
            if steps > 200_000 {
                diagnose(.error, "脚本执行步数异常，已停止（可能死循环）")
                flash("脚本可能存在死循环，已停止")
                return
            }
            let cmd = script.commands[pc]
            pc += 1
            switch cmd {
            case .label:
                break
            case .bg(let file):
                background = file
                checkAsset(file, kind: "背景")
            case .bgm(let file):
                if let f = file { playBGM(f) } else { audio.stopBGM(); currentBGM = nil }
            case .se(let file):
                playSE(file)
            case .show(let id, let file, let pos):
                sprites.removeAll { $0.id == id }
                sprites.append(VNSprite(id: id, file: file, pos: pos))
                checkAsset(file, kind: "立绘")
            case .hide(let id):
                if id.lowercased() == "all" {
                    sprites.removeAll()
                } else {
                    sprites.removeAll { $0.id == id }
                }
            case .say(let who, let text):
                speaker = who
                fullText = text
                lineID += 1
                log.append(VNLogEntry(speaker: who, text: text))
                if log.count > 300 { log.removeFirst(log.count - 300) }
                return
            case .choice(let items):
                choices = items
                return
            case .jump(let label):
                jumps += 1
                if jumps > 10_000 {
                    diagnose(.error, "脚本跳转次数异常多，已停止（可能死循环）")
                    flash("脚本可能存在死循环，已停止")
                    return
                }
                if let idx = script.labels[label] { pc = idx }
            case .end:
                finish()
                return
            }
        }
        finish()
    }

    private func finish() {
        isFinished = true
        choices = []
        autoMode = false
        skipMode = false
    }

    // MARK: - 资源

    private func playBGM(_ file: String) {
        guard let assets else { return }
        guard let url = try? assets.fileURL(for: file) else {
            checkAsset(file, kind: "背景音乐")
            return
        }
        switch audio.playBGM(url: url, name: file) {
        case .playing, .alreadyPlaying:
            currentBGM = file
        case .unsupported(let ext):
            diagnose(.warning, "iOS 不支持 .\(ext) 音频，无法播放 BGM：\(file)（请转成 mp3 / m4a / wav）")
            flash("iOS 无法播放 .\(ext)：\(file)")
        case .failed(let reason):
            diagnose(.warning, "播放失败：\(file)（\(reason)）")
            flash("无法播放音乐：\(file)")
        }
    }

    private func playSE(_ file: String) {
        guard let assets else { return }
        guard let url = try? assets.fileURL(for: file) else {
            checkAsset(file, kind: "音效")
            return
        }
        switch audio.playSE(url: url) {
        case .playing, .alreadyPlaying:
            break
        case .unsupported(let ext):
            diagnose(.warning, "iOS 不支持 .\(ext) 音效：\(file)")
            flash("iOS 无法播放 .\(ext)：\(file)")
        case .failed(let reason):
            diagnose(.warning, "播放失败：\(file)（\(reason)）")
        }
    }

    private func checkAsset(_ file: String, kind: String) {
        guard let assets else { return }
        if assets.contains(file) { return }
        // hxv4 之类混淆命名的封包会大量命中这里，所以去重后只报一次
        guard warnedMissing.insert(file).inserted else { return }
        diagnose(.warning, "缺少\(kind)素材：\(file)")
        flash("缺少素材：\(file)")
    }

    func setBGMVolume(_ v: Float) {
        audio.bgmVolume = v
    }

    // MARK: - 存档

    private func makeSnapshot() -> VNSnapshot {
        VNSnapshot(pc: pc, background: background, bgm: currentBGM, sprites: sprites,
                   speaker: speaker, text: fullText, choices: choices, log: log)
    }

    private func makeSave() -> VNSave? {
        guard let info = info else { return nil }
        let preview = String(fullText.replacingOccurrences(of: "\n", with: " ").prefix(40))
        return VNSave(gameId: info.id, title: info.title, preview: preview,
                      timestamp: Date(), snapshot: makeSnapshot())
    }

    func slotSummaries() -> [Int: VNSave] {
        guard let info = info else { return [:] }
        return saves.slots(gameId: info.id)
    }

    func save(slot: Int) {
        guard let value = makeSave() else { return }
        do {
            try saves.save(value, slot: slot)
            flash("已存档（栏位 \(slot)）")
        } catch {
            flash(error.localizedDescription)
        }
    }

    private func autoSave() {
        guard let value = makeSave() else { return }
        try? saves.save(value, slot: 0)
    }

    func load(slot: Int) {
        guard let info = info else { return }
        guard let value = saves.load(gameId: info.id, slot: slot) else {
            flash("该栏位没有可用的存档")
            return
        }
        let s = value.snapshot
        guard let script = script, s.pc >= 0, s.pc <= script.commands.count else {
            flash("存档与当前脚本不匹配")
            return
        }
        pc = s.pc
        background = s.background
        sprites = s.sprites
        speaker = s.speaker
        fullText = s.text
        choices = s.choices
        log = s.log
        isFinished = false
        autoMode = false
        skipMode = false
        lineID += 1
        if let b = s.bgm {
            playBGM(b)
        } else {
            audio.stopBGM()
            currentBGM = nil
        }
        flash("已读档")
    }

    // MARK: - 诊断与提示

    /// 不开游戏、只做体检：挂载封包、解析脚本、把脚本引用到的素材逐个核对一遍。
    /// 这是排查"为什么打不开 / 为什么没声音没图"的主要入口。
    func inspect(_ game: VNGameInfo) -> [VNDiagnostic] {
        var out: [VNDiagnostic] = []
        out.append(VNDiagnostic(level: .info, text: "游戏：\(game.title)"))
        out.append(VNDiagnostic(level: .info, text: "目录：\(game.root.lastPathComponent)"))
        if let archive = game.archive {
            out.append(VNDiagnostic(level: .info, text: "封包：\(archive.lastPathComponent)"))
        } else {
            out.append(VNDiagnostic(level: .info, text: "素材形式：散装文件夹"))
        }

        do {
            var sources: [AssetSource] = []
            if let archiveURL = game.archive {
                let archive = try XP3Archive(url: archiveURL)
                sources.append(try XP3Source(archive: archive))
                out.append(VNDiagnostic(level: .info, text: "封包内 \(archive.count) 个文件"))
                for warning in archive.warnings {
                    out.append(VNDiagnostic(level: .warning, text: "封包 \(warning)"))
                }
            }
            sources.append(DirectorySource(root: game.root))
            let loader = AssetLoader(source: CompositeSource(sources))
            let parsed = try loadScript(game, loader: loader)

            out.append(VNDiagnostic(level: .info, text: "脚本：\(parsed.origin)"))
            out.append(VNDiagnostic(level: .info,
                                    text: "指令 \(parsed.commands.count) 条，标签 \(parsed.labels.count) 个，素材总数 \(loader.listFiles().count)"))
            for warning in parsed.warnings {
                out.append(VNDiagnostic(level: .warning, text: "脚本 \(warning)"))
            }

            var missing: [String] = []
            var seen = Set<String>()
            for command in parsed.commands {
                for file in VNRuntime.assetNames(in: command) where seen.insert(file).inserted {
                    if !loader.contains(file) { missing.append(file) }
                }
            }
            if missing.isEmpty {
                out.append(VNDiagnostic(level: .info, text: "脚本引用的素材都存在"))
            } else {
                for file in missing.prefix(30) {
                    out.append(VNDiagnostic(level: .warning, text: "缺少素材：\(file)"))
                }
                if missing.count > 30 {
                    out.append(VNDiagnostic(level: .warning, text: "……还有 \(missing.count - 30) 个缺失素材未列出"))
                }
            }
            let unsupported = missing.filter { VNRuntime.iosUnsupportedExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            for file in Set(unsupported).sorted().prefix(20) {
                let ext = (file as NSString).pathExtension.lowercased()
                out.append(VNDiagnostic(level: .error,
                                        text: "iOS 无法解码 .\(ext)：\(file)（需要先转码，详见使用说明）"))
            }
        } catch {
            out.append(VNDiagnostic(level: .error, text: "载入失败：\(error.localizedDescription)"))
        }
        return out
    }

    /// iOS 系统本身没有解码器的扩展名。
    static let iosUnsupportedExtensions: Set<String> = ["ogg", "oga", "opus", "tlg", "pimg", "eri", "mpg", "mpeg", "wmv", "avi", "swf"]

    static func assetNames(in command: VNCommand) -> [String] {
        switch command {
        case .bg(let file), .se(let file): return [file]
        case .bgm(let file): return file.map { [$0] } ?? []
        case .show(_, let file, _): return [file]
        case .label, .hide, .say, .choice, .jump, .end: return []
        }
    }

    private func diagnose(_ level: VNDiagnostic.Level, _ text: String) {
        guard diagnostics.count < maxDiagnostics else { return }
        if diagnostics.contains(where: { $0.text == text }) { return }
        diagnostics.append(VNDiagnostic(level: level, text: text))
    }

    private func flash(_ text: String) {
        message = text
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self.message == text { self.message = nil }
        }
    }
}
