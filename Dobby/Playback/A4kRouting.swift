import Foundation

/// #483: the pure half of the a4k lanes (Dobby/Web/A4kLane.swift): every decision, JSON body and
/// file name, with no WebKit, no Python and no disk, so Tests/A4kRoutingCheck.swift runs it alone.
/// A port of dobby-android's FullSearchLane and SubtitlesLane (themselves ports of the Pi's
/// StreamingRoutes/SubtitleRoutes), so the page reads the same bodies and status codes whichever
/// side answers. Here and not in Dobby/Web because run-checks.sh compiles pure checks from
/// Dobby/Playback.
enum A4kRouting {
    struct Answer: Equatable {
        let status: Int
        let contentType: String
        let body: Data

        var text: String { String(decoding: body, as: UTF8.self) }

        static func json(_ status: Int, _ text: String) -> Answer {
            Answer(status: status, contentType: "application/json", body: Data(text.utf8))
        }

        static func error(_ status: Int, _ message: String) -> Answer {
            json(status, "{\"error\":" + A4kRouting.quote(message) + "}")
        }

        static let notFound = Answer(status: 404, contentType: "text/plain", body: Data())
    }

    // MARK: - Full search (FullSearchLane)

    /// The scrape's own budget handed to Python, and how long the lane waits for it: 40 s plus
    /// FullSearchLane's 20 s slack for the first import and the hand-back.
    static let budgetSeconds = 40.0
    static let waitSeconds = 60.0
    static let defaultCacheSize = 20

    /// One scraped torrent, normalised as FullSearchLane.Found normalises it.
    struct Torrent: Equatable {
        let hash: String
        let title: String
        let seeds: String
        let sizeMb: Double
        let provider: String

        init(hash: String, title: String, seeds: String, sizeMb: Double, provider: String) {
            self.hash = hash
            self.title = title
            self.seeds = seeds.isEmpty ? "0" : seeds
            self.sizeMb = sizeMb
            self.provider = provider.isEmpty ? "a4k" : provider
        }

        /// `[hash, title, seeds, sizeMb, provider]` as dobby_apple.py hands a row back.
        init?(row: [String]) {
            guard row.count >= 5 else { return nil }
            self.init(hash: row[0], title: row[1], seeds: row[2], sizeMb: A4kRouting.number(row[3]), provider: row[4])
        }
    }

    enum FullSearchPlan: Equatable {
        case answer(Answer)
        case search(cacheKey: String, params: [String: String], refresh: Bool)
    }

    /// FullSearchLane.fullsearch's checks, in its order: the key first (401), then the query (400).
    static func fullSearchPlan(_ query: [String: String], apiKey: String?) -> FullSearchPlan {
        guard let apiKey, !apiKey.isEmpty else { return .answer(.error(401, "Premiumize API key not configured")) }
        let imdbId = query["imdbId"] ?? "", type = query["type"] ?? "", title = query["title"] ?? ""
        if imdbId.isEmpty || type.isEmpty || title.isEmpty {
            return .answer(.error(400, "Missing imdbId, type or title parameter"))
        }
        var cacheKey = imdbId + "-" + type
        if type == "series" {
            let season = query["season"] ?? "", episode = query["episode"] ?? ""
            if season.isEmpty || episode.isEmpty { return .answer(.error(400, "Missing season or episode for series")) }
            cacheKey += "-s" + season + "e" + episode
        }
        let params = ["type": type, "imdb": imdbId, "title": title, "year": query["year"] ?? "",
                      "season": query["season"] ?? "", "episode": query["episode"] ?? "",
                      "episode_title": query["episodeTitle"] ?? "", "no_seasons": query["noSeasons"] ?? ""]
        return .search(cacheKey: cacheKey, params: params, refresh: query["refresh"] == "1")
    }

