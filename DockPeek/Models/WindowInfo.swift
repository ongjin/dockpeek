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
    /// Pre-resolved project / workspace root, populated by WindowManager.
    /// For document-backed windows this is the URL trimmed at the outermost
    /// path component also mentioned in the title; for JetBrains windows it
    /// is looked up from the IDE's recentProjects.xml.
    var projectRoot: URL?

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

    /// Abbreviated path to show above the thumbnail. If a project root was
    /// resolved upstream it wins; otherwise we fall back to the folder name
    /// parsed from the title (displayed without a path).
    var displayParentPath: String? {
        if let root = projectRoot {
            let path = root.path
            if !path.isEmpty, path != "/" {
                return (path as NSString).abbreviatingWithTildeInPath
            }
        }
        return WindowInfo.parsedTitle(title)?.folder
    }

    /// Exposed for WindowManager so it can look up JetBrains projects by the
    /// folder segment of the title.
    static func folderName(fromTitle title: String) -> String? {
        parsedTitle(title)?.folder
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
