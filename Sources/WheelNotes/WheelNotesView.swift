import SwiftUI
import WheelNotesCore

struct WheelNotesRootView: View {
    @Bindable var model: WheelNotesModel
    @Environment(\.colorScheme) private var colorScheme

    private var palette: NotesChromePalette {
        NotesChromePalette(colorScheme: colorScheme)
    }

    var body: some View {
        NavigationSplitView {
            workspaceSidebar
        } content: {
            noteList
        } detail: {
            noteDetail
        }
        .navigationSplitViewStyle(.balanced)
        .background {
            ZStack {
                palette.windowBackground
                LinearGradient(
                    colors: [palette.windowGlow.opacity(0.55), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .ignoresSafeArea()
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
                connectionStatus
            }
        }
        .task {
            await model.start()
        }
    }

    private var connectionStatus: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.isConnectedToWheel ? palette.statusOnline : palette.statusOffline)
                .frame(width: 8, height: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text(model.isConnectedToWheel ? "Connected to Wheel" : "Wheel offline")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.primaryText)

                Text("Wheel active: \(model.currentWheelWorkspaceName ?? "None")")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(palette.tertiaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(palette.statusFill)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(palette.statusBorder, lineWidth: 1)
                )
        )
    }

    private var workspaceSidebar: some View {
        paneChrome {
            List(selection: $model.selectedWorkspaceID) {
                ForEach(model.workspaces) { workspace in
                    let isSelected = model.selectedWorkspaceID == workspace.id

                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(color(for: workspace.color).opacity(isSelected ? 0.24 : 0.15))
                            .frame(width: 34, height: 34)
                            .overlay {
                                Image(systemName: workspace.icon)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(color(for: workspace.color))
                            }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(workspace.name)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(palette.primaryText)
                                .lineLimit(1)

                            if model.currentWheelWorkspaceID == workspace.id {
                                Text("Active in Wheel")
                                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                    .foregroundStyle(palette.accent)
                            }
                        }

                        Spacer(minLength: 8)

                        if model.currentWheelWorkspaceID == workspace.id {
                            Text("Wheel")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(palette.badgeText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(palette.badgeFill)
                                )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(isSelected ? palette.selectedRowFill : palette.rowFill)
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(
                                        isSelected ? palette.selectedRowBorder : palette.rowBorder,
                                        lineWidth: 1
                                    )
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .tag(Optional(workspace.id))
                    .listRowInsets(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
        .navigationTitle("Workspaces")
    }

    private var noteList: some View {
        paneChrome {
            List(selection: $model.selectedNoteID) {
                ForEach(model.notes) { note in
                    let isSelected = model.selectedNoteID == note.id

                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(note.displayTitle)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(palette.primaryText)
                                .lineLimit(1)

                            Spacer(minLength: 8)

                            Text(note.shortUpdatedText)
                                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                .foregroundStyle(isSelected ? palette.secondaryText : palette.tertiaryText)
                        }

                        Text(note.excerpt.isEmpty ? "Start writing." : note.excerpt)
                            .font(.system(size: 12.5, weight: .regular, design: .rounded))
                            .foregroundStyle(note.excerpt.isEmpty ? palette.tertiaryText : palette.secondaryText)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(isSelected ? palette.selectedRowFill : palette.rowFill)
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(
                                        isSelected ? palette.selectedRowBorder : palette.rowBorder,
                                        lineWidth: 1
                                    )
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .tag(Optional(note.id))
                    .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .overlay {
                if model.notes.isEmpty {
                    emptyState(
                        title: "No Notes",
                        systemImage: "note.text",
                        description: "Select a workspace and create a note."
                    )
                }
            }
        }
        .navigationTitle(model.selectedWorkspace?.name ?? "Notes")
    }

    @ViewBuilder
    private var noteDetail: some View {
        if let note = model.selectedNote {
            WheelNoteEditorPane(model: model, note: note)
                .navigationTitle(note.displayTitle)
                .padding(12)
        } else {
            paneChrome {
                emptyState(
                    title: "Select a Note",
                    systemImage: "square.and.pencil",
                    description: "Choose a note from the list or create a new one."
                )
            }
        }
    }

    private func paneChrome<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [palette.paneFillTop, palette.paneFillBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(palette.paneBorder, lineWidth: 1)
                )
                .shadow(color: palette.paneShadow, radius: 26, y: 14)

            content()
                .padding(10)
        }
        .padding(12)
    }

    private func emptyState(title: String, systemImage: String, description: String) -> some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text(description)
        )
        .foregroundStyle(palette.secondaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func color(for hex: String) -> Color {
        Color(hex: hex) ?? palette.accent
    }
}

private struct WheelNoteEditorPane: View {
    @Bindable var model: WheelNotesModel
    let note: NoteRecord

    @Environment(\.colorScheme) private var colorScheme
    @State private var editorBridge = NoteEditorBridge()

    private var palette: NotesChromePalette {
        NotesChromePalette(colorScheme: colorScheme)
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(note.displayTitle)
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                        .foregroundStyle(palette.primaryText)

                    HStack(spacing: 8) {
                        Label("Updated \(note.shortUpdatedText)", systemImage: "clock")
                        if let workspace = model.selectedWorkspace {
                            Label(workspace.name, systemImage: workspace.icon)
                        }
                    }
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(palette.secondaryText)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    Text(model.isConnectedToWheel ? "Live with Wheel" : "Working locally")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.badgeText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(model.isConnectedToWheel ? palette.badgeFill : palette.rowFill)
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(
                                            model.isConnectedToWheel ? palette.selectedRowBorder : palette.rowBorder,
                                            lineWidth: 1
                                        )
                                )
                        )

                    Text("A cleaner reading surface, with the note centered inside the canvas.")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(palette.tertiaryText)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 210, alignment: .trailing)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)

            ZStack {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [palette.editorCanvasTop, palette.editorCanvasBottom],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 34, style: .continuous)
                            .stroke(palette.editorCanvasBorder, lineWidth: 1)
                    )
                    .shadow(color: palette.paneShadow.opacity(0.75), radius: 34, y: 16)

                NoteEditorView(bridge: editorBridge)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                    .padding(14)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
        .background(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [palette.paneFillTop, palette.paneFillBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .stroke(palette.paneBorder, lineWidth: 1)
                )
        )
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

