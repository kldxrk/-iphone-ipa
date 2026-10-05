import Foundation

/// 从一个文件夹里探测出可玩的游戏。
struct DetectedGame {
    let root: URL
    let archive: URL?
    let scriptPath: String
    let title: String?
    let warnings: [String]
}

/// 游戏目录相关的纯文件操作（不依赖主线程，可在后台任务里调用）。
enum GameStore {
    static var gamesDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Games", isDirectory: true)
    }

    /// App「导入」功能专用的目录：与用户自己用「文件」App 拷进 Games 的东西分开存放，
    /// 这样既能一眼分清来源，也能整体一键清空，不会误删自己整理好的游戏。
    static var importedDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ImportedGames", isDirectory: true)
    }

    static func prepare() {
        let fm = FileManager.default
        try? fm.createDirectory(at: gamesDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: importedDirectory, withIntermediateDirectories: true)
        let readme = gamesDirectory.appendingPathComponent("使用说明.txt")
        if !fm.fileExists(atPath: readme.path) {
            try? readmeText.write(to: readme, atomically: true, encoding: .utf8)
        }
    }

    /// 目录占用体积，用于「存储管理」显示。
    static func size(of directory: URL) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory,
                                             includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                                             options: [.skipsHiddenFiles]) else { return 0 }
        var total = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                  values.isDirectory != true, let fileSize = values.fileSize else { continue }
            total += fileSize
        }
        return total
    }

    static func remove(_ folder: URL, gameId: String) {
        try? FileManager.default.removeItem(at: folder)
        SaveManager().deleteAll(gameId: gameId)
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    /// 探测顺序：
    ///  1. 找脚本：文件夹自己的 `script.vns`，或一级子目录里的；
    ///  2. 找封包：优先与脚本同目录的 `.xp3`，其次是文件夹自己的，最后是任意一级子目录的；
    ///  3. 两者可以**同时存在**——外部 `script.vns` 用来驱动封包里的素材（覆盖包内脚本做调试）。
    ///
    /// `root` 取"脚本所在目录"（没有外部脚本时取封包所在目录），这样 `root/script.vns`
    /// 这种相对查找才是对的；脚本放在子目录里的游戏也不会像 1.2 早期那样打不开。
    static func detect(in folder: URL) -> (game: DetectedGame?, unsupportedReason: String?) {
        let fm = FileManager.default
        let subs = subdirectories(of: folder)

        func archives(in directory: URL) -> [URL] {
            let items = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles])) ?? []
            return items.filter { $0.pathExtension.lowercased() == "xp3" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        // 1) 脚本目录
        var scriptDirectory: URL?
        for candidate in [folder] + subs
        where fm.fileExists(atPath: candidate.appendingPathComponent("script.vns").path) {
            scriptDirectory = candidate
            break
        }

        // 2) 封包（按优先级收集，去重）
        var archiveCandidates: [URL] = []
        if let dir = scriptDirectory { archiveCandidates += archives(in: dir) }
        archiveCandidates += archives(in: folder)
        for sub in subs { archiveCandidates += archives(in: sub) }
        var seen = Set<String>()
        let archiveURL = archiveCandidates.first { seen.insert($0.resolvingSymlinksInPath().path).inserted }

        // 3) 纯目录游戏
        if scriptDirectory == nil, archiveURL == nil {
            return (nil, "没有 script.vns，也没有 .xp3 封包")
        }

        let root = scriptDirectory ?? archiveURL?.deletingLastPathComponent() ?? folder

        guard let archiveURL else {
            let scriptURL = root.appendingPathComponent("script.vns")
            return (DetectedGame(root: root, archive: nil, scriptPath: "script.vns",
                                 title: readTitle(from: scriptURL),
                                 warnings: []), nil)
        }

        // 4) 有封包：打开它挑脚本（外部脚本优先，只用于取标题）
        do {
            let archive = try XP3Archive(url: archiveURL)
            var warnings = archive.warnings
            let entry: XP3Archive.Entry?
            if scriptDirectory != nil {
                entry = nil                        // 外部脚本驱动，包内脚本只作后备
            } else {
                entry = chooseScript(in: archive)
                if entry == nil {
                    warnings.append("包内没有 .vns 脚本")
                }
            }

            let title: String?
            if scriptDirectory != nil {
                title = readTitle(from: root.appendingPathComponent("script.vns"))
            } else if let entry {
                title = (try? archive.data(for: entry))
                    .flatMap { ScriptText.decode($0) }
                    .flatMap { GameStore.title(in: $0) }
            } else {
                title = nil
            }

            // 既没有外部脚本、包里也找不到脚本 → 这个游戏没法玩，但要说明"里面到底是什么"，
            // 否则用户只看到一句"没有脚本"，无法判断这包是原版 KiriKiri 游戏还是别的什么。
            if entry == nil, scriptDirectory == nil {
                return (nil, "\(archiveURL.lastPathComponent)：包内没有 .vns 脚本（\(archive.count) 个文件：\(inventory(archive))）")
            }

            let scriptPath = scriptDirectory != nil ? "script.vns" : (entry?.name ?? "script.vns")
            return (DetectedGame(root: root, archive: archiveURL, scriptPath: scriptPath,
                                 title: title, warnings: warnings), nil)
        } catch {
            // 封包打不开，但如果旁边有可用的外部脚本，仍然当目录游戏跑
            if scriptDirectory != nil {
                return (DetectedGame(root: root, archive: nil, scriptPath: "script.vns",
                                     title: readTitle(from: root.appendingPathComponent("script.vns")),
                                     warnings: ["封包 \(archiveURL.lastPathComponent) 无法读取：\(error.localizedDescription)"]),
                        nil)
            }
            return (nil, "\(archiveURL.lastPathComponent)：\(error.localizedDescription)")
        }
    }

    /// 按与 detect() 相同的优先级找出封包，供兼容性体检使用。
    static func archiveCandidate(in folder: URL) -> URL? {
        let subs = subdirectories(of: folder)

        func archives(in directory: URL) -> [URL] {
            let items = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            return items.filter { $0.pathExtension.lowercased() == "xp3" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        var candidates: [URL] = []
        // 注意括号：`.first` 的优先级高于 `+`，写成 `[folder] + subs.first(...)` 会被解析成
        // `[URL] + URL?`，直接编译失败（这里踩过一次）。
        if let scriptDir = ([folder] + subs)
            .first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("script.vns").path) }) {
            candidates += archives(in: scriptDir)
        }
        candidates += archives(in: folder)
        for sub in subs { candidates += archives(in: sub) }
        var seen = Set<String>()
        return candidates.first { seen.insert($0.resolvingSymlinksInPath().path).inserted }
    }

    /// 包内没有我们的脚本时，给一句话内容清单（按扩展名统计），
    /// 让用户一眼看出这是"原版 KiriKiri 游戏"还是"只是没放脚本"。
    static func inventory(_ archive: XP3Archive) -> String {
        var counts: [String: Int] = [:]
        for entry in archive.entries {
            let ext = (entry.name as NSString).pathExtension.lowercased()
            counts[ext.isEmpty ? "无扩展名" : "." + ext, default: 0] += 1
        }
        let top = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(6)
        let list = top.map { "\($0.key)×\($0.value)" }.joined(separator: "、")
        let scripts = archive.entries.filter {
            let ext = ($0.name as NSString).pathExtension.lowercased()
            return ext == "ks" || ext == "tjs"
        }.count
        if scripts > 0 {
            return list + "；其中 \(scripts) 个 .ks/.tjs——看起来是原版 KiriKiri 脚本，需要 TJS2/KAG3 引擎才能执行"
        }
        return list
    }

    /// 包内优先找 script.vns，其次任意 .vns（取路径最短的，避免命中备份文件）。
    static func chooseScript(in archive: XP3Archive) -> XP3Archive.Entry? {
        if let exact = archive.entry(named: "script.vns") { return exact }
        let candidates = archive.entries
            .filter { $0.name.lowercased().hasSuffix(".vns") }
            .sorted { ($0.name.count, $0.name) < ($1.name.count, $1.name) }
        return candidates.first
    }

    static func subdirectories(of url: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { isDirectory($0) }
    }

    static func readTitle(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return ScriptText.decode(data).flatMap(title(in:))
    }

    /// 在脚本文本里找第一行 `@title`。
    static func title(in source: String) -> String? {
        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("@title ") {
                let value = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    static func importFolder(_ src: URL) throws {
        let fm = FileManager.default
        prepare()
        // 导入的东西一律进 ImportedGames，不跟用户自己拷进 Games 的混在一起
        let dest = importedDirectory.appendingPathComponent(src.lastPathComponent, isDirectory: true)
        if src.resolvingSymlinksInPath().path == dest.resolvingSymlinksInPath().path { return }
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: src, to: dest)
    }

    static func sanitize(_ name: String) -> String {
        String(name.map { ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "_" })
    }

    /// 稳定的游戏 ID。
    /// sanitize 是有损的："My Game" 与 "My_Game" 会得到同一个名字，于是两个游戏共用存档文件，
    /// 删掉一个还会把另一个的存档一起清掉。所以再混入整个路径的稳定哈希。
    static func stableID(for folder: URL) -> String {
        sanitize(folder.lastPathComponent) + "-" + folder.stablePathHash
    }

    static let readmeText = """
    VNPlayer 游戏文件夹说明
    =======================
    把一个游戏做成一个文件夹，放进本目录（Games）。支持两种形式：

    【一】散装素材
      文件夹里至少要有 script.vns，图片、音乐放在同一个文件夹里（可以有子文件夹，
      脚本里写相对路径）。

    【二】KiriKiri 封包（.xp3）
      把 data.xp3 这类封包放进文件夹即可。VNPlayer 会读取封包的索引、按需解压其中的
      图片/音乐，并用包内（或旁边）的 script.vns 驱动播放。
      注意：只支持**未加密**的封包；被标记为受保护（info.flags 的 bit31）的条目无法解出，
      因为密钥不在文件格式里。

    script.vns 是文本，每行一条（UTF-8 / GBK / 带 BOM 的 UTF-16 都能识别）：

    @title 游戏名            设置标题
    @bg 背景.jpg             切换背景图
    @bgm 音乐.mp3            循环播放背景音乐（@bgm stop 停止）
    @se 音效.wav             播放一次音效
    @show 标识 立绘.png 位置   显示立绘，位置 left / center / right
    @hide 标识               隐藏立绘（@hide all 隐藏全部）
    @label 标签名            定义跳转标签
    @jump 标签名             跳转
    @choice 选项A=标签1 选项B=标签2    弹出选项（文字含空格时用英文引号包住）
    @end                     结束
    [名字] 台词              带角色名的对白
    普通一行文字             旁白
    # 开头的行是注释

    写错的行不会让游戏打不开，而是记进"诊断"里，可以在游戏库里点开查看。

    【iOS 系统本身的限制】以下 KiriKiri 常用格式需要先转换：
      .ogg 音乐  → 转成 mp3 / m4a / wav（AVFoundation 不支持 Ogg Vorbis）
      .tlg 图片  → 转成 png / jpg（KiriKiri 私有格式，系统没有解码器）
      .mpg/.wmv 视频 → 转成 H.264 的 mp4
    另外 VNPlayer 不会运行 Windows 的 EXE / DLL，也不执行 TJS2 脚本。
    """
}

