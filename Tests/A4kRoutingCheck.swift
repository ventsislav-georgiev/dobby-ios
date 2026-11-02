import Foundation

// #483: the a4k lanes' decisions and bodies (Dobby/Playback/A4kRouting.swift), checked against what
// dobby-android's FullSearchLane and SubtitlesLane answer for the same input, since the page reads
// either side's bytes with the same code.
@main
enum A4kRoutingCheck {
    static func check(_ condition: Bool, _ what: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(what) (#483)\n".utf8))
            exit(1)
        }
    }

    typealias R = A4kRouting

    static func main() {
        // Full search: the key is checked before the query, then the query, then the series pair.
        let full = ["imdbId": "tt1", "type": "movie", "title": "T"]
        check(R.fullSearchPlan([:], apiKey: nil) == .answer(.error(401, "Premiumize API key not configured")),
              "no key is a 401 even when the query is bad too")
        check(R.fullSearchPlan(["imdbId": "tt1", "type": "movie"], apiKey: "k")
              == .answer(.error(400, "Missing imdbId, type or title parameter")), "no title is a 400")
        check(R.fullSearchPlan(["imdbId": "tt1", "type": "series", "title": "T", "season": "1"], apiKey: "k")
              == .answer(.error(400, "Missing season or episode for series")), "a series needs season and episode")
        guard case let .search(key, params, refresh) = R.fullSearchPlan(
            ["imdbId": "tt1", "type": "series", "title": "T", "season": "1", "episode": "2",
             "episodeTitle": "E", "noSeasons": "3", "refresh": "1"], apiKey: "k") else { return check(false, "a series plan") }
        check(key == "tt1-series-s1e2" && refresh, "series cache key and refresh")
        check(params["imdb"] == "tt1" && params["episode_title"] == "E" && params["no_seasons"] == "3" && params["year"] == "",
              "the Pi script's argv names, absent as empty")
        guard case .search(_, _, false) = R.fullSearchPlan(full, apiKey: "k") else { return check(false, "a movie plan") }

        // The Torrentio-shaped row, byte for byte FullSearchLane.shape.
        let big = R.Torrent(hash: "abc", title: "Rel", seeds: "12", sizeMb: 2048, provider: "tpb")
        check(R.shape(big) == "{\"name\":\"[A4K+] tpb\",\"title\":\"Rel\\n👤 12 💾 2.00 GB ⚙️ a4k/tpb\",\"infoHash\":\"abc\"}",
              "shape with a size: \(R.shape(big))")
        let bare = R.Torrent(row: ["def", "R2", "", "0", ""])!
        check(R.shape(bare) == "{\"name\":\"[A4K+] a4k\",\"title\":\"R2\\n👤 0 ⚙️ a4k/a4k\",\"infoHash\":\"def\"}",
              "shape without a size, empty seeds and provider defaulted: \(R.shape(bare))")
        check(R.Torrent(row: ["a", "b", "c", "d"]) == nil, "a short Python row is dropped")

        // The Premiumize split: a missing flag is uncached; a cache hit says so.
        let split = R.streamsJson([big, bare], [true], fromCache: true)
        check(split == "{\"streams\":[\(R.shape(big))],\"uncached\":[\(R.shape(bare))],\"cached\":true}", "split: \(split)")
        check(!R.streamsJson([big], [false], fromCache: false).contains("\"cached\""), "a fresh scrape carries no cached key")
        check(R.cachedFlags(Data("{\"response\":[true,false]}".utf8), count: 3) == [true, false, false], "short answer padded")
        check(R.cachedFlags(Data("{\"response\":[\"yes\",true]}".utf8), count: 2) == [false, true], "a non-bool flag is false")
        check(R.cachedFlags(Data("<html>".utf8), count: 2) == [false, false], "garbage is all false")

        // /partial: counters before the first report, done flag, rows split only with cache=1.
        check(R.partialJson([], progress: nil, cached: nil)
              == "{\"exists\":true,\"done\":false,\"providersDone\":0,\"providersTotal\":0,\"count\":0}", "partial before progress")
        let live = R.partialJson([big], progress: [1, 3, 5], cached: [false])
        check(live == "{\"exists\":true,\"done\":true,\"providersDone\":3,\"providersTotal\":5,\"count\":1"
              + ",\"streams\":[],\"uncached\":[\(R.shape(big))]}", "partial with cache=1: \(live)")

        // The result cache: bound, file name, round trip.
        check(R.cacheLimit(nil) == 20 && R.cacheLimit("x") == 20 && R.cacheLimit(" 0 ") == 0 && R.cacheLimit("999") == 500
              && R.cacheLimit("-3") == 0 && R.cacheLimit(NSNumber(value: 7)) == 7, "a4kCacheSize read, defaulted and clamped")
        check(R.cacheFileName("tt1-series-s1e2") == "tt1-series-s1e2.tsv" && R.cacheFileName("a/b:c") == "a_b_c.tsv",
              "cache file names keep letters, digits and dashes only")
        let dirty = R.Torrent(hash: "h", title: "a\tb\nc", seeds: "4", sizeMb: 1.5, provider: "p")
        check(R.parseTsv(R.tsv([dirty, big]) + "short\tline\n")
              == [R.Torrent(hash: "h", title: "a b c", seeds: "4", sizeMb: 1.5, provider: "p"), big],
              "tsv round trip, tabs and newlines cleaned, short lines skipped")

        // Subtitles: search query, row shape, provider gating.
        check(R.subSearchPlan(["imdbId": "123", "type": "movie"]).answer == .error(400, "Missing imdbId or type parameter"),
              "an imdb id without tt is a 400")
        check(R.subSearchPlan(["imdbId": "tt1"]).answer != nil, "no type is a 400")
        let plan = R.subSearchPlan(["imdbId": "tt1", "type": "episode"])
        check(plan.answer == nil && plan.type == "movie" && plan.languages == "en", "type normalised, languages default en")
        let row = R.Sub(row: ["subssabbz", "bul", "Rel.srt", "{\"id\":1}"])!
        check(row.id == "a4k-839020a88e6e95fe" && R.fnv1a("a") == "af63dc4c8601ec8c", "row id is FNV-1a 64 of service|args")
        check(R.subShape(row, cached: true) == "{\"provider\":\"a4k\",\"id\":\"a4k-839020a88e6e95fe\",\"lang\":\"bg\""
              + ",\"label\":\"Subssabbz - BG · Rel.srt\",\"fileName\":\"Rel.srt\",\"url\":\"\",\"release\":\"Rel.srt\""
              + ",\"cached\":true,\"a4kService\":\"subssabbz\",\"a4kArgs\":\"{\\\"id\\\":1}\"}", "subtitle row shape")
        let nameless = R.subShape(R.Sub(row: ["", "en", "", "{}"])!, cached: false)
        check(!nameless.contains("fileName") && !nameless.contains("release") && nameless.contains("\"label\":\"a4k - EN · a4k\""),
              "an empty name drops fileName and release: \(nameless)")
        let anon = R.subSettings(osUser: "u", osPass: "  ", subdl: nil, subsource: "s")
        check(anon["opensubtitles.enabled"] == "false" && anon["subdl.enabled"] == "false" && anon["subsource.enabled"] == "true"
              && anon["bsplayer.enabled"] == "false" && anon["subssabbz.enabled"] == "true" && anon["subsunacs.enabled"] == "true",
              "OpenSubtitles needs both credentials, keys gate their service, bsplayer stays off")
        check(R.subSettings(osUser: "u", osPass: "p", subdl: nil, subsource: nil)["opensubtitles.enabled"] == "true",
              "both OpenSubtitles credentials turn it on")

        // /fetch fields: the POST body as the Pi takes it, the query otherwise.
        let posted = R.fetchFields(query: ["provider": "x"],
                                   body: Data("{\"provider\":\"a4k\",\"id\":7,\"label\":null,\"a4kService\":\"s\"}".utf8))
        check(posted == ["provider": "a4k", "id": "7", "a4kService": "s"], "POST body wins, null absent, number kept: \(posted)")
        check(R.fetchFields(query: ["provider": "a4k"], body: nil) == ["provider": "a4k"], "GET reads the query")
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
        check(R.sidecar(host: "subtitles", path: "/fetch", query: ["id": "a4k-1"]).id == "a4k-1", "fetch?id names a row")
        check(R.sidecar(host: "Subtitles", path: "/file/k1/k1.srt", query: [:]).fileName == "k1.srt", "file path names a file")
        check(R.sidecar(host: "streaming", path: "/fetch", query: ["id": "x"]) == (nil, nil), "another host names nothing")

        // Shared plumbing.
        check(R.query("a=1+2&b=%2B&c&a=3&d=%E2%9C%93") == ["a": "3", "b": "+", "c": "", "d": "✓"],
              "query: + is a space, later duplicate wins, bare name is empty")
        check(R.quote("a\"b\\c\u{1}") == "\"a\\\"b\\\\c\\u0001\"", "quote escapes structure and controls")
        check(R.normalizeLanguage(" ENG ") == "en" && R.normalizeLanguage("pt-BR") == "pt" && R.normalizeLanguage("bul") == "bg",
              "language codes normalised")
        print("PASS: A4kRouting answers the Android lanes' status codes and bodies: full search, partial, cache, subtitle search, fetch and file (#483)")
    }
}
