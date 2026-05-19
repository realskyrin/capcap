import AppKit

/// Stable identifier for every button that can appear in the editor's
/// toolbars. Raw values are persisted in `UserDefaults`, so existing cases
/// must never be renamed — only added or deprecated.
enum ToolbarItemID: String, Codable, CaseIterable {
    // Annotation tools (toggle an `EditTool`)
    case rectangle
    case ellipse
    case arrow
    case pen
    case marker
    case mosaic
    case numbered
    case text
    // Stateful actions
    case colorPicker
    case undo
    case redo
    case moveSelection
    case scrollCapture
    case beautify
    case ocr
    // Output actions
    case save
    case upload
    case pin
    case close
    case confirm
}

extension ToolbarItemID {
    /// How the button behaves — drives which `on*` callback it fires and
    /// whether it carries a persistent selected/active state.
    enum Kind {
        /// Annotation tool — selecting it toggles an `EditTool`.
        case toggleTool
        /// Has an on/off state but is not an `EditTool` (scroll capture, beautify).
        case toggleAction
        /// Fires once on click, no persistent state.
        case momentary
        /// Press-and-drag handle (move selection) — not a tappable button.
        case dragHandle
    }

    var kind: Kind {
        switch self {
        case .rectangle, .ellipse, .arrow, .pen, .marker, .mosaic, .numbered, .text:
            return .toggleTool
        case .scrollCapture, .beautify:
            return .toggleAction
        case .moveSelection:
            return .dragHandle
        case .colorPicker, .undo, .redo, .ocr, .save, .upload, .pin, .close, .confirm:
            return .momentary
        }
    }

    /// The annotation tool a `toggleTool` item maps to; `nil` for all others.
    var editTool: EditTool? {
        switch self {
        case .rectangle: return .rectangle
        case .ellipse:   return .ellipse
        case .arrow:     return .arrow
        case .pen:       return .pen
        case .marker:    return .marker
        case .mosaic:    return .mosaic
        case .numbered:  return .numbered
        case .text:      return .text
        default:         return nil
        }
    }

    var symbolName: String {
        switch self {
        case .rectangle:     return "rectangle"
        case .ellipse:       return "circle"
        case .arrow:         return "arrow.up.right"
        case .pen:           return "pencil.tip"
        case .marker:        return "highlighter"
        case .mosaic:        return "square.grid.3x3"
        case .numbered:      return "1.circle"
        case .text:          return "textformat"
        case .colorPicker:   return "eyedropper"
        case .undo:          return "arrow.uturn.backward"
        case .redo:          return "arrow.uturn.forward"
        case .moveSelection: return "arrow.up.and.down.and.arrow.left.and.right"
        case .scrollCapture: return "arrow.up.and.down.text.horizontal"
        case .beautify:      return "sparkles"
        case .ocr:           return "text.viewfinder"
        case .save:          return "square.and.arrow.down"
        case .upload:        return "icloud.and.arrow.up"
        case .pin:           return "pin"
        case .close:         return "xmark"
        case .confirm:       return "checkmark"
        }
    }

    /// Localized hover-tooltip text.
    var tooltip: String {
        switch self {
        case .rectangle:     return L10n.tipRectangle
        case .ellipse:       return L10n.tipEllipse
        case .arrow:         return L10n.tipArrow
        case .pen:           return L10n.tipPen
        case .marker:        return L10n.tipMarker
        case .mosaic:        return L10n.tipMosaic
        case .numbered:      return L10n.tipNumbered
        case .text:          return L10n.tipText
        case .colorPicker:   return L10n.tipColorPicker
        case .undo:          return L10n.tipUndo
        case .redo:          return L10n.tipRedo
        case .moveSelection: return L10n.tipMoveSelection
        case .scrollCapture: return L10n.tipScrollCapture
        case .beautify:      return L10n.tipBeautify
        case .ocr:           return L10n.tipOCR
        case .save:          return L10n.tipSave
        case .upload:        return L10n.tipUpload
        case .pin:           return L10n.tipPin
        case .close:         return L10n.tipCancel
        case .confirm:       return L10n.tipConfirm
        }
    }

