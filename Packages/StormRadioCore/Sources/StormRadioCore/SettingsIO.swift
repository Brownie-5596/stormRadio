import Foundation

/// Reading and writing settings files.
///
/// Importing is lenient: anything missing from the file (for example settings added in a newer version
/// of the app) is filled in from the defaults, so old exported files keep working.
public enum SettingsIO {
    public enum ImportError: LocalizedError {
        case notJSON
        case invalid(String)

        public var errorDescription: String? {
            switch self {
            case .notJSON: return "The file is not a Storm Radio settings file (not valid JSON)."
            case .invalid(let why): return "The settings file could not be read: \(why)"
            }
        }
    }

    public static func encode(_ settings: AppSettings) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(settings)
    }

    public static func encode(profile: Profile) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(profile)
    }

    /// Decodes a full settings file, or a single exported profile (wrapped into a settings object).
    public static func decode(_ data: Data) throws -> AppSettings {
        guard let any = try? JSONSerialization.jsonObject(with: data), let obj = any as? [String: Any] else {
            throw ImportError.notJSON
        }
        let defaults = AppSettings.defaults
        var defaultsObj = try jsonObject(defaults)

        var input = obj
        if input["profiles"] == nil, input["alertRules"] != nil || input["location"] != nil {
            // A single profile file.
            let pid = (input["id"] as? String) ?? UUID().uuidString
            input = ["profiles": [input], "activeProfileID": pid]
        }

        let baseProfile = try jsonObject(Profile.chase)
        let ruleDefault = try jsonObject(ProductRule())
        let reportRuleDefault = try jsonObject(ReportRule())

        var mergedProfiles: [Any] = []
        if let profiles = input["profiles"] as? [[String: Any]] {
            for p in profiles {
                var base = baseProfile
                // Start from the matching built-in profile when ids match (keeps sensible defaults).
                if let pid = p["id"] as? String, let builtin = defaults.profiles.first(where: { $0.id == pid }) {
                    base = try jsonObject(builtin)
                }
                var merged = deepMerge(base, p)
                if let rules = p["alertRules"] as? [String: Any] {
                    var out = (base["alertRules"] as? [String: Any]) ?? [:]
                    for (k, v) in rules {
                        let start = (out[k] as? [String: Any]) ?? ruleDefault
                        out[k] = (v as? [String: Any]).map { deepMerge(start, $0) } ?? start
                    }
                    merged["alertRules"] = out
                }
                if let reports = p["reports"] as? [String: Any], let cats = reports["categories"] as? [String: Any] {
                    var rep = (merged["reports"] as? [String: Any]) ?? [:]
                    var out = ((base["reports"] as? [String: Any])?["categories"] as? [String: Any]) ?? [:]
                    for (k, v) in cats {
                        let start = (out[k] as? [String: Any]) ?? reportRuleDefault
                        out[k] = (v as? [String: Any]).map { deepMerge(start, $0) } ?? start
                    }
                    rep["categories"] = out
                    merged["reports"] = rep
                }
                if let tpl = p["template"] as? [String: Any], let blocks = tpl["blocks"] {
                    var t = (merged["template"] as? [String: Any]) ?? [:]
                    t["blocks"] = blocks // arrays replace; missing kinds are re-added by normalize()
                    merged["template"] = t
                }
                mergedProfiles.append(merged)
            }
        }
        var top = input
        top.removeValue(forKey: "profiles")
        defaultsObj = deepMerge(defaultsObj, top)
        if !mergedProfiles.isEmpty { defaultsObj["profiles"] = mergedProfiles }

        do {
            let mergedData = try JSONSerialization.data(withJSONObject: defaultsObj)
            var settings = try JSONDecoder().decode(AppSettings.self, from: mergedData)
            settings.schemaVersion = AppSettings.currentSchemaVersion
            settings.normalize()
            return settings
        } catch let DecodingError.dataCorrupted(ctx) {
            throw ImportError.invalid(describe(ctx))
        } catch let DecodingError.typeMismatch(_, ctx) {
            throw ImportError.invalid(describe(ctx))
        } catch let DecodingError.valueNotFound(_, ctx) {
            throw ImportError.invalid(describe(ctx))
        } catch let DecodingError.keyNotFound(key, ctx) {
            throw ImportError.invalid("missing \(key.stringValue) at \(describe(ctx))")
        }
    }

    static func describe(_ ctx: DecodingError.Context) -> String {
        let path = ctx.codingPath.map { $0.stringValue }.joined(separator: ".")
        return path.isEmpty ? ctx.debugDescription : "\(path): \(ctx.debugDescription)"
    }

    static func jsonObject<T: Encodable>(_ v: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(v)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Recursively overlays `over` onto `base`. Objects merge; everything else replaces.
    static func deepMerge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
        var out = base
        for (k, v) in over {
            if let vb = out[k] as? [String: Any], let vo = v as? [String: Any] {
                out[k] = deepMerge(vb, vo)
            } else if v is NSNull {
                out.removeValue(forKey: k)
            } else {
                out[k] = v
            }
        }
        return out
    }

    /// Adds the profiles from `imported` to `current` (renaming duplicates) instead of replacing everything.
    public static func mergeProfiles(from imported: AppSettings, into current: AppSettings) -> AppSettings {
        var result = current
        for var p in imported.profiles {
            if let i = result.profiles.firstIndex(where: { $0.id == p.id }) {
                result.profiles[i] = p
            } else {
                if result.profiles.contains(where: { $0.name == p.name }) { p.name += " (imported)" }
                result.profiles.append(p)
            }
        }
        return result
    }
}
