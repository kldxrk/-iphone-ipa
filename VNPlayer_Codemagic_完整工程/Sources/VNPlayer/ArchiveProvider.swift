import Foundation

protocol ArchiveProvider {
    func canOpen(url: URL) -> Bool
    func listFiles(url: URL) throws -> [String]
    func readFile(url: URL, path: String) throws -> Data
}

final class DirectoryProvider: ArchiveProvider {
    func canOpen(url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    func listFiles(url: URL) throws -> [String] {
        let base = url.standardizedFileURL
        let e = FileManager.default.enumerator(at: base)
        var result: [String] = []
        while let item = e?.nextObject() as? URL {
            result.append(item.path.replacingOccurrences(of: base.path + "/", with: ""))
        }
        return result
    }

    func readFile(url: URL, path: String) throws -> Data {
        try Data(contentsOf: url.appendingPathComponent(path))
    }
}

// 占位：后续依据公开格式规范实现 PAC。
final class PACProvider: ArchiveProvider {
    func canOpen(url: URL) -> Bool { url.pathExtension.lowercased() == "pac" }
    func listFiles(url: URL) throws -> [String] { throw VNRuntimeError.unsupportedArchive }
    func readFile(url: URL, path: String) throws -> Data { throw VNRuntimeError.unsupportedArchive }
}

// 占位：后续依据公开格式规范实现 XP3。
final class XP3Provider: ArchiveProvider {
    func canOpen(url: URL) -> Bool { url.pathExtension.lowercased() == "xp3" }
    func listFiles(url: URL) throws -> [String] { throw VNRuntimeError.unsupportedArchive }
    func readFile(url: URL, path: String) throws -> Data { throw VNRuntimeError.unsupportedArchive }
}
