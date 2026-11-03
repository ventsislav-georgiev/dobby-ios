import Foundation

// #483: the on-device lanes' decisions and bodies (Dobby/Playback/OnDeviceRouting.swift), checked
// against what dobby-android's lanes answer for the same input, since the page reads either side's
// bytes with the same code. The row shapes are the bundled Python entry's and are checked there.
@main
enum OnDeviceRoutingCheck {
    static func check(_ condition: Bool, _ what: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(what) (#483)\n".utf8))
            exit(1)
        }
    }

    typealias R = OnDeviceRouting

    static func main() {
        // Full search: the query, then the series pair (the key gate before both is the Python entry's).
        let full = ["imdbId": "tt1", "type": "movie", "title": "T"]
        check(R.fullSearchPlan(["imdbId": "tt1", "type": "movie"])
              == .answer(.error(400, "Missing imdbId, type or title parameter")), "no title is a 400")
        check(R.fullSearchPlan(["imdbId": "tt1", "type": "series", "title": "T", "season": "1"])
              == .answer(.error(400, "Missing season or episode for series")), "a series needs season and episode")
        guard case let .search(key, params, refresh) = R.fullSearchPlan(
            ["imdbId": "tt1", "type": "series", "title": "T", "season": "1", "episode": "2",
             "episodeTitle": "E", "noSeasons": "3", "refresh": "1"]) else { return check(false, "a series plan") }
        check(key == "tt1-series-s1e2" && refresh, "series cache key and refresh")
        check(params["imdb"] == "tt1" && params["episode_title"] == "E" && params["no_seasons"] == "3" && params["year"] == "",
              "the Pi script's argv names, absent as empty")
        guard case .search(_, _, false) = R.fullSearchPlan(full) else { return check(false, "a movie plan") }

        // Rows are the Python entry's [hash, streamJson], passed through untouched.
        let big = R.Found(row: ["abc", "{\"id\":\"abc\",\"title\":\"Rel\\n👤 12\"}"])!
        let bare = R.Found(hash: "def", json: "{\"id\":\"def\"}")
        check(R.Found(row: ["a"]) == nil && R.Found(row: ["a", ""]) == nil && R.Found(row: [1, "{}"]) == nil,
              "a short, empty or non-string Python row is dropped")

        // The cache split: a missing flag is uncached; a cache hit says so.
        let split = R.streamsJson([big, bare], [true], fromCache: true)
        check(split == "{\"streams\":[\(big.json)],\"uncached\":[\(bare.json)],\"cached\":true}", "split: \(split)")
        check(!R.streamsJson([big], [false], fromCache: false).contains("\"cached\""), "a fresh search carries no cached key")

        // /partial: counters before the first report, done flag, rows split only with cache=1.
        check(R.partialJson([], progress: nil, cached: nil)
              == "{\"exists\":true,\"done\":false,\"providersDone\":0,\"providersTotal\":0,\"count\":0}", "partial before progress")
        let live = R.partialJson([big], progress: [1, 3, 5], cached: [false])
        check(live == "{\"exists\":true,\"done\":true,\"providersDone\":3,\"providersTotal\":5,\"count\":1"
              + ",\"streams\":[],\"uncached\":[\(big.json)]}", "partial with cache=1: \(live)")

        // The result cache: bound, file name, round trip.
        check(R.cacheLimit(nil) == 20 && R.cacheLimit("x") == 20 && R.cacheLimit(" 0 ") == 0 && R.cacheLimit("999") == 500
              && R.cacheLimit("-3") == 0 && R.cacheLimit(NSNumber(value: 7)) == 7, "cache size read, defaulted and clamped")
        check(R.cacheFileName("tt1-series-s1e2") == "tt1-series-s1e2.tsv" && R.cacheFileName("a/b:c") == "a_b_c.tsv",
              "cache file names keep letters, digits and dashes only")
        let dirty = R.Found(hash: "h", json: "{\"t\":\"a\tb\nc\"}")
        check(R.parseTsv(R.tsv([dirty, big]) + "short\n")
              == [R.Found(hash: "h", json: "{\"t\":\"a b c\"}"), big],
              "tsv round trip, a stray tab or newline blanked, a line without a tab skipped")

        // Subtitles: search query, rows with their cached flag.
        check(R.subSearchPlan(["imdbId": "123", "type": "movie"]).answer == .error(400, "Missing imdbId or type parameter"),
              "an imdb id without tt is a 400")
        check(R.subSearchPlan(["imdbId": "tt1"]).answer != nil, "no type is a 400")
        let plan = R.subSearchPlan(["imdbId": "tt1", "type": "episode"])
        check(plan.answer == nil && plan.type == "movie" && plan.languages == "en", "type normalised, languages default en")
        check(R.fnv1a("a") == "af63dc4c8601ec8c", "the cache key is FNV-1a 64")
        let subs = R.subtitlesJson([["id": "x-1", "lang": "bg", "fileName": "a/b.srt"], ["lang": "en"], ["id": "x-2"]]) { $0 == "x-1" }
        check(subs == "{\"subtitles\":[{\"cached\":true,\"fileName\":\"a/b.srt\",\"id\":\"x-1\",\"lang\":\"bg\"},"
              + "{\"cached\":false,\"id\":\"x-2\"}]}", "rows keep their fields, gain cached by id, a row without an id is dropped: \(subs)")
        check(R.subtitlesJson([]) { _ in true } == "{\"subtitles\":[]}", "no rows is an empty list")

        // /fetch fields: the POST body as the Pi takes it, the query otherwise.
        let posted = R.fetchFields(query: ["provider": "x"],
                                   body: Data("{\"provider\":\"y\",\"id\":7,\"label\":null,\"service\":\"s\"}".utf8))
        check(posted == ["provider": "y", "id": "7", "service": "s"], "POST body wins, null absent, number kept: \(posted)")
        check(R.fetchFields(query: ["provider": "y"], body: nil) == ["provider": "y"], "GET reads the query")
        check(R.cachedResponse("k1.srt", lang: "bg", label: nil, fromCache: false)
              == "{\"url\":\"/api/subtitles/file/k1/k1.srt\",\"fileName\":\"k1.srt\",\"lang\":\"bg\",\"cached\":false}",
              "fetch answer, label absent")

        // /file: the name must start with its key and both must be safe.
        check(R.fileName(forFilePath: "k1/k1.srt") == "k1.srt", "a cached name is served")
        for bad in ["k1/k2.srt", "k1/", "/k1.srt", "k1/k1..srt", "k1/k1.srt/x", "k1", "k 1/k 1.srt"] {
            check(R.fileName(forFilePath: bad) == nil, "\(bad) is a 404")
        }
        check(R.extensionOf("/t/a.VTT") == "vtt" && R.extensionOf("/t.d/a") == "srt" && R.extensionOf("/t/a.toolong") == "srt",
              "extension kept only when 1 to 5 alphanumerics")
        check(R.contentType("k.srt") == "application/x-subrip; charset=utf-8" && R.contentType("k.ass") == "text/plain; charset=utf-8",
              "content types")

        // Offline sidecar URLs on the scheme.
        check(R.sidecar(host: "subtitles", path: "/fetch", query: ["id": "x-1"]).id == "x-1", "fetch?id names a row")
        check(R.sidecar(host: "Subtitles", path: "/file/k1/k1.srt", query: [:]).fileName == "k1.srt", "file path names a file")
        check(R.sidecar(host: "streaming", path: "/fetch", query: ["id": "x"]) == (nil, nil), "another host names nothing")

        // Shared plumbing.
        check(R.query("a=1+2&b=%2B&c&a=3&d=%E2%9C%93") == ["a": "3", "b": "+", "c": "", "d": "✓"],
              "query: + is a space, later duplicate wins, bare name is empty")
        check(R.quote("a\"b\\c\u{1}") == "\"a\\\"b\\\\c\\u0001\"", "quote escapes structure and controls")
        check(R.normalizeLanguage(" ENG ") == "en" && R.normalizeLanguage("pt-BR") == "pt" && R.normalizeLanguage("bul") == "bg",
              "language codes normalised")
        print("PASS: OnDeviceRouting answers the Android lanes' status codes and bodies: full search, partial, cache, subtitle search, fetch and file (#483)")
    }
}