    /// Icon tint in the resting state.
    var normalColor: NSColor {
        switch self {
        case .close:   return toolbarDangerRed
        case .confirm: return accentGreen
        default:       return .white
        }
    }

    /// Icon tint while selected/active. For `momentary` items this equals
    /// `normalColor` — they never enter a selected state.
    var selectedColor: NSColor {
        switch kind {
        case .toggleTool, .toggleAction:
            return accentGreen
        case .momentary, .dragHandle:
            return normalColor
        }
    }
}

/// Red used for the cancel button's icon. Mirrors the literal previously
/// inlined in `ToolbarView.setupButtons()`.
let toolbarDangerRed = NSColor(red: 1.0, green: 0.35, blue: 0.35, alpha: 1.0)

/// User-customizable assignment of every toolbar item to the primary
/// (horizontal) toolbar, the side (vertical) toolbar, or hidden.
struct ToolbarLayout: Equatable {
    var primary: [ToolbarItemID]
    var side: [ToolbarItemID]
    var hidden: [ToolbarItemID]

    /// Canonical left-to-right order. Used for the default layout and to
    /// place any newly-introduced tool that an older persisted layout never
    /// recorded.
    static let canonicalOrder: [ToolbarItemID] = [
        .rectangle, .ellipse, .arrow, .pen, .marker, .mosaic, .numbered, .text,
        .colorPicker, .undo, .redo, .moveSelection, .scrollCapture, .beautify, .ocr,
        .save, .upload, .pin, .close, .confirm,
    ]

    /// Default layout: annotation tools + edit actions on the primary
    /// (horizontal) toolbar; capture/output actions on the side (vertical)
    /// toolbar.
    static var `default`: ToolbarLayout {
        ToolbarLayout(
            primary: [
                .rectangle, .ellipse, .arrow, .pen, .marker, .mosaic, .numbered, .text,
                .colorPicker, .beautify, .ocr, .undo, .redo, .moveSelection,
            ],
            side: [.scrollCapture, .upload, .save, .pin, .close, .confirm],
            hidden: []
        )
    }

    /// Drops duplicate / unknown ids and appends any tool missing from all
    /// three buckets to `primary`, so the result always covers every
    /// `ToolbarItemID` exactly once regardless of app-version drift.
    func normalized() -> ToolbarLayout {
        var seen = Set<ToolbarItemID>()
        func dedup(_ ids: [ToolbarItemID]) -> [ToolbarItemID] {
            ids.filter { seen.insert($0).inserted }
        }
        var p = dedup(primary)
        let s = dedup(side)
        let h = dedup(hidden)
        let missing = Self.canonicalOrder.filter { !seen.contains($0) }
        p.append(contentsOf: missing)
        return ToolbarLayout(primary: p, side: s, hidden: h)
    }
}

extension ToolbarLayout {
    /// Builds a layout from a persisted `[bucket: [rawValue]]` dictionary,
    /// silently skipping any raw value no longer backed by a `ToolbarItemID`.
    init(dictionary: [String: [String]]) {
        func parse(_ key: String) -> [ToolbarItemID] {
            (dictionary[key] ?? []).compactMap(ToolbarItemID.init(rawValue:))
        }
        self.init(
            primary: parse("primary"),
            side: parse("side"),
            hidden: parse("hidden")
        )
    }

    /// Plain `[String: [String]]` form suitable for `UserDefaults`.
    var dictionary: [String: [String]] {
        [
            "primary": primary.map(\.rawValue),
            "side": side.map(\.rawValue),
            "hidden": hidden.map(\.rawValue),
        ]
    }
}

extension Defaults {
    /// Persisted editor toolbar layout. Always returned normalized, so
    /// callers can rely on every tool being present exactly once.
    static var toolbarLayout: ToolbarLayout {
        get {
            guard let dict = UserDefaults.standard
                .dictionary(forKey: "editor.toolbarLayout") as? [String: [String]]
            else {
                return .default
            }
            return ToolbarLayout(dictionary: dict).normalized()
        }
        set {
            UserDefaults.standard.set(
                newValue.normalized().dictionary,
                forKey: "editor.toolbarLayout"
            )
        }
    }
}
