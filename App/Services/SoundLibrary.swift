import Foundation
import Combine
import StormRadioCore

/// A user-provided alert sound stored in Documents/Sounds.
struct CustomSound: Identifiable, Hashable {
    let fileName: String
    var id: String { fileName }
    var tone: ToneID { .custom(fileName) }
    var name: String { (fileName as NSString).deletingPathExtension }
}

/// Custom sounds live in Files > On My iPhone > Storm Radio > Sounds, so you can also drop files in there directly.
@MainActor
final class SoundLibrary: ObservableObject {
    @Published private(set) var sounds: [CustomSound] = []

    static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "caf", "aif", "aiff", "aac", "mp4"]

    nonisolated static var folder: URL {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// File for a custom tone, if it exists on this device.
    nonisolated static func fileURL(for tone: ToneID) -> URL? {
        guard let name = tone.customFileName else { return nil }
        let u = folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    init() { reload() }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.folder.path)) ?? []
        sounds = files.filter { Self.audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { CustomSound(fileName: $0) }
    }

    /// Copies an audio file (from the Files picker) into the Sounds folder.
    @discardableResult
    func importFile(_ url: URL) throws -> CustomSound {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.lowercased()
        guard Self.audioExtensions.contains(ext) else {
            throw NSError(domain: "StormRadio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Use an audio file (m4a, mp3, wav, caf, aiff)."])
        }
        let base = url.deletingPathExtension().lastPathComponent
        var name = "\(base).\(ext)"
        var n = 2
        while FileManager.default.fileExists(atPath: Self.folder.appendingPathComponent(name).path) {
            name = "\(base) \(n).\(ext)"
            n += 1
        }
        try FileManager.default.copyItem(at: url, to: Self.folder.appendingPathComponent(name))
        reload()
        return CustomSound(fileName: name)
    }

    func delete(_ s: CustomSound) {
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(s.fileName))
        reload()
    }

    func rename(_ s: CustomSound, to newName: String) {
        let clean = newName.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty else { return }
        let ext = (s.fileName as NSString).pathExtension
        let target = Self.folder.appendingPathComponent("\(clean).\(ext)")
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        try? FileManager.default.moveItem(at: Self.folder.appendingPathComponent(s.fileName), to: target)
        reload()
    }
}
