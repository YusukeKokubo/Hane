import AppKit

/// `key`（窓まわりへ）と `page-key`（ページへ）で書くキーの名前を、仮想キーコードと文字に引き直す。
enum KeySpec {
    /// `key` のキー。小文字にしてから読む。
    static func windowKey(from spec: String) throws -> (flags: NSEvent.ModifierFlags, code: UInt16, characters: String) {
        var parts = spec.lowercased().split(separator: "+").map(String.init)
        guard let name = parts.popLast() else { throw ControlError("キーがない。") }
        let flags = try modifiers(from: parts)
        guard let (keyCode, characters) = keys[name] else {
            let named = keys.keys.filter { letterKeys[$0] == nil }.sorted()
            throw ControlError("知らないキー: \(name)（a〜z, \(named.joined(separator: ", "))）")
        }
        return (flags, keyCode, characters)
    }

    /// `page-key` のキー。`key` と同じ書き方に、大文字（Shift つきの英字）を加える。
    static func pageKey(from spec: String) throws -> (code: UInt16, characters: String, ignoringModifiers: String, modifiers: NSEvent.ModifierFlags) {
        var parts = spec.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard var name = parts.popLast(), !name.isEmpty else { throw ControlError("キーがない: \(spec)") }
        var modifiers = try Self.modifiers(from: parts.map { $0.lowercased() })
        if name.count == 1, let letter = name.first, letter.isUppercase, letter.isASCII {
            modifiers.insert(.shift)
            name = name.lowercased()
        }
        name = name.lowercased()
        guard let (code, base) = keys[name] else {
            let named = keys.keys.filter { letterKeys[$0] == nil }.sorted()
            throw ControlError("知らないキー: \(name)（a〜z、A〜Z, \(named.joined(separator: ", "))）")
        }
        let characters = modifiers.contains(.shift) && letterKeys[name] != nil ? base.uppercased() : base
        return (code, characters, base, modifiers)
    }

    static func modifiers(from names: [String]) throws -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for name in names {
            switch name {
            case "cmd": flags.insert(.command)
            case "ctrl": flags.insert(.control)
            case "opt", "alt": flags.insert(.option)
            case "shift": flags.insert(.shift)
            default: throw ControlError("知らない修飾キー: \(name)（cmd, ctrl, opt, shift）")
            }
        }
        return flags
    }

    /// 送れるキー。値は仮想キーコードと、そのキーが打ち出す文字。
    private static let keys: [String: (UInt16, String)] = [
        "1": (18, "1"), "2": (19, "2"), "3": (20, "3"), "4": (21, "4"), "5": (23, "5"),
        "6": (22, "6"), "7": (26, "7"), "8": (28, "8"), "9": (25, "9"),
        "up": (126, String(UnicodeScalar(NSUpArrowFunctionKey)!)),
        "down": (125, String(UnicodeScalar(NSDownArrowFunctionKey)!)),
        "left": (123, String(UnicodeScalar(NSLeftArrowFunctionKey)!)),
        "right": (124, String(UnicodeScalar(NSRightArrowFunctionKey)!)),
        "return": (36, "\r"),
        "escape": (53, "\u{1b}"),
        "delete": (51, "\u{7f}"),
        "tab": (48, "\t"),
        "space": (49, " "),
        ",": (43, ","),
    ].merging(letterKeys) { $1 }

    /// 英字キー。仮想キーコードは並びが文字の順ではない（US 配列の位置で決まっている）。
    private static let letterKeys: [String: (UInt16, String)] = {
        let codes: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38,
            "k": 40, "n": 45, "m": 46,
        ]
        return Dictionary(uniqueKeysWithValues: codes.map { (String($0.key), ($0.value, String($0.key))) })
    }()
}
