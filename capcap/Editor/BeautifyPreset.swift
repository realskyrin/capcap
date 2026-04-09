import AppKit

struct BeautifyPreset: Equatable {
    let id: String
    let displayName: String
    let startColor: NSColor
    let endColor: NSColor
    let angleDegrees: CGFloat

    static func == (lhs: BeautifyPreset, rhs: BeautifyPreset) -> Bool {
        lhs.id == rhs.id
    }

    static let defaults: [BeautifyPreset] = [
        BeautifyPreset(
            id: "peach-blue",
            displayName: L10n.beautifyPresetPeachBlue,
            startColor: NSColor(red: 0xFD/255.0, green: 0xE8/255.0, blue: 0xEF/255.0, alpha: 1),
            endColor:   NSColor(red: 0xC7/255.0, green: 0xD7/255.0, blue: 0xF2/255.0, alpha: 1),
            angleDegrees: 135
        ),
        BeautifyPreset(
            id: "mint-teal",
            displayName: L10n.beautifyPresetMintTeal,
            startColor: NSColor(red: 0xD4/255.0, green: 0xF1/255.0, blue: 0xE5/255.0, alpha: 1),
            endColor:   NSColor(red: 0xA7/255.0, green: 0xD8/255.0, blue: 0xC6/255.0, alpha: 1),
            angleDegrees: 135
        ),
        BeautifyPreset(
            id: "peach-pink",
            displayName: L10n.beautifyPresetPeachPink,
            startColor: NSColor(red: 0xFD/255.0, green: 0xE1/255.0, blue: 0xD3/255.0, alpha: 1),
            endColor:   NSColor(red: 0xF9/255.0, green: 0xA8/255.0, blue: 0xA8/255.0, alpha: 1),
            angleDegrees: 135
        ),
        BeautifyPreset(
            id: "blue-purple",
            displayName: L10n.beautifyPresetBluePurple,
            startColor: NSColor(red: 0xC9/255.0, green: 0xD6/255.0, blue: 0xFF/255.0, alpha: 1),
            endColor:   NSColor(red: 0xE2/255.0, green: 0xB0/255.0, blue: 0xFF/255.0, alpha: 1),
            angleDegrees: 135
        ),
        BeautifyPreset(
            id: "warm-orange",
            displayName: L10n.beautifyPresetWarmOrange,
            startColor: NSColor(red: 0xFE/255.0, green: 0xF3/255.0, blue: 0xC7/255.0, alpha: 1),
            endColor:   NSColor(red: 0xFB/255.0, green: 0xBF/255.0, blue: 0x85/255.0, alpha: 1),
            angleDegrees: 135
        ),
        BeautifyPreset(
            id: "teal-pink",
            displayName: L10n.beautifyPresetTealPink,
            startColor: NSColor(red: 0xA8/255.0, green: 0xED/255.0, blue: 0xEA/255.0, alpha: 1),
            endColor:   NSColor(red: 0xFE/255.0, green: 0xD6/255.0, blue: 0xE3/255.0, alpha: 1),
            angleDegrees: 135
        ),
        BeautifyPreset(
            id: "deep-purple",
            displayName: L10n.beautifyPresetDeepPurple,
            startColor: NSColor(red: 0x66/255.0, green: 0x7E/255.0, blue: 0xEA/255.0, alpha: 1),
            endColor:   NSColor(red: 0x76/255.0, green: 0x4B/255.0, blue: 0xA2/255.0, alpha: 1),
            angleDegrees: 135
        ),
        BeautifyPreset(
            id: "neutral-gray",
            displayName: L10n.beautifyPresetNeutralGray,
            startColor: NSColor(red: 0xE9/255.0, green: 0xEC/255.0, blue: 0xEF/255.0, alpha: 1),
            endColor:   NSColor(red: 0xCE/255.0, green: 0xD4/255.0, blue: 0xDA/255.0, alpha: 1),
            angleDegrees: 135
        ),
    ]

    static func preset(forID id: String?) -> BeautifyPreset? {
        guard let id else { return nil }
        return defaults.first(where: { $0.id == id })
    }

    static var defaultPreset: BeautifyPreset {
        preset(forID: Defaults.lastBeautifyPresetID) ?? defaults[0]
    }
}
