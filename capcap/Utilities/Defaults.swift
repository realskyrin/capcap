import Foundation

enum CaptureMode: Int {
    case direct = 0
    case edit = 1
}

struct Defaults {
    private static let suiteName = "com.capcap.app"

    private static var defaults: UserDefaults {
        UserDefaults.standard
    }

    static var captureMode: CaptureMode {
        get {
            CaptureMode(rawValue: defaults.integer(forKey: "captureMode")) ?? .direct
        }
        set {
            defaults.set(newValue.rawValue, forKey: "captureMode")
        }
    }

    static var doubleTapInterval: TimeInterval {
        get {
            let val = defaults.double(forKey: "doubleTapInterval")
            return val > 0 ? val : 0.3
        }
        set {
            defaults.set(newValue, forKey: "doubleTapInterval")
        }
    }

    static var penColor: Int {
        get {
            let val = defaults.integer(forKey: "penColor")
            return val == 0 ? 0xFF0000 : val
        }
        set {
            defaults.set(newValue, forKey: "penColor")
        }
    }

    static var penWidth: Double {
        get {
            let val = defaults.double(forKey: "penWidth")
            return val > 0 ? val : 3.0
        }
        set {
            defaults.set(newValue, forKey: "penWidth")
        }
    }
}
