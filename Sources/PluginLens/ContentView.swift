import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            sidebar(selection: $model.selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        } detail: {
            if let item = model.selectedItem {
                ProjectDetailView(itemID: item.id)
            } else {
                ContentUnavailableView {
                    Label("No Project Selected", systemImage: "waveform")
                } description: {
                    Text("Use Open Project… to choose a Logic .logicx package, an Ableton .als set, or a folder of projects.")
                }
            }
        }
        .task {
            // `--open <path>` lets scripts and UI tests start with a project loaded.
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--open"), i + 1 < args.count, model.items.isEmpty {
                model.open(URL(fileURLWithPath: args[i + 1]))
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.chooseProject() } label: {
                    Label("Open Project…", systemImage: "folder")
                }
                .help("Open a Logic project, an Ableton Live set, or a folder containing them")
            }
        }
    }

    private func sidebar(selection: Binding<String?>) -> some View {
        List(model.items, selection: selection) { item in
            HStack(spacing: 8) {
                Image(systemName: icon(for: item))
                    .foregroundStyle(color(for: item))
                    .frame(width: 18)
                Text(item.project.name).lineLimit(1)
                Spacer(minLength: 4)
                if case .loading = item.state { ProgressView().controlSize(.small) }
                if case .pending = item.state, model.isScanning { ProgressView().controlSize(.small) }
            }
            .tag(item.id)
        }
        .overlay {
            if model.items.isEmpty && !model.isScanning {
                ContentUnavailableView {
                    Label("No Projects", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(model.statusText.isEmpty ? "Choose Open Project… to begin." : model.statusText)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.isScanning {
                VStack(alignment: .leading, spacing: 4) {
                    if let p = model.progress {
                        ProgressView(value: p)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(model.statusText).font(.caption).foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.bar)
            }
        }
    }

    private func icon(for item: ProjectItem) -> String {
        switch item.state {
        case .failed: return "exclamationmark.triangle.fill"
        case .loaded(let r): return r.plugins.contains(where: { $0.needsAttention || $0.versionCheck.needsAttention }) ? "exclamationmark.circle" : "music.note.list"
        default: return "music.note.list"
        }
    }
    private func color(for item: ProjectItem) -> Color {
        switch item.state {
        case .failed: return .red
        case .loaded(let r): return r.plugins.contains(where: { $0.status == .notInstalled }) ? .orange : .secondary
        default: return .secondary
        }
    }
}
