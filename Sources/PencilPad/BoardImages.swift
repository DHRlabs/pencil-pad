import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The images pasted onto the board: one PNG per paste in Application Support, named by a 12-character
/// lowercase hex id. The only place that knows the folder and the id rule; the paste handler, the HTTP
/// server and the Board window's scheme handler all read through it, so a bad id is a 404 everywhere.
enum BoardImages {
    /// The largest stored image. Bigger ones are scaled down to fit inside it, never up.
    static let limit = (w: 3840, h: 2160)

    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PencilPad/Images", isDirectory: true)

    /// How both servers let a browser keep an image: the file behind an id never changes.
    static let cacheControl = "private, max-age=31536000, immutable"

    /// `^[0-9a-f]{12}$`
    static func isValid(_ k: String) -> Bool {
        k.utf8.count == 12 && k.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    /// The stored PNG for image `k`, or nil for a bad id or a missing file.
    static func data(_ k: String) -> Data? {
        guard isValid(k) else { return nil }
        return try? Data(contentsOf: folder.appendingPathComponent("\(k).png"))
    }

    // MARK: Paste

    /// Something on the clipboard that may be an image.
    enum Source: Sendable {
        case file(URL)
        case data(Data)
    }

    struct Stored: Sendable {
        let k: String
        let w: Int
        let h: Int
    }

    struct Failure: Error, Sendable {
        let why: String
    }

    /// What the clipboard offers, best first: an image file (what was copied is that file, and any picture
    /// next to it is only its icon), then PNG, then TIFF. Cheap, so it runs on the main actor; decoding does not.
    @MainActor
    static func clipboard() -> [Source] {
        let board = NSPasteboard.general
        let files = board.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]) as? [URL] ?? []
        var found = files.map { Source.file($0) }
        if let png = board.data(forType: .png) { found.append(.data(png)) }
        if let tiff = board.data(forType: .tiff) { found.append(.data(tiff)) }
        return found
    }

    /// Decodes the first source that is a readable image, scales it down to fit `limit`, and stores it as PNG.
    nonisolated static func store(_ sources: [Source]) -> Result<Stored, Failure> {
        guard !sources.isEmpty else { return .failure(Failure(why: "No image on the Mac clipboard")) }
        for source in sources {
            let imageSource: CGImageSource? = switch source {
            case .file(let url): CGImageSourceCreateWithURL(url as CFURL, nil)
            case .data(let data): CGImageSourceCreateWithData(data as CFData, nil)
            }
            guard let imageSource, let (png, w, h) = scaledPNG(imageSource) else { continue }
            return save(png, w: w, h: h)
        }
        return .failure(Failure(why: "The image on the Mac clipboard could not be read"))
    }

    /// The image as PNG bytes plus its size in pixels. The size comes from the pixels, not from NSImage points.
    private nonisolated static func scaledPNG(_ source: CGImageSource) -> (Data, Int, Int)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var w = props[kCGImagePropertyPixelWidth] as? Int,
              var h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0
        else { return nil }
        // A rotated photo (EXIF 5 to 8) is stored sideways; the thumbnail below turns it upright.
        if let turn = props[kCGImagePropertyOrientation] as? Int, turn >= 5 { swap(&w, &h) }
        let scale = min(1, Double(limit.w) / Double(w), Double(limit.h) / Double(h))
        let side = max(1, Int((Double(max(w, h)) * scale).rounded(.down)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data, image.width, image.height)
    }

    /// Writes the PNG under a fresh random id. The write refuses to overwrite, so an id that is taken is redrawn.
    private nonisolated static func save(_ png: Data, w: Int, h: Int) -> Result<Stored, Failure> {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            while true {
                let k = (0..<6).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
                do {
                    try png.write(to: folder.appendingPathComponent("\(k).png"), options: .withoutOverwriting)
                    return .success(Stored(k: k, w: w, h: h))
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    continue
                }
            }
        } catch {
            log.error("board: image not stored: \(error.localizedDescription, privacy: .public)")
            return .failure(Failure(why: "The image could not be saved on the Mac"))
        }
    }
}
