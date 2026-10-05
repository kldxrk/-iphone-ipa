import Foundation

final class SaveManager {
    /// 手动存档栏位 1...slotCount；栏位 0 是自动存档。
    static let slotCount = 8

    private let directory: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("VNPlayer/Saves", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(gameId: String, slot: Int) -> URL {
        let safe = String(gameId.map { ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "_" })
        return directory.appendingPathComponent("\(safe)_slot\(slot).json")
    }

    func save(_ value: VNSave, slot: Int) throws {
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: fileURL(gameId: value.gameId, slot: slot), options: .atomic)
        } catch {
            throw VNRuntimeError.saveFailed(error.localizedDescription)
        }
    }

    func load(gameId: String, slot: Int) -> VNSave? {
        guard let data = try? Data(contentsOf: fileURL(gameId: gameId, slot: slot)),
              let value = try? JSONDecoder().decode(VNSave.self, from: data),
              value.gameId == gameId else { return nil }
        return value
    }

    func slots(gameId: String) -> [Int: VNSave] {
        var result: [Int: VNSave] = [:]
        for n in 0...SaveManager.slotCount {
            if let s = load(gameId: gameId, slot: n) { result[n] = s }
        }
        return result
    }

    /// 删除某个游戏的全部存档（删除游戏时一并清理，避免残留占空间）。
    func deleteAll(gameId: String) {
        for n in 0...SaveManager.slotCount {
            try? FileManager.default.removeItem(at: fileURL(gameId: gameId, slot: n))
        }
    }
}
