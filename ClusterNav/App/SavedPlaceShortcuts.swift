import AppIntents
import Observation

@MainActor
@Observable
final class SavedPlaceShortcutHandoff {
    static let shared = SavedPlaceShortcutHandoff()

    private(set) var pending: [AppModel.Shortcut] = []

    func enqueue(_ shortcut: AppModel.Shortcut) {
        pending.append(shortcut)
    }

    func takeNext() -> AppModel.Shortcut? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    func consumeIfActive(_ active: Bool, model: AppModel) -> [String] {
        guard active, !pending.isEmpty else { return [] }
        model.foregroundSafetyCheck()
        var messages: [String] = []
        while let shortcut = takeNext() {
            if let message = model.previewSavedPlace(shortcut) {
                messages.append(message)
            }
        }
        return messages
    }
}

struct PreviewHomeIntent: AppIntent {
    static let title: LocalizedStringResource = "Preview route home"
    static let description = IntentDescription("Open a route preview to your saved Home. Starting the ride requires a separate tap.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        SavedPlaceShortcutHandoff.shared.enqueue(.home)
        return .result()
    }
}

struct PreviewWorkIntent: AppIntent {
    static let title: LocalizedStringResource = "Preview route to work"
    static let description = IntentDescription("Open a route preview to your saved Work. Starting the ride requires a separate tap.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        SavedPlaceShortcutHandoff.shared.enqueue(.work)
        return .result()
    }
}

struct SavedPlaceAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PreviewHomeIntent(), phrases: [
            "Preview my route home in \(.applicationName)",
            "Show my route home in \(.applicationName)"
        ], shortTitle: "Preview Home", systemImageName: "house.fill")
        AppShortcut(intent: PreviewWorkIntent(), phrases: [
            "Preview my route to work in \(.applicationName)",
            "Show my route to work in \(.applicationName)"
        ], shortTitle: "Preview Work", systemImageName: "briefcase.fill")
    }
}