    /// Byte for byte FullSearchLane.shape (and the Pi's a4kStreamShape), emoji included: the
    /// picker renders this title string.
    static func shape(_ t: Torrent) -> String {
        let sizeGb = t.sizeMb > 0 ? String(format: "%.2f", t.sizeMb / 1024) : ""
        let title = t.title + (sizeGb.isEmpty
            ? "\n👤 " + t.seeds + " ⚙️ a4k/" + t.provider
            : "\n👤 " + t.seeds + " 💾 " + sizeGb + " GB ⚙️ a4k/" + t.provider)
        return "{\"name\":" + quote("[A4K+] " + t.provider) + ",\"title\":" + quote(title)
            + ",\"infoHash\":" + quote(t.hash) + "}"
    }

    /// The rows on one side of the Premiumize split. A missing flag reads as not cached.
    static func shapes(_ found: [Torrent], _ cached: [Bool], wantCached: Bool) -> String {
        let picked = found.indices.filter { (($0 < cached.count) && cached[$0]) == wantCached }
        return "[" + picked.map { shape(found[$0]) }.joined(separator: ",") + "]"
    }

    static func streamsJson(_ found: [Torrent], _ cached: [Bool], fromCache: Bool) -> String {
        "{\"streams\":" + shapes(found, cached, wantCached: true)
            + ",\"uncached\":" + shapes(found, cached, wantCached: false)
            + (fromCache ? ",\"cached\":true" : "") + "}"
    }

    /// FullSearchLane.partial. `progress` is `[done, providersDone, providersTotal]` (nil before
    /// the first provider report); `cached` is nil without `cache=1`.
    static func partialJson(_ found: [Torrent], progress: [Int]?, cached: [Bool]?) -> String {
        let p = progress ?? [0, 0, 0]
        var out = "{\"exists\":true,\"done\":\(p.first == 1)"
            + ",\"providersDone\":\(p.count > 1 ? p[1] : 0),\"providersTotal\":\(p.count > 2 ? p[2] : 0)"
            + ",\"count\":\(found.count)"
        if let cached {
            out += ",\"streams\":" + shapes(found, cached, wantCached: true)
                + ",\"uncached\":" + shapes(found, cached, wantCached: false)
        }
        return out + "}"
    }

    /// `a4kCacheSize` from the settings document, string or number; 20 when unset or unreadable,
    /// clamped to 0...500, and 0 turns the cache off.
    static func cacheLimit(_ raw: Any?) -> Int {
        let text: String
        switch raw {
        case let s as String: text = s.trimmingCharacters(in: .whitespaces)
        case let n as NSNumber: text = n.stringValue
        default: return defaultCacheSize
        }
        guard let value = Int(text) else { return defaultCacheSize }
        return max(0, min(500, value))
    }

