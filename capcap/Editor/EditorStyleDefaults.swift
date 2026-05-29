import AppKit

enum EditorStyleDefaults {
    static let paletteColors: [NSColor] = [
        NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0),     // Red
        NSColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0),      // Blue
        NSColor(red: 0.0, green: 0.83, blue: 0.42, alpha: 1.0),     // Green
        NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0),       // Yellow
        NSColor(red: 0.843, green: 0.467, blue: 0.341, alpha: 1.0), // #D77757
        .white,
        NSColor(white: 0.5, alpha: 1.0),                           // Gray
        .black,
    ]

    static var primaryColor: NSColor { paletteColors[0] }
    static var markerColor: NSColor { paletteColors[3] }

    static let standardLineSizes: [CGFloat] = [2, 4, 6]
    static let markerLineSizes: [CGFloat] = [3, 5, 8]

    static let standardLineWidth: CGFloat = 4
    static let markerLineWidth: CGFloat = 5
}