private struct NotesChromePalette {
    let windowBackground: Color
    let windowGlow: Color
    let paneFillTop: Color
    let paneFillBottom: Color
    let paneBorder: Color
    let paneShadow: Color
    let rowFill: Color
    let rowBorder: Color
    let selectedRowFill: Color
    let selectedRowBorder: Color
    let primaryText: Color
    let secondaryText: Color
    let tertiaryText: Color
    let accent: Color
    let badgeFill: Color
    let badgeText: Color
    let statusFill: Color
    let statusBorder: Color
    let statusOnline: Color
    let statusOffline: Color
    let editorCanvasTop: Color
    let editorCanvasBottom: Color
    let editorCanvasBorder: Color

    init(colorScheme: ColorScheme) {
        if colorScheme == .dark {
            windowBackground = Color(hex: "#111214") ?? .black
            windowGlow = Color(hex: "#2D3647") ?? .gray
            paneFillTop = Color(hex: "#242425") ?? .gray
            paneFillBottom = Color(hex: "#1A1A1B") ?? .black
            paneBorder = Color.white.opacity(0.08)
            paneShadow = Color.black.opacity(0.34)
            rowFill = Color.white.opacity(0.035)
            rowBorder = Color.white.opacity(0.055)
            selectedRowFill = Color(hex: "#35363A") ?? .gray
            selectedRowBorder = Color.white.opacity(0.11)
            primaryText = Color.white.opacity(0.95)
            secondaryText = Color.white.opacity(0.70)
            tertiaryText = Color.white.opacity(0.46)
            accent = Color(hex: "#8EC7FF") ?? .blue
            badgeFill = Color(hex: "#1E3446") ?? .blue
            badgeText = Color(hex: "#C9ECFF") ?? .white
            statusFill = Color.white.opacity(0.04)
            statusBorder = Color.white.opacity(0.08)
            statusOnline = Color(hex: "#61C48D") ?? .green
            statusOffline = Color(hex: "#FF9B55") ?? .orange
            editorCanvasTop = Color(hex: "#1B1D20") ?? .black
            editorCanvasBottom = Color(hex: "#161719") ?? .black
            editorCanvasBorder = Color.white.opacity(0.07)
        } else {
            windowBackground = Color(hex: "#F0EEE8") ?? .white
            windowGlow = Color(hex: "#FBF7F0") ?? .white
            paneFillTop = Color(hex: "#F8F6F0") ?? .white
            paneFillBottom = Color(hex: "#EFEBE4") ?? .white
            paneBorder = Color.black.opacity(0.08)
            paneShadow = Color.black.opacity(0.09)
            rowFill = Color.white.opacity(0.68)
            rowBorder = Color.black.opacity(0.06)
            selectedRowFill = Color.white.opacity(0.94)
            selectedRowBorder = Color.black.opacity(0.10)
            primaryText = Color(hex: "#1F232A") ?? .black
            secondaryText = Color(hex: "#4F5A68") ?? .gray
            tertiaryText = Color(hex: "#7D8793") ?? .gray
            accent = Color(hex: "#2E6DFF") ?? .blue
            badgeFill = Color(hex: "#DDECFB") ?? .blue
            badgeText = Color(hex: "#24547A") ?? .blue
            statusFill = Color.white.opacity(0.56)
            statusBorder = Color.black.opacity(0.06)
            statusOnline = Color(hex: "#4FA870") ?? .green
            statusOffline = Color(hex: "#D7823B") ?? .orange
            editorCanvasTop = Color(hex: "#F2EEE6") ?? .white
            editorCanvasBottom = Color(hex: "#ECE7DE") ?? .white
            editorCanvasBorder = Color.black.opacity(0.06)
        }
    }
}
