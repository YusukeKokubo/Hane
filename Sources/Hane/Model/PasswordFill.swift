import Foundation
import Observation
import WebKit

/// 1Password のログインを、選んでいるページの入力欄に入れる（⌘\）。
///
/// 1Password の CLI（`op`）を、押したときだけ起こして尋ねる。拡張を載せる道は、拡張の裏の処理がずっと居座るうえ、
/// 拡張と本体アプリのやりとりを真似できないのでやめた。解錠は本体アプリとの連携（Touch ID）に任せる。
///
/// 入れるのは押したときだけで、ページを開いたときに勝手には入れない。見えない入力欄に抜き取られないようにするため。
/// 候補もページのホストに合うログインだけにする。窓（`TabStore`）ごとに一つ持つ。
@MainActor
@Observable
final class PasswordFill {
    enum State: Equatable {
        case idle
        /// 1Password に尋ねているか、入れている最中。解錠を待っていると数秒かかる。
        case working
        /// 合うログインがいくつもあり、選んでもらう。
        case choosing([LoginItem])
        case failed(String)
    }

    private(set) var state = State.idle

    @ObservationIgnored private let source: any LoginSource
    /// 選んでもらっているあいだの入れる先。選ぶまでにページが別のアドレスへ移っていたら入れない。
    @ObservationIgnored private var target: (page: Page, url: URL)?

    init(source: any LoginSource = OnePasswordCLI()) {
        self.source = source
    }

    func start(on tab: Tab?) {
        guard state != .working else { return }
        target = nil
        guard let page = tab?.page, let url = page.url, let host = url.host(), !host.isEmpty else {
            state = .failed("このページにはログインを入れられません。")
            return
        }
        state = .working
        Task {
            do {
                let items = LoginItem.candidates(try await source.logins(), for: host)
                guard page.url == url else {
                    state = .idle
                    return
                }
                switch items.count {
                case 0: state = .failed("\(host) のログインは 1Password に見つかりません。")
                case 1: await fill(items[0], into: page, at: url)
                default:
                    target = (page, url)
                    state = .choosing(items)
                }
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func choose(_ item: LoginItem) {
        guard case .choosing = state, let target else { return }
        self.target = nil
        state = .working
        Task { await fill(item, into: target.page, at: target.url) }
    }

    func dismiss() {
        guard state != .working else { return }
        target = nil
        state = .idle
    }

    private func fill(_ item: LoginItem, into page: Page, at url: URL) async {
        do {
            let credentials = try await source.credentials(for: item)
            guard page.url == url else {
                state = .idle
                return
            }
            let filled = try await Self.fill(credentials, into: page, at: url)
            state = filled.isEmpty ? .failed("このページにログインの入力欄が見つかりません。") : .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: ページの中

    /// ページのスクリプトから触られない実行環境。入れた値そのものはページから読めるが、入れる手順を横取りさせない。
    static let world = WKContentWorld.world(name: "password-fill")

    /// 入力欄を探して入れ、入れた欄の種類（`username`、`password`、`code`）を返す。トップのページだけを見る。
    /// 待っているあいだに別のアドレスへ移っていたら何も入れない。
    static func fill(_ credentials: Credentials, into page: Page, at url: URL) async throws -> [String] {
        let host = (url.host() ?? "") + (url.port.map { ":\($0)" } ?? "")
        let result = try await page.callJavaScript(script, arguments: [
            "host": host,
            "username": credentials.username,
            "passwordValue": credentials.password,
            "oneTimeCode": credentials.oneTimeCode ?? "",
        ], contentWorld: world)
        return result as? [String] ?? []
    }

    /// 入れる欄の選び方:
    /// - パスワード欄は、フォーカスのあるものか、見えている最初のもの。
    /// - ユーザー名は、フォーカスのある文字の欄（パスワード欄と同じフォームのとき）か、パスワード欄の手前にある最後の文字の欄。
    ///   パスワード欄がない（ユーザー名だけ先に聞く）ページでは、名前やメールの欄らしいもの。
    /// - パスワード欄がなく、ワンタイムコードの欄があれば、コードだけ入れる。
    /// 値は自分の実行環境から入れるので、React などがページの側で値の書き込みを見張っていても素通りし、
    /// 続けて出す `input` で変化に気づいてもらえる。
    private static let script = """
        if (location.host !== host) return [];
        const shown = el => !el.disabled && !el.readOnly && el.getClientRects().length > 0
            && getComputedStyle(el).visibility !== "hidden";
        const inputs = Array.from(document.querySelectorAll("input")).filter(shown);
        const hint = el => [el.name, el.id, el.autocomplete, el.placeholder, el.getAttribute("aria-label")]
            .join(" ").toLowerCase();
        const isCode = el => el.autocomplete === "one-time-code"
            || (["text", "tel", "number"].includes(el.type)
                && /otp|totp|2fa|mfa|one.?time|verification|auth.?code|security.?code/.test(hint(el)));
        const isName = el => ["text", "email", "tel"].includes(el.type) && !isCode(el);
        const active = inputs.includes(document.activeElement) ? document.activeElement : null;

        const password = active?.type === "password" ? active : inputs.find(el => el.type === "password");
        let name = null;
        let code = null;
        if (password) {
            if (active && isName(active) && active.form === password.form) {
                name = active;
            } else {
                const scope = password.form ? inputs.filter(el => el.form === password.form) : inputs;
                name = scope.filter(el => isName(el)
                    && (el.compareDocumentPosition(password) & Node.DOCUMENT_POSITION_FOLLOWING)).at(-1) ?? null;
            }
        } else {
            code = active && isCode(active) ? active : inputs.find(isCode) ?? null;
            if (!code || !oneTimeCode) {
                code = null;
                name = active && isName(active) ? active
                    : inputs.find(el => isName(el) && (el.type === "email" || /user|login|mail|account/.test(hint(el)))) ?? null;
            }
        }

        const put = (el, value) => {
            el.focus();
            el.value = value;
            el.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertReplacementText", data: value }));
            el.dispatchEvent(new Event("change", { bubbles: true }));
        };
        const filled = [];
        if (name && username) { put(name, username); filled.push("username"); }
        if (password && passwordValue) { put(password, passwordValue); filled.push("password"); }
        if (code) { put(code, oneTimeCode); filled.push("code"); }
        return filled;
        """
}