    /// One file per title: anything but a letter, a digit or a dash becomes an underscore.
    static func cacheFileName(_ key: String) -> String {
        String(key.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }) + ".tsv"
    }

    static func tsv(_ found: [Torrent]) -> String {
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }
        return found.map { "\($0.hash)\t\($0.seeds)\t\($0.sizeMb)\t\(clean($0.provider))\t\(clean($0.title))\n" }.joined()
    }

    static func parseTsv(_ text: String) -> [Torrent] {
        text.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard p.count >= 5 else { return nil }
            return Torrent(hash: p[0], title: p[4], seeds: p[1], sizeMb: number(p[2]), provider: p[3])
        }
    }

    /// Premiumize's cache/check answer, one flag per hash in order; all false on anything odd,
    /// and a short answer padded rather than trusted (PremiumizeCacheCheck.parse).
    static func cachedFlags(_ data: Data?, count: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: count)
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let flags = object["response"] as? [Any] else { return out }
        for i in 0..<min(count, flags.count) { out[i] = flags[i] as? Bool ?? false }
        return out
    }

    // MARK: - Subtitles (SubtitlesLane)

    static let filePrefix = "/api/subtitles/file/"

    /// One a4kSubtitles result as the sink receives it.
    struct Sub: Equatable {
        let service: String
        let lang: String
        let name: String
        let args: String

        /// `[service, lang, name, actionArgsJson]` as dobby_apple.py hands a row back.
        init?(row: [String]) {
            guard row.count >= 4 else { return nil }
            service = row[0]; lang = row[1]; name = row[2]; args = row[3]
        }

        /// The dedup, cache and remembered-pick key (SubtitleRoutes.swift:118 on the Pi).
        var id: String { "a4k-" + A4kRouting.fnv1a(service + "|" + args) }
    }

    /// The query of an a4k subtitle search, or the 400 for a bad one.
    static func subSearchPlan(_ query: [String: String]) -> (answer: Answer?, type: String, languages: String) {
        guard let imdbId = query["imdbId"], imdbId.hasPrefix("tt"), let rawType = query["type"] else {
            return (.error(400, "Missing imdbId or type parameter"), "", "")
        }
        return (nil, rawType == "series" ? "series" : "movie", query["languages"] ?? "en")
    }

    /// `OnlineSubtitle` as the Pi encodes it: an empty name drops `fileName` and `release`.
    static func subShape(_ s: Sub, cached: Bool) -> String {
        let lang = normalizeLanguage(s.lang)
        var out = "{\"provider\":\"a4k\",\"id\":" + quote(s.id) + ",\"lang\":" + quote(lang)
            + ",\"label\":" + quote(label(s.service, s.name, lang))
        if !s.name.isEmpty { out += ",\"fileName\":" + quote(s.name) }
        out += ",\"url\":\"\""
        if !s.name.isEmpty { out += ",\"release\":" + quote(s.name) }
        return out + ",\"cached\":\(cached),\"a4kService\":" + quote(s.service) + ",\"a4kArgs\":" + quote(s.args) + "}"
    }

    static func label(_ service: String, _ name: String, _ language: String) -> String {
        let svc = service.isEmpty ? "a4k" : service.prefix(1).uppercased() + service.dropFirst()
        return svc + " - " + language.uppercased() + " · " + (name.isEmpty ? svc : name)
    }

    /// Which a4kSubtitles services run (SubtitlesLane.settingsJson, the Pi's _a4k_settings):
    /// anonymous ones always, bsplayer never (filehash only), OpenSubtitles on both credentials,
    /// subdl and subsource on their key. Apple builds carry no built-in credential defaults.
    static func subSettings(osUser: String?, osPass: String?, subdl: String?, subsource: String?) -> [String: String] {
        func trimmed(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let user = trimmed(osUser), pass = trimmed(osPass), subdlKey = trimmed(subdl), subsourceKey = trimmed(subsource)
        return ["general.timeout": "20", "general.results_limit": "200", "general.auto_search": "false",
                "general.auto_download": "false", "bsplayer.enabled": "false", "podnadpisi.enabled": "true",
                "addic7ed.enabled": "true", "subssabbz.enabled": "true", "subsunacs.enabled": "true",
                "opensubtitles.enabled": "\(!user.isEmpty && !pass.isEmpty)",
                "opensubtitles.username": user, "opensubtitles.password": pass,
                "subdl.enabled": "\(!subdlKey.isEmpty)", "subdl.apikey": subdlKey,
                "subsource.enabled": "\(!subsourceKey.isEmpty)", "subsource.apikey": subsourceKey]
    }

    /// The fetch's fields: the POST body as the Pi takes it, else the GET query (Android's
    /// spelling). Scalars become strings; JSON null is absent.
    static func fetchFields(query: [String: String], body: Data?) -> [String: String] {
        guard let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return query }
        var out: [String: String] = [:]
        for (key, value) in object {
            switch value {
            case let s as String: out[key] = s
            case let n as NSNumber: out[key] = n.stringValue
            default: break
            }
        }
        return out
    }

    /// CachedSubtitleResponse. `label` absent from the request is absent from the body.
    static func cachedResponse(_ fileName: String, lang: String, label: String?, fromCache: Bool) -> String {
        let key = fileName.split(separator: ".", maxSplits: 1).first.map(String.init) ?? fileName
        var out = "{\"url\":" + quote(filePrefix + key + "/" + fileName) + ",\"fileName\":" + quote(fileName)
            + ",\"lang\":" + quote(lang)
        if let label { out += ",\"label\":" + quote(label) }
        return out + ",\"cached\":\(fromCache)}"
    }

    /// The cache file a `/file/<key>/<name>` path may read, or nil for the 404: the name must
    /// start with its key and both must pass the Pi's allowlist, so no path escapes the cache.
    static func fileName(forFilePath rest: String) -> String? {
        guard let slash = rest.firstIndex(of: "/"), slash != rest.startIndex,
              rest.index(after: slash) != rest.endIndex else { return nil }
        let key = String(rest[..<slash]), name = String(rest[rest.index(after: slash)...])
        guard name.hasPrefix(key + "."), isSafeFileName(key), isSafeFileName(name) else { return nil }
        return name
    }

    /// What an offline sidecar URL on the scheme names in the lane's cache (#483: URLSession
    /// cannot fetch `dobby-api:`): a row id for `/fetch?id=…`, a file name for `/file/<key>/<name>`.
    static func sidecar(host: String?, path: String, query: [String: String]) -> (id: String?, fileName: String?) {
        guard host?.lowercased() == "subtitles" else { return (nil, nil) }
        if path == "/fetch", let id = query["id"], !id.isEmpty { return (id, nil) }
        if path.hasPrefix("/file/") { return (nil, fileName(forFilePath: String(path.dropFirst("/file/".count)))) }
        return (nil, nil)
    }

    static func contentType(_ fileName: String) -> String {
        switch extensionOf(fileName) {
        case "vtt": return "text/vtt; charset=utf-8"
        case "srt": return "application/x-subrip; charset=utf-8"
        default: return "text/plain; charset=utf-8"
        }
    }

    /// The downloaded file's own extension when it is one to five lowercase alphanumerics, else srt.
    static func extensionOf(_ path: String) -> String {
        guard let dot = path.lastIndex(of: ".") else { return "srt" }
        let ext = path[path.index(after: dot)...].lowercased()
        return (1...5).contains(ext.count) && ext.allSatisfy({ ($0.isASCII && $0.isLetter) || ($0.isASCII && $0.isNumber) }) ? ext : "srt"
    }

    static func isSafeFileName(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("..")
            && value.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    /// The subtitle cache key: 64-bit FNV-1a over the UTF-8 bytes, lowercase hex, no padding.
    static func fnv1a(_ value: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(hash, radix: 16)
    }

    static func normalizeLanguage(_ value: String) -> String {
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch code {
        case "eng": return "en"
        case "spa": return "es"
        case "fre", "fra": return "fr"
        case "ger", "deu": return "de"
        case "ita": return "it"
        case "por": return "pt"
        case "dut", "nld": return "nl"
        case "rus": return "ru"
        case "jpn": return "ja"
        case "kor": return "ko"
        case "chi", "zho": return "zh"
        case "ara": return "ar"
        case "hin": return "hi"
        case "bul": return "bg"
        default: return code.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? code
        }
    }

    // MARK: - Shared

    /// The raw query as Android's lanes read it: split on `&` and the first `=`, `+` is a space,
    /// then percent-decoding; a later duplicate wins.
    static func query(_ raw: String?) -> [String: String] {
        var out: [String: String] = [:]
        for pair in (raw ?? "").split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ s: Substring) -> String {
                let spaced = s.replacingOccurrences(of: "+", with: " ")
                return spaced.removingPercentEncoding ?? spaced
            }
            out[decode(parts[0])] = parts.count > 1 ? decode(parts[1]) : ""
        }
        return out
    }

    /// Minimal JSON string literal, FullSearchLane.quote: UTF-8 raw, structural characters escaped.
    static func quote(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    static func number(_ text: String) -> Double {
        Double(text.trimmingCharacters(in: .whitespaces)) ?? 0
    }
}
