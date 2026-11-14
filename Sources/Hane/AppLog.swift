import os

/// アプリ自身の記録の出し口。`hanectl app-logs` が、この subsystem で絞って読む。
///
/// `NSLog` の文面は統一ログに `<private>` と残って読めず、WebKit などシステムの枠組みの記録にも埋もれるため、
/// subsystem を付けた `Logger` で出す。文面に埋める値は、読めるよう `privacy: .public` を付ける。
enum AppLog {
    static let subsystem = "local.personal.hane"
    static let logger = Logger(subsystem: subsystem, category: "app")
}
