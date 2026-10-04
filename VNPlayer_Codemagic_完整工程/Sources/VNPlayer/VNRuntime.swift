import Foundation
import SwiftUI

@MainActor
final class VNRuntime: ObservableObject {
    @Published private(set) var game: VNGame?
    @Published private(set) var sceneIndex = 0

    private let saves = SaveManager()

    var currentScene: VNScene? {
        guard let game, game.scenes.indices.contains(sceneIndex) else { return nil }
        return game.scenes[sceneIndex]
    }

    func loadDemo() {
        guard let url = Bundle.main.url(forResource: "demo", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let game = try? JSONDecoder().decode(VNGame.self, from: data) else { return }
        self.game = game
        sceneIndex = 0
    }

    func next() {
        guard let game, sceneIndex + 1 < game.scenes.count else { return }
        sceneIndex += 1
    }

    func previous() {
        if sceneIndex > 0 { sceneIndex -= 1 }
    }

    func save(slot: Int) {
        try? saves.save(VNSave(sceneIndex: sceneIndex, timestamp: Date()), slot: slot)
    }

    func load(slot: Int) {
        if let value = try? saves.load(slot: slot) { sceneIndex = value.sceneIndex }
    }
}
