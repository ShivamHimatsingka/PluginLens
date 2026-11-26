import Foundation

enum Exporters {
    static func markdown(_ report: ProjectReport) -> String {
        var s = "# \(escapeMD(report.project.name))\n\n"
        s += "- Path: `\(report.project.url.path)`\n"
        if let d = report.lastModified { s += "- Last modified: \(d.formatted(date: .abbreviated, time: .shortened))\n" }
        if let v = report.lastSavedFrom { s += "- Saved with: \(escapeMD(v))\n" }
        s += "\n| Plugin | Manufacturer | Format | Saved with | Installed version | Version check | Status |\n|---|---|---|---|---|---|---|\n"
        for p in report.plugins {
            s += "| \(escapeMD(p.name)) | \(escapeMD(p.manufacturer)) | \(escapeMD(p.formatText)) | \(escapeMD(p.savedVersionText)) | \(escapeMD(p.versionText)) | \(escapeMD(p.versionCheck.rawValue)) | \(escapeMD(p.statusText)) |\n"
        }
        if report.plugins.isEmpty { s += "| _No plugins found_ | | | | | | |\n" }
        return s
    }

    static func csv(_ report: ProjectReport) -> String {
        var rows = [["Plugin", "Manufacturer", "Format", "Saved with", "Installed version", "Version check", "Status", "IDs", "Note"]]
        for p in report.plugins {
            rows.append([p.name, p.manufacturer, p.formatText, p.savedVersion ?? "", p.installedVersion.map { p.isUncertain ? "\($0) (uncertain)" : $0 } ?? "",
                         p.versionCheck.rawValue, p.statusText, p.codes, p.note ?? ""])
        }
        return rows.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// RFC 4180 quoting, plus a leading apostrophe on cells that spreadsheet apps would treat as formulas.
    static func csvField(_ raw: String) -> String {
        var v = raw
        if let f = v.first, "=+-@\t\r".contains(f) { v = "'" + v }
        if v.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            v = "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return v
    }

    static func escapeMD(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }
}
