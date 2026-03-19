import Foundation

struct Defaults {
    private static var defaults: UserDefaults {
        UserDefaults.standard
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

    static var mosaicBlockSize: Double {
        get {
            let val = defaults.double(forKey: "mosaicBlockSize")
            return val > 0 ? val : 12.0
        }
        set {
            defaults.set(newValue, forKey: "mosaicBlockSize")
        }
    }
}
