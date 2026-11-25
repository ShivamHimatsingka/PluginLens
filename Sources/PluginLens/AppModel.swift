import SwiftUI
import AppKit
import Observation

struct ProjectItem: Identifiable, Hashable {
    var project: DiscoveredProject
    var modified: Date?
    var state: LoadState = .pending
    var id: String { project.id }

    static func == (l: ProjectItem, r: ProjectItem) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

@MainActor
@Observable
final class AppModel {
    var items: [ProjectItem] = []
    var selection: String?
    var isScanning = false
    var statusText = ""
    /// nil = indeterminate
    var progress: Double?
    private var task: Task<Void, Never>?

    var selectedItem: ProjectItem? { items.first { $0.id == selection } }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = "Open Project"
        panel.message = "Choose a project (Logic .logicx, Ableton .als, REAPER .rpp, Waveform .tracktionedit, Ardour .ardour) or a folder containing them."
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ root: URL) {
        task?.cancel()
        items = []
        selection = nil
        isScanning = true
        progress = nil
        statusText = "Scanning…"
        task = Task { [weak self] in await self?.run(root) }
    }

    private func run(_ root: URL) async {
        // 1. Discover projects (off the main thread).
        let report: @Sendable (Int) -> Void = { [weak self] count in
            Task { @MainActor in self?.statusText = "Scanning… \(count) project\(count == 1 ? "" : "s") found" }
        }
        let found = await Task.detached(priority: .userInitiated) {
            ProjectScanner.discover(at: root, progress: report)
        }.value
        guard !Task.isCancelled else { return }

        items = found.map { ProjectItem(project: $0, modified: nil) }
        selection = items.first?.id
        if found.isEmpty {
            isScanning = false
            statusText = "No Logic projects found"
            return
        }

        // 2. Snapshot installed plugins once.
        statusText = "Reading installed plugins…"
        let index = await Task.detached(priority: .userInitiated) { InstalledPluginIndex() }.value
        guard !Task.isCancelled else { return }

        // 3. Parse every project, 4 at a time.
        let total = found.count
        var done = 0
        statusText = "Reading projects… 0 of \(total)"
        progress = 0
        await withTaskGroup(of: (String, Date?, LoadState).self) { group in
            var iterator = found.makeIterator()
            func addNext() {
                guard let p = iterator.next() else { return }
                group.addTask(priority: .userInitiated) {
                    (p.id, ProjectLoader.lastModified(of: p), ProjectLoader.load(p, index: index))
                }
            }
            for _ in 0..<min(4, total) { addNext() }
            while let (id, modified, state) = await group.next() {
                if Task.isCancelled { group.cancelAll(); break }
                if let i = items.firstIndex(where: { $0.id == id }) {
                    items[i].state = state
                    items[i].modified = modified
                }
                done += 1
                progress = Double(done) / Double(total)
                statusText = "Reading projects… \(done) of \(total)"
                addNext()
            }
        }
        guard !Task.isCancelled else { return }
        isScanning = false
        progress = nil
        statusText = "\(total) project\(total == 1 ? "" : "s")"
    }

    // MARK: Export

    func copyMarkdown(_ report: ProjectReport) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Exporters.markdown(report), forType: .string)
    }

    func exportCSV(_ report: ProjectReport) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(report.project.name) plugins.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Exporters.csv(report).write(to: url, atomically: true, encoding: .utf8) }
        catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn't export CSV"
            alert.runModal()
        }
    }
}
