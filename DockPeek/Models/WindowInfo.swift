import AppKit

struct WindowInfo: Identifiable {
    let id: CGWindowID
    let title: String
    let bounds: CGRect
    let ownerPID: pid_t
    let ownerName: String
    let isOnScreen: Bool
    let isMinimized: Bool
    var thumbnail: NSImage?
    var documentURL: URL?

    var displayTitle: String {
        title.isEmpty ? ownerName : title
    }

    /// Filename to show beneath the thumbnail. Prefers the document URL; for
    /// apps that don't expose AX document URLs (JetBrains IDEs etc.) falls
    /// back to parsing the window title.
    var displayFileName: String? {
        if let url = documentURL {
            return url.lastPathComponent
        }
        return WindowInfo.parsedTitle(title)?.file
    }

    /// Abbreviated path ending at the project/workspace root. Editors like
    /// VS Code and Cursor set the AX document URL to the currently-focused
    /// file, so showing only its parent directory exposes an internal file
    /// location rather than the project folder the user actually opened.
    /// Here we match segments of the window title against directories in the
    /// URL and keep the outermost match, which is typically the workspace
    /// root the editor displays in the title bar. For windows without a
    /// document URL (JetBrains etc.) falls back to the folder name parsed
    /// from the title — we don't know the full path in that case.
    var displayParentPath: String? {
        if let url = documentURL {
            let components = url.pathComponents
            guard components.count > 2 else { return nil }

            if !title.isEmpty {
                let segments = WindowInfo.titleSegments(title)
                if !segments.isEmpty {
                    for i in 1..<(components.count - 1) {
                        if segments.contains(components[i]) {
                            let joined = components.dropFirst().prefix(i + 1).joined(separator: "/")
                            return ("/" + joined as NSString).abbreviatingWithTildeInPath
                        }
                    }
                }
            }

            let parent = url.deletingLastPathComponent().path
            guard !parent.isEmpty, parent != "/" else { return nil }
            return (parent as NSString).abbreviatingWithTildeInPath
        }

        return WindowInfo.parsedTitle(title)?.folder
    }

    private static func titleSegments(_ title: String) -> Set<String> {
        var parts: [String] = [title]
        for sep in [" — ", " – ", " - "] {
            parts = parts.flatMap { $0.components(separatedBy: sep) }
        }
        return Set(parts
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    /// Attempt to split a "file — folder" / "folder — file" style title into
    /// its two parts. Only commits when exactly one side looks like a source
    /// code / document filename (known extension); otherwise bails out so
    /// browsers and chat apps with " - "-style titles don't get mangled.
    private static func parsedTitle(_ title: String) -> (file: String, folder: String)? {
        for sep in [" — ", " – ", " - "] {
            let parts = title.components(separatedBy: sep)
            guard parts.count == 2 else { continue }
            let a = parts[0].trimmingCharacters(in: .whitespaces)
            let b = parts[1].trimmingCharacters(in: .whitespaces)
            guard !a.isEmpty, !b.isEmpty else { continue }
            let aIsFile = isKnownFileName(a)
            let bIsFile = isKnownFileName(b)
            if aIsFile && !bIsFile { return (file: a, folder: b) }
            if bIsFile && !aIsFile { return (file: b, folder: a) }
        }
        return nil
    }

    private static func isKnownFileName(_ s: String) -> Bool {
        let ext = (s as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        return knownFileExtensions.contains(ext)
    }

    private static let knownFileExtensions: Set<String> = [
        "swift", "kt", "kts", "java", "groovy", "scala",
        "py", "rb", "php", "pl", "lua", "dart", "zig", "nim", "cr",
        "js", "mjs", "cjs", "ts", "tsx", "jsx", "vue", "svelte", "astro",
        "go", "rs", "c", "cc", "cpp", "cxx", "h", "hh", "hpp", "m", "mm",
        "ex", "exs", "erl", "elm", "clj", "cljs", "cljc", "edn",
        "r", "jl", "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd",
        "md", "markdown", "rst", "tex", "adoc", "txt", "log",
        "json", "jsonc", "yaml", "yml", "toml", "xml", "ini", "env", "conf", "cfg", "properties",
        "html", "htm", "css", "scss", "sass", "less", "styl",
        "sql", "prisma", "proto", "graphql", "gql",
        "tf", "tfvars", "hcl",
        "plist", "xib", "storyboard", "xcassets", "pbxproj", "gradle", "cmake",
        "gitignore", "gitattributes", "editorconfig", "dockerfile",
        "csv", "tsv",
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "heif", "bmp", "tiff", "tif", "ico"
    ]
}
