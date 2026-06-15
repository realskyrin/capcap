import AppKit

/// Stable identifier for every button that can appear in the editor's
/// toolbars. Raw values are persisted in `UserDefaults`, so existing cases
/// must never be renamed — only added or deprecated.
enum ToolbarItemID: String, Codable, CaseIterable {
    // Annotation tools (toggle an `EditTool`)
    case rectangle
    case ellipse
    case arrow
    case line
    case pen
    case marker
    case mosaic
    case eraser
    case magnifier
    case numbered
    case text
    case emoji
    case insertImage
    // Stateful actions
    case colorPicker
    case undo
    case redo
    case moveSelection
    case scrollCapture
    case beautify
    case ocr
    case screenshotTranslate
    // Output actions
    case save
    case upload
    case pin
    case record
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
        case .rectangle, .ellipse, .arrow, .line, .pen, .marker, .mosaic, .eraser, .magnifier, .numbered, .text, .emoji:
            return .toggleTool
        case .scrollCapture, .beautify:
            return .toggleAction
        case .moveSelection:
            return .dragHandle
        case .insertImage, .colorPicker, .undo, .redo, .ocr, .screenshotTranslate, .save, .upload, .pin, .record, .close, .confirm:
            return .momentary
        }
    }

    /// The annotation tool a `toggleTool` item maps to; `nil` for all others.
    var editTool: EditTool? {
        switch self {
        case .rectangle: return .rectangle
        case .ellipse:   return .ellipse
        case .arrow:     return .arrow
        case .line:      return .line
        case .pen:       return .pen
        case .marker:    return .marker
        case .mosaic:    return .mosaic
        case .eraser:    return .eraser
        case .magnifier: return .magnifier
        case .numbered:  return .numbered
        case .text:      return .text
        case .emoji:     return .emoji
        default:         return nil
        }
    }

    var symbolName: String {
        switch self {
        case .rectangle:     return "rectangle"
        case .ellipse:       return "circle"
        case .arrow:         return "arrow.up.right"
        case .line:          return "line.diagonal"
        case .pen:           return "pencil.tip"
        case .marker:        return "highlighter"
        case .mosaic:        return "square.grid.3x3"
        case .eraser:        return "eraser"
        case .magnifier:     return "plus.magnifyingglass"
        case .numbered:      return "1.circle"
        case .text:          return "textformat"
        case .emoji:         return "face.smiling"
        case .insertImage:   return "photo"
        case .colorPicker:   return "eyedropper"
        case .undo:          return "arrow.uturn.backward"
        case .redo:          return "arrow.uturn.forward"
        case .moveSelection: return "arrow.up.and.down.and.arrow.left.and.right"
        case .scrollCapture: return "arrow.up.and.down.text.horizontal"
        case .beautify:      return "sparkles"
        case .ocr:           return "text.viewfinder"
        case .screenshotTranslate: return "character.bubble"
        case .save:          return "square.and.arrow.down"
        case .upload:        return "icloud.and.arrow.up"
        case .pin:           return "pin"
        case .record:        return "record.circle"
        case .close:         return "xmark"
        case .confirm:       return "checkmark"
        }
    }

    /// Localized hover-tooltip text.
    var tooltip: String {
        let title: String
        switch self {
        case .rectangle:     title = L10n.tipRectangle
        case .ellipse:       title = L10n.tipEllipse
        case .arrow:         title = L10n.tipArrow
        case .line:          title = L10n.tipLine
        case .pen:           title = L10n.tipPen
        case .marker:        title = L10n.tipMarker
        case .mosaic:        title = L10n.tipMosaic
        case .eraser:        title = L10n.tipEraser
        case .magnifier:     title = L10n.tipMagnifier
        case .numbered:      title = L10n.tipNumbered
        case .text:          title = L10n.tipText
        case .emoji:         title = L10n.tipEmoji
        case .insertImage:   title = L10n.tipInsertImage
        case .colorPicker:   title = L10n.tipColorPicker
        case .undo:          title = L10n.tipUndo
        case .redo:          title = L10n.tipRedo
        case .moveSelection: title = L10n.tipMoveSelection
        case .scrollCapture: title = L10n.tipScrollCapture
        case .beautify:      title = L10n.tipBeautify
        case .ocr:           title = L10n.tipOCR
        case .screenshotTranslate: title = L10n.tipScreenshotTranslate
        case .save:          title = L10n.tipSave
        case .upload:        title = L10n.tipUpload
        case .pin:           title = L10n.tipPin
        case .record:        title = L10n.tipRecord
        case .close:         title = L10n.tipCancel
        case .confirm:       title = L10n.tipConfirm
        }
        guard let shortcut = editorShortcutDisplay else { return title }
        return "\(title) (\(shortcut))"
    }

    var editorShortcutDisplay: String? {
        switch self {
        case .rectangle: return "R"
        case .ellipse:   return "O"
        case .line:      return "L"
        case .arrow:     return "A"
        case .pin:       return "P"
        case .pen:       return "D"
        case .marker:    return "H"
        case .mosaic:    return "M"
        case .eraser:    return "E"
        case .text:      return "T"
        case .numbered:  return "N"
        case .save:      return HotkeyManager.currentFileSaveDisplayString()
        case .confirm:   return HotkeyManager.currentClipboardDisplayString() ?? L10n.clipboardShortcutDefaultDisplay
        case .undo:      return "⌘+Z"
        case .redo:      return "Z"
        case .close:     return "X"
        default:         return nil
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
        .rectangle, .ellipse, .line, .arrow, .pen, .marker, .mosaic, .eraser, .numbered, .text, .emoji, .insertImage,
        .colorPicker, .magnifier, .undo, .redo, .moveSelection, .scrollCapture, .beautify, .ocr,
        .screenshotTranslate,
        .save, .upload, .pin, .record, .close, .confirm,
    ]

    /// Default layout: annotation tools + edit actions on the primary
    /// (horizontal) toolbar; capture/output actions on the side (vertical)
    /// toolbar.
    static var `default`: ToolbarLayout {
        ToolbarLayout(
            primary: [
                .rectangle, .ellipse, .line, .arrow, .pen, .marker, .mosaic, .eraser, .numbered, .text, .emoji, .insertImage,
                .colorPicker, .magnifier, .beautify, .ocr, .screenshotTranslate, .undo, .redo, .moveSelection,
            ],
            side: [.scrollCapture, .upload, .save, .pin, .record, .close, .confirm],
            hidden: []
        )
    }

    /// Drops duplicate / unknown ids and slots any tool missing from all
    /// three buckets next to its canonical neighbour, so the result always
    /// covers every `ToolbarItemID` exactly once regardless of app-version
    /// drift. A newly-introduced tool lands beside its siblings (e.g. `line`
    /// after `ellipse`) instead of being dumped at the end of the bar.
    func normalized() -> ToolbarLayout {
        var seen = Set<ToolbarItemID>()
        func dedup(_ ids: [ToolbarItemID]) -> [ToolbarItemID] {
            ids.filter { seen.insert($0).inserted }
        }
        var p = dedup(primary)
        var s = dedup(side)
        var h = dedup(hidden)

        let missing = Self.canonicalOrder.filter { !seen.contains($0) }
        for item in missing {
            guard let canonicalIdx = Self.canonicalOrder.firstIndex(of: item) else { continue }
            // Walk back through the canonical order to the nearest sibling
            // that's already placed, then drop the new tool right after it
            // in whichever bucket that sibling lives in.
            var placed = false
            for prevIdx in stride(from: canonicalIdx - 1, through: 0, by: -1) {
                let prev = Self.canonicalOrder[prevIdx]
                if let i = p.firstIndex(of: prev) { p.insert(item, at: i + 1); placed = true; break }
                if let i = s.firstIndex(of: prev) { s.insert(item, at: i + 1); placed = true; break }
                if let i = h.firstIndex(of: prev) { h.insert(item, at: i + 1); placed = true; break }
            }
            if !placed { p.insert(item, at: 0) }
            seen.insert(item)
        }
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
