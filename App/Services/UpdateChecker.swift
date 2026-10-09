import Foundation
import Combine
import UIKit

/// Checks the GitHub "latest" release (via its AltStore/SideStore source file) for a newer build.
@MainActor
final class UpdateChecker: ObservableObject {
    static let repo = "Brownie-5596/stormRadio"
    static let releaseTag = "latest"
    static var releasePage: URL { URL(string: "https://github.com/\(repo)/releases/tag/\(releaseTag)")! }
    static var ipaURL: URL { URL(string: "https://github.com/\(repo)/releases/download/\(releaseTag)/StormRadio.ipa")! }
    static var sourceURL: URL { URL(string: "https://github.com/\(repo)/releases/download/\(releaseTag)/altstore-source.json")! }

    struct Latest: Equatable {
        var version: String
        var build: Int
        var date: String
        var notes: String
        var size: Int
    }

    @Published private(set) var latest: Latest?
    @Published private(set) var checking = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var error: String?

    var installedVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    var installedBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }

    var updateAvailable: Bool { (latest?.build ?? 0) > installedBuild }

    /// Checks at most every few hours unless forced.
    func check(force: Bool = false) async {
        if !force, let last = lastChecked, Date().timeIntervalSince(last) < 3 * 3600 { return }
        guard !checking else { return }
        checking = true
        defer { checking = false }
        do {
            var req = URLRequest(url: Self.sourceURL)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 20
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                throw NSError(domain: "StormRadio", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "No published build found (HTTP \(http.statusCode))."])
            }
            struct Source: Decodable {
                struct App: Decodable { var versions: [Version] }
                struct Version: Decodable {
                    var version: String
                    var buildVersion: String
                    var date: String?
                    var localizedDescription: String?
                    var size: Int?
                }
                var apps: [App]
            }
            let src = try JSONDecoder().decode(Source.self, from: data)
            guard let v = src.apps.first?.versions.first else { throw NSError(domain: "StormRadio", code: 2, userInfo: [NSLocalizedDescriptionKey: "The update file is empty."]) }
            latest = Latest(version: v.version, build: Int(v.buildVersion) ?? 0, date: v.date ?? "", notes: v.localizedDescription ?? "", size: v.size ?? 0)
            error = nil
            lastChecked = Date()
        } catch {
            self.error = error.localizedDescription
            lastChecked = Date()
        }
    }

    /// Opens SideStore or AltStore with the source added (falls back to the release page).
    func addSource(app: String) {
        let enc = Self.sourceURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        guard let url = URL(string: "\(app)://source?url=\(enc)") else { return }
        UIApplication.shared.open(url) { ok in
            if !ok { UIApplication.shared.open(Self.releasePage) }
        }
    }
}
