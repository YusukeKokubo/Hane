import AppKit
import WebKit

/// ページが利用者に尋ねるもの（`alert`、`confirm`、`prompt`、ファイルの選択）を、ページの窓のシートで出す。
///
/// シートは窓の中だけを止めるので、メインスレッドは止まらず、hanectl も答えられる（`ui-snapshot` で中身が出る）。
/// ページが窓に載っていない（裏のタブ、テスト）ときは、取り消したのと同じに答える。WebKit が案内役なしで振る舞うのと同じ。
@MainActor
enum PageDialogs {
    static func alert(_ message: String, from frame: WKFrameInfo, in webView: WKWebView) async {
        guard let window = webView.window else { return }
        let alert = makeAlert(message, from: frame)
        alert.addButton(withTitle: "OK")
        _ = await alert.beginSheetModal(for: window)
    }

    static func confirm(_ message: String, from frame: WKFrameInfo, in webView: WKWebView) async -> Bool {
        guard let window = webView.window else { return false }
        let alert = makeAlert(message, from: frame)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "キャンセル")
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    static func prompt(_ message: String, defaultText: String?, from frame: WKFrameInfo, in webView: WKWebView) async -> String? {
        guard let window = webView.window else { return nil }
        let alert = makeAlert(message, from: frame)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "キャンセル")
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    static func chooseFiles(_ parameters: WKOpenPanelParameters, in webView: WKWebView) async -> [URL]? {
        guard let window = webView.window else { return nil }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
    }

    /// どのサイトが尋ねているかを題に出す。ページになりすました文言で、ほかのサイトやアプリを装わせないため。
    private static func makeAlert(_ message: String, from frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        let origin = frame.securityOrigin
        let site = origin.host.isEmpty ? origin.protocol : origin.host
        alert.messageText = "\(site) からのメッセージ"
        alert.informativeText = message
        return alert
    }
}
