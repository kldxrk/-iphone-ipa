import Foundation

struct VNGame: Codable, Identifiable {
    let id: String
    let title: String
    let scenes: [VNScene]
}

struct VNScene: Codable, Identifiable {
    let id: String
    let background: String?
    let speaker: String?
    let text: String
}

struct VNSave: Codable {
    let sceneIndex: Int
    let timestamp: Date
}

enum VNRuntimeError: Error {
    case gameNotFound
    case invalidScene
    case unsupportedArchive
}
