import Foundation

/// The item provider a folder / shelf popup cell hands to a real file drag.
///
/// Registers the file URL only — the shape a Finder drag has — so the receiver works on the file
/// itself. Never `NSItemProvider(contentsOf:)`: it registers the content type first
/// (`public.zip-archive`, `public.plain-text`, …) with no name, and Finder / mail clients take that
/// data copy and name it after the type ("Zip归档.zip").
///
/// Never set `suggestedName` either: SwiftUI then copies the file into
/// `~/Library/Caches/com.apple.SwiftUI.Drag-<UUID>/` and puts **the copy's** URL on the drag
/// pasteboard, so every receiver — the Trash chip, a pinned folder, the shelf, Finder — acts on
/// the copy and the user's file stays where it was.
enum FileDragItemProvider {
    /// Marks a drag that started on a folder popup cell, so the popup can tell its own items
    /// being reordered from files dragged in from elsewhere. Visible to this process only, after
    /// the URL, so no other app ever sees it.
    static let folderReorderType = "com.caye.macosdockcc.v2.folder-reorder"

    static func make(for url: URL, marksFolderReorder: Bool = false) -> NSItemProvider {
        let provider = NSItemProvider(object: url as NSURL)
        if marksFolderReorder {
            provider.registerDataRepresentation(forTypeIdentifier: folderReorderType, visibility: .ownProcess) { done in
                done(Data(url.path.utf8), nil)
                return nil
            }
        }
        return provider
    }
}
