import SwiftUI

/// Tab bar button for editor sync. Left-click toggles sync on/off.
/// Right-click shows a picker to choose the target editor.
///
/// Shortcuts:
/// - ⌘E        → Toggle sync on/off (shows picker if first time)
/// - ⌘E, 1-9   → Pick editor by number (opens popover, press number)
struct EditorSyncTitlebarButton: View {
    /// When nil, uses tab-bar-native styling (12pt icon, no frame constraints).
    let config: TitlebarControlsStyleConfig?
    @ObservedObject private var editorSync = EditorSyncController.shared
    @State private var isHovering = false
    @State private var showingPicker = false

    private var availableEditors: [TerminalDirectoryOpenTarget] {
        EditorSyncController.availableEditors
    }

    private var iconSize: CGFloat { config?.iconSize ?? 12 }
    private var buttonSize: CGFloat? { config?.buttonSize }

    var body: some View {
        let button = Button {
            if editorSync.isEnabled {
                editorSync.isEnabled = false
            } else if availableEditors.isEmpty {
                // No editors installed
            } else {
                showingPicker = true
            }
        } label: {
            ZStack {
                Image(systemName: editorSync.isEnabled ? "curlybraces.square.fill" : "curlybraces.square")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(editorSync.isEnabled ? AnyShapeStyle(cmuxAccentColor()) : AnyShapeStyle(.primary))
                    .frame(width: buttonSize, height: buttonSize)

                if editorSync.isEnabled {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 5, height: 5)
                        .offset(
                            x: (buttonSize ?? 20) / 2 - 4,
                            y: -((buttonSize ?? 20) / 2 - 4)
                        )
                }
            }
        }
        .buttonStyle(config != nil ? .plain : .plain)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
            editorPickerPopover
        }
        .contextMenu {
            editorContextMenu
        }
        .accessibilityIdentifier("titlebarControl.editorSync")
        .accessibilityLabel("Editor Sync")
        .help(editorSync.isEnabled
            ? "Editor sync: \(editorDisplayName(editorSync.targetEditor)) (⌘E to toggle)"
            : "Link an editor (⌘E)")
        .keyboardShortcut("e", modifiers: .command)

        if let buttonSize {
            button.frame(width: buttonSize, height: buttonSize)
        } else {
            button
        }
    }

    // MARK: - Popover Picker (shown on first click or when disabled)

    private var editorPickerPopover: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Link Editor  ⌘E")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 6)

            Divider()

            ForEach(Array(availableEditors.enumerated()), id: \.element.rawValue) { index, editor in
                let number = index + 1
                Button {
                    selectEditor(editor)
                } label: {
                    HStack(spacing: 8) {
                        // Number badge
                        Text("\(number)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)

                        editorIcon(for: editor)
                            .frame(width: 16, height: 16)

                        Text(editorDisplayName(editor))
                            .font(.system(size: 12))

                        Spacer()

                        if editor == editorSync.targetEditor && editorSync.isEnabled {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(cmuxAccentColor())
                        }

                        // Shortcut hint
                        Text("⌘E \(number)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Number key shortcut within the popover
                .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: [])
            }

            if availableEditors.isEmpty {
                Text("No supported editors installed")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }

            if editorSync.isEnabled {
                Divider()
                Button {
                    editorSync.isEnabled = false
                    showingPicker = false
                } label: {
                    HStack {
                        Text("Disable Sync")
                            .font(.system(size: 12))
                        Spacer()
                        Text("⌘E")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .frame(minWidth: 200)
    }

    // MARK: - Context Menu (right-click)

    @ViewBuilder
    private var editorContextMenu: some View {
        ForEach(Array(availableEditors.enumerated()), id: \.element.rawValue) { index, editor in
            Button {
                selectEditor(editor)
            } label: {
                HStack {
                    Text("\(index + 1). \(editorDisplayName(editor))")
                    if editor == editorSync.targetEditor && editorSync.isEnabled {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }

        if editorSync.isEnabled {
            Divider()
            Button("Disable Editor Sync") {
                editorSync.isEnabled = false
            }
        }
    }

    // MARK: - Actions

    private func selectEditor(_ editor: TerminalDirectoryOpenTarget) {
        editorSync.targetEditor = editor
        editorSync.isEnabled = true
        showingPicker = false
        editorSync.openCurrentDirectoryNow(activate: true)
    }

    // MARK: - Helpers

    private func editorDisplayName(_ editor: TerminalDirectoryOpenTarget) -> String {
        switch editor {
        case .cursor: return "Cursor"
        case .vscode: return "VS Code"
        case .windsurf: return "Windsurf"
        case .zed: return "Zed"
        case .xcode: return "Xcode"
        case .androidStudio: return "Android Studio"
        case .antigravity: return "Antigravity"
        default: return editor.rawValue.capitalized
        }
    }

    private func editorIcon(for editor: TerminalDirectoryOpenTarget) -> some View {
        let symbolName: String
        switch editor {
        case .cursor: symbolName = "cursorarrow.rays"
        case .vscode: symbolName = "chevron.left.forwardslash.chevron.right"
        case .windsurf: symbolName = "wind"
        case .zed: symbolName = "bolt.fill"
        case .xcode: symbolName = "hammer.fill"
        case .androidStudio: symbolName = "ant.fill"
        default: symbolName = "app.fill"
        }
        return Image(systemName: symbolName)
            .font(.system(size: 12))
            .foregroundStyle(.primary)
    }
}
