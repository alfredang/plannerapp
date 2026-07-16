import SwiftUI
import SwiftData

/// Wires the window's `UndoManager` into the SwiftData context so every model change —
/// add, edit, delete, check-off, drag-rearrange — is undoable/redoable: ⌘Z / ⇧⌘Z
/// (Edit ▸ Undo) on macOS, the Undo toolbar button on iOS. Works alongside CloudKit
/// mirroring: an undo is just another local change, which syncs like any other.
struct ModelUndoSupport: ViewModifier {
    @Environment(\.undoManager) private var undoManager
    @Environment(\.modelContext) private var context

    func body(content: Content) -> some View {
        content
            .onAppear { context.undoManager = undoManager }
            .onChange(of: undoManager.map(ObjectIdentifier.init)) {
                context.undoManager = undoManager
            }
    }
}

extension View {
    /// Enable system undo/redo for all SwiftData changes made in this window.
    func modelUndoSupport() -> some View { modifier(ModelUndoSupport()) }
}
