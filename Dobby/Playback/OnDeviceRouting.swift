import Foundation

/// #483: the pure half of the on-device lanes (Dobby/Web/OnDeviceLane.swift): every decision, JSON
/// body and file name, with no WebKit, no Python and no disk, so Tests/OnDeviceRoutingCheck.swift
/// runs it alone. A port of dobby-android's full-search and subtitle lanes (themselves ports of the
/// Pi's routes), so the page reads the same bodies and status codes whichever side answers. The
/// rows themselves are shaped by the bundled Python entry and stay opaque here. Here and not in
/// Dobby/Web because run-checks.sh compiles pure checks from Dobby/Playback.
enum OnDeviceRouting {
    struct Answer: Equatable {
        let status: Int
        let contentType: String
        let body: Data

        var text: String { String(decoding: body, as: UTF8.self) }

        static func json(_ status: Int, _ text: String) -> Answer {
            Answer(status: status, contentType: "application/json", body: Data(text.utf8))
        }

        static func error(_ status: Int, _ message: String) -> Answer {
            json(status, "{\"error\":" + OnDeviceRouting.quote(message) + "}")
        }

        static let notFound = Answer(status: 404, contentType: "text/plain", body: Data())
    }

    // MARK: - Full search

    /// The search's own budget handed to Python, and how long the lane waits for it: 40 s plus
    /// Android's 20 s slack for the first import and the hand-back.
    static let budgetSeconds = 40.0
    static let waitSeconds = 60.0
    static let defaultCacheSize = 20

    /// One search result: its hash (what the cache split checks) and the stream object the page
    /// renders, shaped by the Python entry and passed through untouched.
    struct Found: Equatable {
        let hash: String
        let json: String

        init(hash: String, json: String) {
            self.hash = hash
            self.json = json
        }

        /// `[hash, streamJson]` as the Python entry hands a row back.
        init?(row: [Any]) {
            guard row.count >= 2, let hash = row[0] as? String, let json = row[1] as? String, !json.isEmpty else { return nil }
            self.init(hash: hash, json: json)
        }
    }

    enum FullSearchPlan: Equatable {
        case answer(Answer)
        case search(cacheKey: String, params: [String: String], refresh: Bool)
    }

    /// Android's full-search query checks (400). Its key check (401) comes first and is the
    /// Python entry's, asked by the lane before this.
    static func fullSearchPlan(_ query: [String: String]) -> FullSearchPlan {
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

    /// The rows on one side of the cache split. A missing flag reads as not cached.
    static func shapes(_ found: [Found], _ cached: [Bool], wantCached: Bool) -> String {
        let picked = found.indices.filter { (($0 < cached.count) && cached[$0]) == wantCached }
        return "[" + picked.map { found[$0].json }.joined(separator: ",") + "]"
    }

    static func streamsJson(_ found: [Found], _ cached: [Bool], fromCache: Bool) -> String {
        "{\"streams\":" + shapes(found, cached, wantCached: true)
            + ",\"uncached\":" + shapes(found, cached, wantCached: false)
            + (fromCache ? ",\"cached\":true" : "") + "}"
    }

    /// Android's partial answer. `progress` is `[done, sourcesDone, sourcesTotal]` (nil before
    /// the first report); `cached` is nil without `cache=1`.
    static func partialJson(_ found: [Found], progress: [Int]?, cached: [Bool]?) -> String {
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

    /// The result-cache bound the Python entry reads out of the settings document, string or
    /// number; 20 when unset or unreadable, clamped to 0...500, and 0 turns the cache off.
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

    /// One `hash<TAB>streamJson` line per row. The JSON carries no raw tab or line break (the
    /// entry's encoder escapes them inside strings); a stray one is blanked rather than trusted.
    static func tsv(_ found: [Found]) -> String {
        func clean(_ s: String) -> String {
            s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }
        return found.map { clean($0.hash) + "\t" + clean($0.json) + "\n" }.joined()
    }

    static func parseTsv(_ text: String) -> [Found] {
        text.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            return p.count == 2 ? Found(row: p) : nil
        }
    }

    // MARK: - Subtitles

    static let filePrefix = "/api/subtitles/file/"

    /// The query of a subtitle search, or the 400 for a bad one.
    static func subSearchPlan(_ query: [String: String]) -> (answer: Answer?, type: String, languages: String) {
        guard let imdbId = query["imdbId"], imdbId.hasPrefix("tt"), let rawType = query["type"] else {
            return (.error(400, "Missing imdbId or type parameter"), "", "")
        }
        return (nil, rawType == "series" ? "series" : "movie", query["languages"] ?? "en")
    }

    /// The search answer: the Python entry's rows as it shaped them, each with `cached` set from
    /// this device's subtitle cache by its `id`. A row without an id is dropped.
    static func subtitlesJson(_ rows: [[String: Any]], cached: (String) -> Bool) -> String {
        let shaped: [[String: Any]] = rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            var out = row
            out["cached"] = cached(id)
            return out
        }
        let data = try? JSONSerialization.data(withJSONObject: ["subtitles": shaped], options: [.sortedKeys, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{\"subtitles\":[]}"
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

    /// Minimal JSON string literal: UTF-8 raw, structural characters escaped.
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
}
