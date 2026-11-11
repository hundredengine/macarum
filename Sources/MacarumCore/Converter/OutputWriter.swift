import Foundation

/// Picks where a result goes and writes it without ever replacing an existing file:
/// `photo.jpg`, then `photo (1).jpg`, `photo (2).jpg`.
public enum OutputWriter {
    static let maxAttempts = 10_000

    /// "photo.jpg" for index 0, "photo (3).jpg" for index 3; no extension gives a folder name.
    public static func name(base: String, ext: String?, index: Int) -> String {
        let stem = index == 0 ? base : "\(base) (\(index))"
        guard let ext, !ext.isEmpty else { return stem }
        return stem + "." + ext
    }

    /// The folder results of `source` go to. Throws when a chosen folder no longer exists.
    public static func directory(for source: URL, destination: OutputDestination) throws -> URL {
        switch destination {
        case .nextToOriginal:
            return source.deletingLastPathComponent()
        case .folder(let folder):
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ConversionError.folderMissing(folder.lastPathComponent)
            }
            return folder
        }
    }

    /// Writes `data` with exclusive create, so a file that already exists (or appears
    /// meanwhile) is never overwritten.
    public static func write(_ data: Data, base: String, ext: String, in directory: URL) throws -> URL {
        for index in 0..<maxAttempts {
            let url = directory.appendingPathComponent(name(base: base, ext: ext, index: index))
            do {
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            } catch {
                throw writeError(error, directory)
            }
        }
        throw ConversionError.cannotWrite(folder: directory.lastPathComponent, reason: "too many files with this name")
    }

    /// Moves a finished file (written elsewhere first, as AVFoundation needs a path that does not
    /// exist yet) to its free name; never replaces a file. The source is removed either way.
    public static func move(_ source: URL, base: String, ext: String, in directory: URL) throws -> URL {
        defer { try? FileManager.default.removeItem(at: source) }
        for index in 0..<maxAttempts {
            let url = directory.appendingPathComponent(name(base: base, ext: ext, index: index))
            do {
                try FileManager.default.moveItem(at: source, to: url)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            } catch {
                throw writeError(error, directory)
            }
        }
        throw ConversionError.cannotWrite(folder: directory.lastPathComponent, reason: "too many files with this name")
    }

    /// Checks a folder can take new files before a long job starts, so a video is not
    /// converted for minutes only to fail at the end.
    public static func checkWritable(_ directory: URL) throws {
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            throw ConversionError.cannotWrite(folder: directory.lastPathComponent, reason: "permission denied")
        }
    }

    /// A fresh path in the temporary folder for AVFoundation to write to.
    static func temporaryURL(ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("macarum-\(UUID().uuidString).\(ext)")
    }

    /// Makes a new, empty folder: `report`, then `report (1)`.
    public static func makeFolder(base: String, in directory: URL) throws -> URL {
        for index in 0..<maxAttempts {
            let url = directory.appendingPathComponent(name(base: base, ext: nil, index: index), isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            } catch {
                throw writeError(error, directory)
            }
        }
        throw ConversionError.cannotWrite(folder: directory.lastPathComponent, reason: "too many folders with this name")
    }

    private static func writeError(_ error: Error, _ directory: URL) -> ConversionError {
        let reason: String
        if let cocoa = error as? CocoaError, cocoa.code == .fileWriteNoPermission {
            reason = "permission denied"
        } else if let cocoa = error as? CocoaError, cocoa.code == .fileWriteOutOfSpace {
            reason = "the disk is full"
        } else if let cocoa = error as? CocoaError, cocoa.code == .fileWriteVolumeReadOnly {
            reason = "the disk is read-only"
        } else {
            reason = (error as NSError).localizedFailureReason ?? error.localizedDescription
        }
        return .cannotWrite(folder: directory.lastPathComponent, reason: reason)
    }
}
