import SwiftUI
import WheelNotesCore

struct WheelNotesRootView: View {
    @Bindable var model: WheelNotesModel

    var body: some View {
        NavigationSplitView {
            workspaceSidebar
        } content: {
            noteList
        } detail: {
            noteDetail
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button(action: model.createNoteFromUI) {
                    Label("New Note", systemImage: "square.and.pencil")
                }

                if model.selectedNote != nil {
                    Button(role: .destructive, action: model.deleteSelectedNote) {
                        Label("Delete Note", systemImage: "trash")
                    }
                }
            }

            ToolbarItem(placement: .automatic) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(model.isConnectedToWheel ? "Connected to Wheel" : "Wheel offline")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(model.isConnectedToWheel ? Color.secondary : Color.orange)

                    if let current = model.currentWheelWorkspaceName {
                        Text("Wheel active: \(current)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task {
            await model.start()
        }
    }

    private var workspaceSidebar: some View {
        List(selection: $model.selectedWorkspaceID) {
            ForEach(model.workspaces) { workspace in
                HStack(spacing: 10) {
                    Image(systemName: workspace.icon)
                        .foregroundStyle(color(for: workspace.color))
                        .frame(width: 18)
                    Text(workspace.name)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if model.currentWheelWorkspaceID == workspace.id {
                        Text("Wheel")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.blue.opacity(0.12)))
                    }
                }
                .tag(Optional(workspace.id))
            }
        }
        .navigationTitle("Workspaces")
    }

    private var noteList: some View {
        List(selection: $model.selectedNoteID) {
            ForEach(model.notes) { note in
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(note.excerpt.isEmpty ? "Start writing." : note.excerpt)
                        .font(.system(size: 12))
                        .foregroundStyle(note.excerpt.isEmpty ? .tertiary : .secondary)
                        .lineLimit(2)
                    Text(note.shortUpdatedText)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
                .tag(Optional(note.id))
            }
        }
        .navigationTitle(model.selectedWorkspace?.name ?? "Notes")
        .overlay {
            if model.notes.isEmpty {
                ContentUnavailableView(
                    "No Notes",
                    systemImage: "note.text",
                    description: Text("Select a workspace and create a note.")
                )
            }
        }
    }

    @ViewBuilder
    private var noteDetail: some View {
        if let note = model.selectedNote {
            WheelNoteEditorPane(model: model, note: note)
                .navigationTitle(note.displayTitle)
        } else {
            ContentUnavailableView(
                "Select a Note",
                systemImage: "square.and.pencil",
                description: Text("Choose a note from the list or create a new one.")
            )
        }
    }

    private func color(for hex: String) -> Color {
        Color(hex: hex) ?? .blue
    }
}

private struct WheelNoteEditorPane: View {
    @Bindable var model: WheelNotesModel
    let note: NoteRecord

    @State private var editorBridge = NoteEditorBridge()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(note.displayTitle)
                        .font(.system(size: 15, weight: .semibold))
                    Text("Updated \(note.shortUpdatedText)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()

            NoteEditorView(bridge: editorBridge)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear(perform: configureBridge)
        .onAppear {
            syncEditor(with: note, requestFocus: true)
        }
        .onChange(of: note.id) { _, _ in
            syncEditor(with: note, requestFocus: true)
        }
        .onChange(of: note.updatedAt) { _, _ in
            syncEditor(with: note)
        }
    }

    private func configureBridge() {
        editorBridge.onReady = {
            syncEditor(with: model.selectedNote ?? note, force: true, requestFocus: true)
        }
        editorBridge.onDocumentChanged = { document in
            model.updateSelectedNoteDocument(document)
        }
        editorBridge.onEditorError = { _ in }
    }

    private func syncEditor(with note: NoteRecord, force: Bool = false, requestFocus: Bool = false) {
        editorBridge.activate(noteID: note.id)
        editorBridge.loadDocumentIfNeeded(note.document, force: force)

        if requestFocus {
            editorBridge.focusEditor()
        }
    }
}
