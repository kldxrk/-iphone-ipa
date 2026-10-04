import Foundation

final class SaveManager {
    private let directory: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("VNPlayer/Saves", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func save(_ value: VNSave, slot: Int) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: directory.appendingPathComponent("slot\(slot).json"), options: .atomic)
    }

    func load(slot: Int) throws -> VNSave {
        let data = try Data(contentsOf: directory.appendingPathComponent("slot\(slot).json"))
        return try JSONDecoder().decode(VNSave.self, from: data)
    }
}