@MainActor
final class GameLibrary: ObservableObject {
    /// 认不出来但值得给用户一个"为什么"的条目：保留文件夹 URL，这样才能对它跑兼容性体检、也才能删掉。
    struct UnsupportedGame: Identifiable {
        let id = UUID()
        let name: String
        let folder: URL
        let reason: String
        let isImported: Bool
    }

    @Published private(set) var games: [VNGameInfo] = []
    @Published private(set) var unsupported: [UnsupportedGame] = []
    @Published private(set) var isImporting = false
    @Published private(set) var message: String?
    /// 「存储管理」用的统计
    @Published private(set) var importedBytes = 0
    @Published private(set) var gamesBytes = 0

    init() {
        GameStore.prepare()
        refresh()
    }

    func refresh() {
        var list: [VNGameInfo] = []
        if let demo = Bundle.main.url(forResource: "Demo", withExtension: nil) {
            list.append(VNGameInfo(id: "builtin-demo", title: "示例游戏（内置）", root: demo,
                                   folder: nil, isBuiltIn: true))
        }
        // 内置的 XP3 自检：素材全部装在 data.xp3 里，用来验证封包链路（索引 / 段解压 / 查找 / 音频物化）。
        // 由 tools/make_test_game.py 生成。
        if let test = Bundle.main.url(forResource: "TestXP3", withExtension: nil) {
            let archive = test.appendingPathComponent("data.xp3")
            if FileManager.default.fileExists(atPath: archive.path) {
                list.append(VNGameInfo(id: "builtin-xp3", title: "XP3 自检示例（内置）",
                                       root: test, archive: archive, scriptPath: "script.vns",
                                       folder: nil, isBuiltIn: true))
            }
        }
        var bad: [UnsupportedGame] = []

        // 两个目录都扫：ImportedGames（App 导入的）与 Games（用户自己放进去的）
        func scan(_ directory: URL, isImported: Bool) {
            let items = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            for d in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard GameStore.isDirectory(d) else { continue }
                let detected = GameStore.detect(in: d)
                guard let game = detected.game else {
                    bad.append(UnsupportedGame(name: d.lastPathComponent, folder: d,
                                               reason: detected.unsupportedReason ?? "无法识别",
                                               isImported: isImported))
                    continue
                }
                list.append(VNGameInfo(id: "user-" + GameStore.stableID(for: d),
                                       title: game.title ?? d.lastPathComponent,
                                       root: game.root,
                                       archive: game.archive,
                                       scriptPath: game.scriptPath,
                                       folder: d,
                                       isBuiltIn: false,
                                       isImported: isImported))
            }
        }
        scan(GameStore.importedDirectory, isImported: true)
        scan(GameStore.gamesDirectory, isImported: false)

