import Foundation

/// DiceBear 10.x 公共实例当前提供的全部官方风格。
public enum DiceBearStyle: String, CaseIterable, Codable, Sendable {
    case adventurer
    case adventurerNeutral = "adventurer-neutral"
    case avataaars
    case avataaarsNeutral = "avataaars-neutral"
    case bigEars = "big-ears"
    case bigEarsNeutral = "big-ears-neutral"
    case bigSmile = "big-smile"
    case bottts
    case botttsNeutral = "bottts-neutral"
    case croodles
    case croodlesNeutral = "croodles-neutral"
    case disco
    case dylan
    case funEmoji = "fun-emoji"
    case glass
    case glyphs
    case icons
    case identicon
    case initialFace = "initial-face"
    case initials
    case lorelei
    case loreleiNeutral = "lorelei-neutral"
    case micah
    case miniavs
    case notionists
    case notionistsNeutral = "notionists-neutral"
    case openPeeps = "open-peeps"
    case personas
    case pixelArt = "pixel-art"
    case pixelArtNeutral = "pixel-art-neutral"
    case rings
    case shapeGrid = "shape-grid"
    case shapes
    case stripes
    case thumbs
    case toonHead = "toon-head"
    case triangles

    /// Mirage 生产环境只允许这五种人物头像风格参与稳定随机选择。
    public static let mirageCatalog: [DiceBearStyle] = [
        .notionistsNeutral,
        .lorelei,
        .croodles,
        .adventurer,
        .micah,
    ]

    /// 风格名称只用于展示；远程请求始终使用稳定的 rawValue。
    public var displayName: String {
        rawValue
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + String($0.dropFirst()) }
            .joined(separator: " ")
    }

    /// 每个风格使用各自真实的艺术作品许可证，不能把 DiceBear 代码的 MIT 许可证混作内容许可证。
    public var license: LicenseInfo {
        switch self {
        case .adventurer, .adventurerNeutral, .bigEars, .bigEarsNeutral, .bigSmile,
             .croodles, .croodlesNeutral, .dylan, .funEmoji, .glyphs, .micah,
             .miniavs, .personas, .toonHead:
            return LicenseInfo(
                identifier: "cc-by-4.0",
                displayName: "CC BY 4.0",
                url: URL(string: "https://creativecommons.org/licenses/by/4.0/")
            )
        case .avataaars, .avataaarsNeutral:
            return LicenseInfo(
                identifier: "avataaars-free-use",
                displayName: "Free for personal and commercial use",
                url: URL(string: "https://www.dicebear.com/styles/avataaars/")
            )
        case .bottts, .botttsNeutral:
            return LicenseInfo(
                identifier: "bottts-free-use",
                displayName: "Free for personal and commercial use",
                url: URL(string: "https://www.dicebear.com/styles/bottts/")
            )
        case .icons:
            return LicenseInfo(
                identifier: "mit",
                displayName: "MIT",
                url: URL(string: "https://github.com/twbs/icons/blob/main/LICENSE")
            )
        case .disco, .glass, .identicon, .initialFace, .initials, .lorelei,
             .loreleiNeutral, .notionists, .notionistsNeutral, .openPeeps,
             .pixelArt, .pixelArtNeutral, .rings, .shapeGrid, .shapes, .stripes,
             .thumbs, .triangles:
            return .cc0
        }
    }

    /// DiceBear 风格定义中声明的原作者名称。
    public var creator: String {
        switch self {
        case .adventurer, .adventurerNeutral, .lorelei, .loreleiNeutral:
            return "Lisa Wischofsky"
        case .avataaars, .avataaarsNeutral, .bottts, .botttsNeutral, .openPeeps:
            return "Pablo Stanley"
        case .bigEars, .bigEarsNeutral:
            return "The Visual Team"
        case .bigSmile:
            return "Ashley Seo"
        case .croodles, .croodlesNeutral:
            return "vijay verma"
        case .disco, .glass, .identicon, .initialFace, .initials, .pixelArt,
             .pixelArtNeutral, .rings, .shapeGrid, .shapes, .stripes, .thumbs,
             .triangles:
            return "DiceBear"
        case .dylan:
            return "Natalia Spivak"
        case .funEmoji:
            return "Davis Uche"
        case .glyphs:
            return "Matt Houser"
        case .icons:
            return "The Bootstrap Authors"
        case .micah:
            return "Micah Lanier"
        case .miniavs:
            return "Webpixels"
        case .notionists, .notionistsNeutral:
            return "Zoish"
        case .personas:
            return "Draftbit - draftbit.com"
        case .toonHead:
            return "Johan Melin"
        }
    }

    /// 作者主页随记录持久化，详情页可以直接完成许可证要求的归属展示。
    public var creatorURL: URL? {
        switch self {
        case .adventurer, .adventurerNeutral, .lorelei, .loreleiNeutral:
            return URL(string: "https://www.instagram.com/lischi_art/")
        case .avataaars, .avataaarsNeutral, .bottts, .botttsNeutral, .openPeeps:
            return URL(string: "https://twitter.com/pablostanley")
        case .bigEars, .bigEarsNeutral:
            return URL(string: "https://thevisual.team/")
        case .bigSmile:
            return URL(string: "https://www.ashleyseo.com/")
        case .croodles, .croodlesNeutral:
            return URL(string: "https://vjy.me/")
        case .disco, .glass, .identicon, .initialFace, .initials, .pixelArt,
             .pixelArtNeutral, .rings, .shapeGrid, .shapes, .stripes, .thumbs,
             .triangles:
            return URL(string: "https://www.dicebear.com")
        case .dylan:
            return URL(string: "https://nataspvk.tilda.ws/")
        case .funEmoji:
            return URL(string: "https://www.instagram.com/davedirect3/")
        case .glyphs:
            return URL(string: "https://x.com/mattkhouser")
        case .icons:
            return URL(string: "https://getbootstrap.com/")
        case .micah:
            return URL(string: "https://dribbble.com/micahlanier")
        case .miniavs:
            return URL(string: "https://webpixels.io/")
        case .notionists, .notionistsNeutral:
            return URL(string: "https://bio.link/heyzoish")
        case .personas:
            return URL(string: "https://draftbit.com/")
        case .toonHead:
            return URL(string: "https://www.johanmelin.com/")
        }
    }
}
