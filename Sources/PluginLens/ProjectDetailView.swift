import SwiftUI

struct ProjectDetailView: View {
    @Environment(AppModel.self) private var model
    /// Looked up by id on every render so state changes (loading -> loaded) always refresh the view.
    let itemID: String
    private var item: ProjectItem {
        model.items.first { $0.id == itemID } ?? ProjectItem(project: DiscoveredProject(url: URL(fileURLWithPath: itemID), kind: .logicx), modified: nil)
    }

    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\PluginEntry.statusRank), KeyPathComparator(\PluginEntry.name)]

    private var report: ProjectReport? {
        if case .loaded(let r) = item.state { return r }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .searchable(text: $search, placement: .toolbar, prompt: "Filter plugins")
        .toolbar {
            ToolbarItemGroup {
                Button { if let report { model.copyMarkdown(report) } } label: {
                    Label("Copy as Markdown", systemImage: "doc.on.doc")
                }
                .disabled(report == nil)
                Button { if let report { model.exportCSV(report) } } label: {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
                }
                .disabled(report == nil)
            }
        }
        .navigationTitle(item.project.name)
        .onChange(of: itemID) { _, _ in search = "" }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.project.name).font(.title2.bold())
            Text(item.project.url.path)
                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
            HStack(spacing: 16) {
                if let d = report?.lastModified ?? item.modified {
                    Label("Modified \(d.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                }
                if let v = report?.lastSavedFrom {
                    Label(v, systemImage: "hammer")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch item.state {
        case .pending, .loading:
            VStack { ProgressView("Reading project…") }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let error):
            ContentUnavailableView {
                Label("Can't Read This Project", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.localizedDescription).textSelection(.enabled)
            }
        case .loaded(let r):
            VStack(spacing: 0) {
                ForEach(r.warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.yellow.opacity(0.18))
                }
                table(for: r)
                footer(for: r)
            }
        }
    }

    private func filtered(_ r: ProjectReport) -> [PluginEntry] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let base = q.isEmpty ? r.plugins : r.plugins.filter {
            [$0.name, $0.manufacturer, $0.formatText, $0.versionText, $0.savedVersionText, $0.versionCheck.rawValue, $0.statusText, $0.codes]
                .contains { $0.localizedCaseInsensitiveContains(q) }
        }
        return base.sorted(using: sortOrder)
    }

    @ViewBuilder private func table(for r: ProjectReport) -> some View {
        let rows = filtered(r)
        if r.plugins.isEmpty {
            ContentUnavailableView("No Plugins Found", systemImage: "puzzlepiece.extension",
                                   description: Text("This project has no plugin records that this app can read."))
        } else {
            Table(rows, sortOrder: $sortOrder) {
                TableColumn("Plugin", value: \.name) { p in
                    HStack(spacing: 6) {
                        if p.needsAttention {
                            Image(systemName: p.status == .notInstalled ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(p.status == .notInstalled ? .red : .orange)
                        }
                        Text(p.name)
                    }
                    .help(p.note ?? p.name)
                }
                .width(min: 140, ideal: 180)
                TableColumn("Manufacturer", value: \.manufacturer) { p in Text(p.manufacturer) }
                    .width(min: 90, ideal: 130)
                TableColumn("Format", value: \.formatText) { p in Text(p.formatText) }
                    .width(min: 120, ideal: 170)
                TableColumn("Saved with", value: \.savedVersionText) { p in
                    Text(p.savedVersionText).monospacedDigit().foregroundStyle(p.savedVersion == nil ? .secondary : .primary)
                        .help(p.savedVersionSource.map { "Read from: \($0)" } ?? "This plugin does not write its version into the project.")
                }
                .width(min: 90, ideal: 120)
                TableColumn("Installed version", value: \.versionText) { p in
                    Text(p.versionText).monospacedDigit().foregroundStyle(p.installedVersion == nil ? .secondary : .primary)
                }
                .width(min: 100, ideal: 130)
                TableColumn("Version check", value: \.checkRank) { p in
                    HStack(spacing: 4) {
                        if p.versionCheck.needsAttention { Image(systemName: "arrow.triangle.2.circlepath") }
                        Text(p.versionCheck.rawValue)
                    }
                    .foregroundStyle(checkColor(p.versionCheck))
                    .help(p.versionCheck == .notStored ? "The project has no version for this plugin." : "")
                }
                .width(min: 100, ideal: 125)
                TableColumn("Status", value: \.statusRank) { p in
                    Text(p.statusText)
                        .fontWeight(p.needsAttention ? .semibold : .regular)
                        .foregroundStyle(statusColor(p.status))
                        .help(p.note ?? "")
                }
            }
            .overlay {
                if rows.isEmpty { ContentUnavailableView.search(text: search) }
            }
        }
    }

    private func footer(for r: ProjectReport) -> some View {
        let missing = r.plugins.filter { $0.status == .notInstalled }.count
        let unknown = r.plugins.filter { $0.status == .versionUnknown }.count
        let changed = r.plugins.filter { $0.versionCheck.needsAttention }.count
        return HStack {
            Text("\(r.plugins.count) plugin\(r.plugins.count == 1 ? "" : "s")")
            if missing > 0 { Text("· \(missing) not installed").foregroundStyle(.red) }
            if unknown > 0 { Text("· \(unknown) version unknown").foregroundStyle(.orange) }
            if changed > 0 { Text("· \(changed) changed since saved").foregroundStyle(.orange) }
            Spacer()
        }
        .font(.caption).padding(8).background(.bar)
    }

    private func checkColor(_ c: VersionCheck) -> Color {
        switch c {
        case .same: return .green
        case .installedNewer, .differs: return .orange
        case .installedOlder: return .red
        default: return .secondary
        }
    }

    private func statusColor(_ s: PluginStatus) -> Color {
        switch s {
        case .installed: return .green
        case .notInstalled: return .red
        case .versionUnknown: return .orange
        }
    }
}

extension PluginEntry {
    var statusRank: Int { status.sortRank }
    var checkRank: Int { versionCheck.sortRank }
}
