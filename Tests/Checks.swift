// Headless checks for the pure pieces of DockPeek. Run with `make test`.
// No permissions, no UI, no cursor. Anything that needs a live Dock belongs in scripts/e2e.swift.

import AppKit

@main
struct Checks {
    static var failures = 0

    static func expect(_ passed: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        let note = detail()
        print(passed ? "PASS" : "FAIL", name, note.isEmpty ? "" : "— \(note)")
        if !passed { failures += 1 }
    }

    static func main() {
        checkVersionOrdering()
        checkDownscale()
        checkPreviewFit()
        checkL10nParity()

        print(failures == 0 ? "All checks passed" : "\(failures) check(s) failed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - UpdateChecker

    /// The self-updater offers an update only when the release is newer, so this ordering decides
    /// who gets prompted.
    static func checkVersionOrdering() {
        let newer: [(String, String)] = [("1.5.24", "1.5.23"), ("1.10.0", "1.9.9"), ("2", "1.9.9"), ("1.5.1", "1.5")]
        for (a, b) in newer {
            expect(UpdateChecker.compareVersions(a, isGreaterThan: b), "version \(a) > \(b)")
            expect(!UpdateChecker.compareVersions(b, isGreaterThan: a), "version \(b) is not > \(a)")
        }

        let equal: [(String, String)] = [("1.5.24", "1.5.24"), ("1.5", "1.5.0")]
        for (a, b) in equal {
            expect(!UpdateChecker.compareVersions(a, isGreaterThan: b) && !UpdateChecker.compareVersions(b, isGreaterThan: a),
                   "version \(a) == \(b)")
        }
    }

    // MARK: - Thumbnails

    static func makeImage(width: Int, height: Int, space: CGColorSpace, bitmapInfo: UInt32) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: bitmapInfo) else { return nil }
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func pixels(_ image: NSImage?) -> (width: Int, height: Int)? {
        image?.cgImage(forProposedRect: nil, context: nil, hints: nil).map { ($0.width, $0.height) }
    }

    /// Thumbnails must come out at display size: caching full-size captures is what used to hold
    /// tens of megabytes per preview.
    static func checkDownscale() {
        let rgba = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let p3 = CGColorSpace(name: CGColorSpace.displayP3) else {
            expect(false, "Display P3 color space available")
            return
        }

        func image(_ width: Int, _ height: Int) -> CGImage? { makeImage(width: width, height: height, space: p3, bitmapInfo: rgba) }

        let landscape = image(2880, 1800).flatMap { WindowManager.downscale($0, maxSize: 200, scale: 2) }
        expect(pixels(landscape).map { $0 == (400, 250) } ?? false, "landscape capture downscales to 400x250 px", "\(String(describing: pixels(landscape)))")
        expect(landscape?.size == NSSize(width: 200, height: 125), "landscape thumbnail is 200x125 pt", "\(String(describing: landscape?.size))")

        let small = image(300, 200).flatMap { WindowManager.downscale($0, maxSize: 200, scale: 2) }
        expect(pixels(small).map { $0 == (300, 200) } ?? false, "small window is never upscaled", "\(String(describing: pixels(small)))")

        let portrait = image(1000, 2000).flatMap { WindowManager.downscale($0, maxSize: 200, scale: 2) }
        expect(pixels(portrait).map { $0 == (200, 400) } ?? false, "portrait capture downscales to 200x400 px", "\(String(describing: pixels(portrait)))")
        expect(portrait?.size == NSSize(width: 100, height: 200), "portrait thumbnail is 100x200 pt", "\(String(describing: portrait?.size))")

        let colorKept = image(800, 500).flatMap { WindowManager.downscale($0, maxSize: 200, scale: 2) }?
            .cgImage(forProposedRect: nil, context: nil, hints: nil)?.colorSpace?.name == p3.name
        expect(colorKept, "thumbnail keeps the capture's color space")

        // A space the bitmap context can't render into must still yield a thumbnail.
        let gray = makeImage(width: 800, height: 600, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        expect(gray.flatMap { WindowManager.downscale($0, maxSize: 200, scale: 2) } != nil, "unsupported color space falls back instead of dropping the thumbnail")
    }

    // MARK: - Preview layout

    /// A row of cards must fit the screen: cards past its edge can't be reached.
    static func checkPreviewFit() {
        expect(PreviewMetrics.rowWidth(count: 2, thumbnailSize: 200) == 468, "two 200pt cards make a 468pt row")
        expect(PreviewMetrics.rowWidth(count: 4, thumbnailSize: 200) == 916, "four 200pt cards make a 916pt row")

        let roomy = PreviewMetrics.fittedThumbnailSize(preferred: 200, count: 4, available: 1904)
        expect(roomy == 200, "a row that fits keeps the preferred size", "\(roomy)")

        let crowded = PreviewMetrics.fittedThumbnailSize(preferred: 200, count: 12, available: 1904)
        expect(PreviewMetrics.rowWidth(count: 12, thumbnailSize: crowded) <= 1904, "12 cards are shrunk to fit 1904pt", "size \(crowded)")
        expect(PreviewMetrics.rowWidth(count: 12, thumbnailSize: crowded + 1) > 1904, "and no further than needed", "size \(crowded)")

        let hopeless = PreviewMetrics.fittedThumbnailSize(preferred: 200, count: 60, available: 1904)
        expect(hopeless == PreviewMetrics.minThumbnailSize, "shrinking stops at the minimum size", "\(hopeless)")

        for available in [CGFloat(1264), 1424, 1904, 2544] {
            for count in 1...14 {
                for preferred in [CGFloat(120), 200, 360] {
                    let size = PreviewMetrics.fittedThumbnailSize(preferred: preferred, count: count, available: available)
                    let fits = PreviewMetrics.rowWidth(count: count, thumbnailSize: size) <= available
                    guard size > preferred || (!fits && size > PreviewMetrics.minThumbnailSize) else { continue }
                    expect(false, "fit holds for \(count) cards at \(Int(preferred))pt in \(Int(available))pt", "size \(size)")
                }
            }
        }
    }

    // MARK: - Localization

    /// Every string must exist in both languages. The dictionaries are private, so read the source.
    static func checkL10nParity() {
        let path = "DockPeek/Utilities/L10n.swift"
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            expect(false, "read \(path)", "run from the repo root")
            return
        }

        func keys(in text: Substring, pattern: String) -> Set<String> {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
            let string = String(text)
            return Set(regex.matches(in: string, range: NSRange(string.startIndex..., in: string)).compactMap {
                Range($0.range(at: 1), in: string).map { String(string[$0]) }
            })
        }

        func table(_ language: String) -> Set<String> {
            guard let start = source.range(of: "private static let \(language): [String: String] = ["),
                  let end = source.range(of: "\n    ]", range: start.upperBound..<source.endIndex) else { return [] }
            return keys(in: source[start.upperBound..<end.lowerBound], pattern: #"^\s*"([A-Za-z0-9_]+)"\s*:"#)
        }

        let en = table("en"), ko = table("ko")
        let used = keys(in: source[...], pattern: #"\bs\("([A-Za-z0-9_]+)"\)"#)

        expect(!en.isEmpty && !ko.isEmpty, "both language tables found", "en \(en.count), ko \(ko.count)")
        expect(en == ko, "en and ko define the same keys", "only en: \(en.subtracting(ko).sorted()), only ko: \(ko.subtracting(en).sorted())")
        expect(used.isSubset(of: en), "every accessor key exists", "missing: \(used.subtracting(en).sorted())")
    }
}
