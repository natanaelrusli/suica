import AppKit
import SuicaCore

/// Asks for one or more folders, hidden ones included; empty when the panel is cancelled.
@MainActor func pickFolders() -> [String] {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    panel.showsHiddenFiles = true
    panel.prompt = Copy.addFoldersPrompt
    guard panel.runModal() == .OK else { return [] }
    return panel.urls.map(\.path)
}
