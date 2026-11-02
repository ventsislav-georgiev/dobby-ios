import Foundation

// #475 (E10): the pause info cards' pure half, PauseInfoModel.swift.
@main
enum PauseInfoModelCheck {
    static func check(_ condition: Bool, _ what: String) {
        guard condition else {
            FileHandle.standardError.write(Data("FAIL: \(what)\n".utf8))
            exit(1)
        }
    }

    static func main() {
        let cdn = "https://image.example.org/t/p/w780/still.jpg"
        let proxied = "dobby-api://proxy?target=image&url=" + cdn.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!

        // Image: the proxy unwraps to the CDN URL; thumb wins over poster; a bad thumb falls through.
        check(PauseInfoModel.imageURL(proxied)?.absoluteString == cdn, "dobby-api proxy URL unwraps to the CDN URL")
        check(PauseInfoModel.imageURL(cdn)?.absoluteString == cdn, "a plain https URL passes through")
        check(PauseInfoModel.imageURL("dobby-api://proxy?target=imdb-graphql&q=x") == nil, "a non-image proxy target is not an image")
        check(PauseInfoModel.imageURL("/api/poster.jpg") == nil, "a relative URL is not fetchable")
        let both = PauseInfoModel(title: "T", subtitle: nil, description: nil, thumb: proxied, poster: "https://p.example.org/p.jpg")
        check(both.image?.absoluteString == cdn, "thumb wins over poster")
        let noThumb = PauseInfoModel(title: "T", subtitle: nil, description: nil, thumb: "", poster: "https://p.example.org/p.jpg")
        check(noThumb.image?.host == "p.example.org", "an empty thumb falls through to the poster")

        // Visibility: Android refreshMediaInfoPanel.
        let m = PauseInfoModel(title: "Title", subtitle: " ", description: "Plot", thumb: nil, poster: nil)
        check(m.meta == nil, "a blank meta line is absent")
        check(m.shows(paused: true, barVisible: true, layerOpen: false, smartTube: false), "paused, bar up, nothing open: shown")
        check(!m.shows(paused: false, barVisible: true, layerOpen: false, smartTube: false), "playing: hidden")
        check(!m.shows(paused: true, barVisible: false, layerOpen: false, smartTube: false), "bar hidden: hidden with it")
        check(!m.shows(paused: true, barVisible: true, layerOpen: true, smartTube: false), "a layer open: hidden")
        check(!m.shows(paused: true, barVisible: true, layerOpen: false, smartTube: true), "SmartTube lane: hidden")
        let empty = PauseInfoModel(title: "", subtitle: "S1", description: nil, thumb: cdn, poster: nil)
        check(!empty.shows(paused: true, barVisible: true, layerOpen: false, smartTube: false), "no title and no plot: hidden")
        print("PauseInfoModelCheck: all checks passed")
    }
}
