import Foundation
import Observation

@MainActor
@Observable
final class TransferCenter {
    static let shared = TransferCenter()

    struct Item: Identifiable {
        let id = UUID().uuidString
        let direction: Direction
        let objectID: String
        let name: String
        var progress: Double = 0
        var statusText: String = "Starting…"
        var state: State = .active

        enum Direction { case upload, download }
        enum State { case active, complete, failed }
    }

    private(set) var items: [Item] = []

    func begin(_ direction: Item.Direction, objectID: String, name: String) -> String {
        let item = Item(direction: direction, objectID: objectID, name: name)
        items.insert(item, at: 0)
        if items.count > 100 { items.removeLast() }
        return item.id
    }

    func update(_ id: String, progress: Double, text: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].progress = progress
        items[i].statusText = text
    }

    func finish(_ id: String, success: Bool, error: String? = nil) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].state = success ? .complete : .failed
        items[i].progress = success ? 1 : items[i].progress
        items[i].statusText = success ? "Complete" : (error ?? "Failed")
    }

    func clearFinished() {
        items.removeAll { $0.state != .active }
    }
}
