import Foundation
import RegexBuilder

/// Scrapes the few fields Stow needs from youtube.com HTML.
enum ChannelPageParser {
    /// Channel id, title, handle and avatar from a channel page (/channel/…, /@…, /c/…, /user/…).
    /// Nil when the page doesn't carry them (consent wall, layout change).
    static func parse(html: String) -> ChannelInfo? {
        let id = html.firstMatch(of: #/<meta itemprop="identifier" content="(UC[\w-]{22})"/#)?.1
            ?? html.firstMatch(of: #/"externalId":"(UC[\w-]{22})"/#)?.1
        guard let id, let title = metaContent("og:title", in: html), !title.isEmpty else { return nil }
        let handle = html.firstMatch(of: #/"vanityChannelUrl":"https?:\/\/www\.youtube\.com\/(@[^"]+)"/#)
            .flatMap { String($0.1).removingPercentEncoding }
        let avatar = metaContent("og:image", in: html).flatMap(URL.init(string:))
        return ChannelInfo(id: String(id), title: title, handle: handle, avatarURL: avatar)
    }

    /// The uploader's channel id from a watch page. The first "channelId" is in videoDetails,
    /// ahead of any recommendations.
    static func ownerChannelId(watchPage html: String) -> String? {
        html.firstMatch(of: #/"channelId":"(UC[\w-]{22})"/#).map { String($0.1) }
    }

    private static func metaContent(_ property: String, in html: String) -> String? {
        let pattern = Regex<(Substring, Substring)> {
            "<meta property=\"\(property)\" content=\""
            Capture { ZeroOrMore { CharacterClass.anyOf("\"").inverted } }
            "\""
        }
        return html.firstMatch(of: pattern).map { decodeEntities(String($0.1)) }
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacing(#/&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos);/#) { match in
            let entity = match.1
            switch entity {
            case "amp": return "&"
            case "lt": return "<"
            case "gt": return ">"
            case "quot": return "\""
            case "apos": return "'"
            default:
                let isHex = entity.hasPrefix("#x")
                let digits = entity.dropFirst(isHex ? 2 : 1)
                return UInt32(digits, radix: isHex ? 16 : 10).flatMap(Unicode.Scalar.init).map { String($0) } ?? String(match.0)
            }
        }
    }
}
