import Foundation
import WebKit

/// タブ1枚ぶんの記録。ページの `console` 出力、捕まえられなかった例外、読み込み失敗を溜める。
///
/// 古いものから捨てるので、長く開いたタブでもメモリは増え続けない。
/// タブが眠ってページを手放しても、記録はタブに残る。
@MainActor
final class PageLog {
    struct Entry {
        let date: Date
        let level: String
        let message: String
    }

    static let handlerName = "haneLog"
    static let capacity = 200
    private static let maxMessageLength = 2000

    private(set) var entries: [Entry] = []

    func append(level: String, message: String) {
        if entries.count >= Self.capacity {
            entries.removeFirst(entries.count - Self.capacity + 1)
        }
        entries.append(Entry(date: Date(), level: level, message: String(message.prefix(Self.maxMessageLength))))
    }

    func clear() {
        entries.removeAll()
    }

    // MARK: ページからの知らせ

    /// ページの設定の受け口に一度だけ付ける。知らせはどの Web ビューから来たかで、そのタブの記録へ振り分ける。
    /// 受け口は全ページで一つなので、ページごとに受け手を作らずに済む。
    static func attach(to controller: WKUserContentController) {
        controller.addUserScript(userScript)
        controller.add(router, name: handlerName)
    }

    /// その Web ビューからの知らせを、この記録へ流す。どちらかが消えれば対応も消える。
    static func route(from webView: WKWebView, to log: PageLog) {
        router.logs.setObject(log, forKey: webView)
    }

    private static let router = Router()

    private final class Router: NSObject, WKScriptMessageHandler {
        let logs = NSMapTable<WKWebView, PageLog>.weakToWeakObjects()

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            // 小窓など、どのタブにも結びつかない Web ビューからの知らせは捨てる。
            guard let webView = message.webView,
                  let log = logs.object(forKey: webView),
                  let body = message.body as? [String: Any],
                  let level = body["level"] as? String,
                  let text = body["message"] as? String
            else { return }
            log.append(level: level, message: text)
        }
    }

    /// `console` の各メソッドと未処理の例外を横取りして、アプリへ知らせるスクリプト。
    static let userScript = WKUserScript(
        source: """
        (() => {
          const format = value => {
            if (typeof value === 'string') return value;
            // WebKitの stack にはメッセージが含まれないので、両方をつなぐ。
            if (value instanceof Error) return String(value) + (value.stack ? ' @ ' + value.stack.split('\\n')[0] : '');
            try { return JSON.stringify(value); } catch { return String(value); }
          };
          const post = (level, values) => {
            try {
              window.webkit.messageHandlers.\(handlerName).postMessage({
                level, message: values.map(format).join(' ').slice(0, \(maxMessageLength))
              });
            } catch {}
          };
          for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
            const original = console[level];
            console[level] = function (...values) {
              post(level, values);
              return original.apply(this, values);
            };
          }
          addEventListener('error', event => {
            const where = event.filename ? ' (' + event.filename + ':' + event.lineno + ')' : '';
            post('exception', [(event.message || 'error') + where]);
          });
          addEventListener('unhandledrejection', event => {
            post('exception', ['Unhandled rejection: ' + format(event.reason)]);
          });
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )
}
