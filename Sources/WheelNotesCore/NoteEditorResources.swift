import Foundation

public enum NoteEditorResources {
    public static func editorDirectoryURL() -> URL? {
        editorHTMLURL()?.deletingLastPathComponent()
    }

    public static func editorHTMLURL() -> URL? {
        Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "NoteEditor")
    }
}