        games = list
        unsupported = bad

        // 体积统计要在后台算：库大的时候全目录枚举会卡住界面
        Task.detached(priority: .utility) {
            let imported = GameStore.size(of: GameStore.importedDirectory)
            let mine = GameStore.size(of: GameStore.gamesDirectory)
            await MainActor.run {
                self.importedBytes = imported
                self.gamesBytes = mine
            }
        }
    }

    func importFolder(_ url: URL) {
        isImporting = true
        Task.detached(priority: .userInitiated) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            var text = "已导入：\(url.lastPathComponent)"
            do {
                try GameStore.importFolder(url)
            } catch {
                text = "导入失败：\(error.localizedDescription)"
            }
            await MainActor.run {
                self.isImporting = false
                self.report(text)
                self.refresh()
            }
        }
    }

    func report(_ text: String) {
        message = text
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if self.message == text { self.message = nil }
        }
    }

    func delete(_ game: VNGameInfo) {
        guard !game.isBuiltIn, let folder = game.folder else { return }
        GameStore.remove(folder, gameId: game.id)
        report("已删除：\(game.title)")
        refresh()
    }

    /// 删掉一个「认不出来」的条目。1.2 之前这里完全没有入口——导入错了就永远清不掉。
    func delete(_ item: UnsupportedGame) {
        GameStore.remove(item.folder, gameId: "user-" + GameStore.stableID(for: item.folder))
        report("已删除：\(item.name)")
        refresh()
    }

    /// 一键清空所有通过「导入」拷进来的东西。用户自己放进 Games 的不受影响。
    func clearImported() {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: GameStore.importedDirectory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        for item in items {
            GameStore.remove(item, gameId: "user-" + GameStore.stableID(for: item))
        }
        report("已清空导入的数据（\(items.count) 项）")
        refresh()
    }
}
