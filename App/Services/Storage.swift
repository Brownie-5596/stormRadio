import Foundation
import StormRadioCore

/// Files on disk. settings.json lives in Documents so it also shows up in the Files app
/// (On My iPhone > Storm Radio), which is another way to move it between devices.
enum Storage {
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var support: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var caches: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0] }

    static var settingsURL: URL { documents.appendingPathComponent("settings.json") }
    static var feedURL: URL { support.appendingPathComponent("feed.json") }
    static var zonesURL: URL { caches.appendingPathComponent("zones.json") }

    static func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL), let s = try? SettingsIO.decode(data) else { return .defaults }
        return s
    }

    static func save(_ settings: AppSettings) {
        guard let data = try? SettingsIO.encode(settings) else { return }
        try? data.write(to: settingsURL, options: .atomic)
    }

    static func loadFeed() -> [Announcement] {
        guard let data = try? Data(contentsOf: feedURL) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([Announcement].self, from: data)) ?? []
    }

    static func save(feed: [Announcement]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(Array(feed.prefix(500))) else { return }
        try? data.write(to: feedURL, options: .atomic)
    }

    static func loadZones() -> [String: GeoShape] {
        guard let data = try? Data(contentsOf: zonesURL) else { return [:] }
        return (try? JSONDecoder().decode([String: GeoShape].self, from: data)) ?? [:]
    }

    static func save(zones: [String: GeoShape]) {
        guard let data = try? JSONEncoder().encode(zones) else { return }
        try? data.write(to: zonesURL, options: .atomic)
    }

    /// Writes an export file to a temporary location for sharing (AirDrop, Files, Messages...).
    static func exportFile(_ data: Data, name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
