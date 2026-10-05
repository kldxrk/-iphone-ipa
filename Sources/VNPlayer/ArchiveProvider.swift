import Foundation
import UIKit
import ImageIO

/// 素材来源。
///
/// 一个游戏可能把素材散在文件夹里，也可能全塞在一个 `.xp3` 里，所以取素材统一走这层抽象，
/// 上层（AssetLoader / VNRuntime）不关心素材到底从哪来。
///
/// 两类读取路径：
///  * `data(for:)` —— 图片走这条，直接进内存交给 ImageIO 降采样，不落盘；
///  * `fileURL(for:)` —— 音频走这条，因为 AVFoundation 只接受 URL。
///    封包里的音频会先物化到缓存目录，重复播放时直接复用。
protocol AssetSource: AnyObject {
    var sourceDescription: String { get }
    var warnings: [String] { get }
    func listFiles() -> [String]
    func contains(_ path: String) -> Bool
    func data(for path: String) throws -> Data
    func fileURL(for path: String) throws -> URL
}

// MARK: - 目录

final class DirectorySource: AssetSource {
    let root: URL

    init(root: URL) {
        self.root = root.resolvingSymlinksInPath()
    }

    var sourceDescription: String { "文件夹 \(root.lastPathComponent)" }
    var warnings: [String] { [] }

    /// 解析游戏目录内的相对路径；越出游戏目录或文件不存在时返回 nil。
    func resolve(_ path: String) -> URL? {
        let target = root.appendingPathComponent(path).resolvingSymlinksInPath()
        let base = root.pathComponents
        let comps = target.pathComponents
        guard comps.count > base.count, Array(comps.prefix(base.count)) == base else { return nil }
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        return target
    }

    func listFiles() -> [String] {
        let base = root
        let baseCount = base.pathComponents.count
        guard let enumerator = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [String] = []
        for case let item as URL in enumerator {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { continue }
            let comps = item.resolvingSymlinksInPath().pathComponents
            result.append(comps.dropFirst(baseCount).joined(separator: "/"))
        }
        return result.sorted()
    }

    func contains(_ path: String) -> Bool { resolve(path) != nil }

    func data(for path: String) throws -> Data {
        guard let url = resolve(path) else { throw VNRuntimeError.invalidPath }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    func fileURL(for path: String) throws -> URL {
        guard let url = resolve(path) else { throw VNRuntimeError.invalidPath }
        return url
    }
}

// MARK: - XP3 封包

final class XP3Source: AssetSource {
    let archive: XP3Archive
    private let cacheDirectory: URL

    init(archive: XP3Archive) throws {
        self.archive = archive
        XP3Source.pruneCacheIfNeeded()
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        // 缓存键不能用 hashValue（每次启动都变）。文件名 + 体积 + 修改时间还不够：
        // 有些分发工具会给所有文件盖同一个时间戳（精确到秒），两个不同的归档就可能撞在一起，
        // 于是同名素材会串到另一个包里。再把归档的绝对路径哈希混进来。
        let stamp = (try? archive.url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate?.timeIntervalSince1970) ?? 0
        let key = "\(archive.url.lastPathComponent)-\(archive.fileSize)-\(Int(stamp))-\(archive.url.stablePathHash)"
            .sanitizedFileName
        cacheDirectory = base.appendingPathComponent("VNPlayerAssets/\(key)", isDirectory: true)
    }

    /// 物化出来的音频放在 Caches 里，从不清会无限增长。每次启动清理一次过期目录就够了。
    private static var didPrune = false

    private static func pruneCacheIfNeeded() {
        guard !didPrune else { return }
        didPrune = true
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VNPlayerAssets", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        for item in items {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            if modified < cutoff { try? FileManager.default.removeItem(at: item) }
        }
    }

    var sourceDescription: String { "\(archive.url.lastPathComponent)（\(archive.count) 个文件）" }

    var warnings: [String] { archive.warnings }

    func listFiles() -> [String] { archive.listFiles() }

    func contains(_ path: String) -> Bool { archive.entry(named: path) != nil }

    func data(for path: String) throws -> Data { try archive.data(named: path) }

    /// 把封包内的文件写到缓存目录，返回真实 URL 给 AVFoundation 用。
    func fileURL(for path: String) throws -> URL {
        let relative = path.replacingOccurrences(of: "\\", with: "/").sanitizedRelativePath
        let target = cacheDirectory.appendingPathComponent(relative)

        // 缓存命中就直接返回：不要为了"比一下大小"把整段音频再解压一遍，那样缓存等于白做。
        // 缓存键里已包含归档体积与修改时间，归档变了就会换目录。
        if let attributes = try? FileManager.default.attributesOfItem(atPath: target.path),
           let size = (attributes[.size] as? NSNumber)?.intValue, size > 0 {
            return target
        }

        let data = try archive.data(named: path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        return target
    }
}

// MARK: - 组合

/// 按传入顺序查找：**第一个**命中的来源胜出。
/// （VNRuntime 传进来的是「目录 → 封包」，所以放在 data.xp3 旁边的同名文件可以覆盖包内素材。）
final class CompositeSource: AssetSource {
    let sources: [AssetSource]

    init(_ sources: [AssetSource]) {
        self.sources = sources
    }

    var sourceDescription: String {
        sources.map(\.sourceDescription).joined(separator: " + ")
    }

    var warnings: [String] { sources.flatMap(\.warnings) }

    func listFiles() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for source in sources {
            for file in source.listFiles() where seen.insert(file.lowercased()).inserted {
                result.append(file)
            }
        }
        return result.sorted()
    }

    private func target(for path: String) -> AssetSource? {
        sources.first { $0.contains(path) }
    }

    func contains(_ path: String) -> Bool { target(for: path) != nil }

    func data(for path: String) throws -> Data {
        guard let source = target(for: path) else {
            throw VNRuntimeError.archiveDamaged("找不到素材 \(path)")
        }
        return try source.data(for: path)
    }

    func fileURL(for path: String) throws -> URL {
        guard let source = target(for: path) else {
            throw VNRuntimeError.archiveDamaged("找不到素材 \(path)")
        }
        return try source.fileURL(for: path)
    }
}

// MARK: - 小工具

extension URL {
    /// 稳定的短哈希（FNV-1a）。
    /// **不能**用 Swift 的 `hashValue`：它每次进程启动都会变，拿它做缓存键等于每次重启都换目录。
    var stablePathHash: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in standardizedFileURL.path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash % 0xFFFFFFF, radix: 16)
    }
}

extension String {
    var sanitizedFileName: String {
        String(map { ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") ? $0 : "_" })
    }

    /// 归一化相对路径并保证不会写出缓存目录（去掉 `..`、绝对路径前缀）。
    var sanitizedRelativePath: String {
        let parts = split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
        let safe = parts.filter { $0 != ".." }.map { $0.sanitizedFileName }
        return safe.isEmpty ? "unnamed" : safe.joined(separator: "/")
    }
}
