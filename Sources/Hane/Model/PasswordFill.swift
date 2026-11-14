import AppKit
import Foundation
import Observation
import WebKit

/// 1Password のログインを、選んでいるページの入力欄に入れる（⌘\）。どの欄に何を入れるかを教わることもできる（⌥⌘\）。
///
/// 1Password の CLI（`op`）を、押したときだけ起こして尋ねる。拡張を載せる道は、拡張の裏の処理がずっと居座るうえ、
/// 拡張と本体アプリのやりとりを真似できないのでやめた。解錠は本体アプリとの連携（Touch ID）に任せる。
///
/// 入れるのは押したときだけで、ページを開いたときに勝手には入れない。見えない入力欄に抜き取られないようにするため。
/// 候補もページのホストに合うログインだけにする。窓（`TabStore`）ごとに一つ持つ。
///
/// 入れる欄は、そのサイトで教わった場所が今のページにあればそこ、なければ欄の種類や名前から推して決める。
/// 教わった場所はアプリ全体で一つの `LoginFieldStore` に持つ。
@MainActor
@Observable
final class PasswordFill {
    enum State: Equatable {
        case idle
        /// 1Password に尋ねているか、入れている最中。解錠を待っていると数秒かかる。
        case working
        /// 合うログインがいくつもあり、選んでもらう。
        case choosing([LoginItem])
        /// 入れる場所を教わっている。値はログインの名前。
        case teaching(String)
        case failed(String)
    }

    /// 入れる場所を教わっているあいだ、選んだ欄に何を入れるかを尋ねる。
    enum FieldChoice: Equatable {
        case field(Credentials.Field)
        /// その欄には入れないことにする。
        case unassign
    }

    /// 欄を選んだときに出すメニュー。`current` は今その欄に入れることにしている項目、`point` はページの中の位置。
    /// 何も選ばずに閉じたら `nil`。テストでは差し替える。
    typealias FieldMenu = @MainActor (_ fields: [Credentials.Field], _ current: String?, _ point: CGPoint, _ page: Page) -> FieldChoice?

    private(set) var state = State.idle
    /// 教わった場所。アプリ全体で一つ。
    let places: LoginFieldStore

    @ObservationIgnored private let source: any LoginSource
    @ObservationIgnored private let menu: FieldMenu
    /// 選んでもらっているあいだの、入れる先と、入れるのか教わるのか。選ぶまでにページが移っていたら何もしない。
    @ObservationIgnored private var target: (page: Page, url: URL, teaching: Bool)?
    /// 教わっているページ。終えるときに、欄を選ばせているスクリプトを止める。
    @ObservationIgnored private var teachingPage: Page?

    init(source: any LoginSource = OnePasswordCLI(), places: LoginFieldStore = LoginFieldStore(), menu: @escaping FieldMenu = FieldMenuPresenter.show) {
        self.source = source
        self.places = places
        self.menu = menu
    }

    /// `teaching` なら、入れずに入れる場所を教わる。
    func start(on tab: Tab?, teaching: Bool = false) {
        guard state != .working else { return }
        stopTeaching()
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
                case 1: await proceed(with: items[0], on: page, at: url, teaching: teaching)
                default:
                    target = (page, url, teaching)
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
        Task { await proceed(with: item, on: target.page, at: target.url, teaching: target.teaching) }
    }

    func dismiss() {
        switch state {
        case .working, .teaching: return
        case .idle, .choosing, .failed: break
        }
        target = nil
        state = .idle
    }

    /// 教わるのを終える。教わっていなければ何もしない。
    func stopTeaching() {
        guard case .teaching = state else { return }
        state = .idle
        if let page = teachingPage {
            teachingPage = nil
            Task { _ = try? await page.callJavaScript("globalThis.haneStopPicking?.()", arguments: [:], contentWorld: Self.world) }
        }
    }

    private func proceed(with item: LoginItem, on page: Page, at url: URL, teaching: Bool) async {
        do {
            let credentials = try await source.credentials(for: item)
            guard page.url == url else {
                state = .idle
                return
            }
            if teaching {
                await teach(credentials, title: item.title, on: page, at: url)
                return
            }
            let site = HiddenElementStore.site(for: url)
            let filled = try await Self.fill(credentials, into: page, at: url, places: site.map(places.places(on:)) ?? [])
            if !filled.isEmpty {
                state = .idle
            } else if credentials.password.isEmpty {
                // 選んだログインが思っていたものと違うことがある（ホストが合う別のログインが一件だけあった、など）。
                state = .failed(Self.noPassword(item.title))
            } else {
                state = .failed("このページにログインの入力欄が見つかりません。入れる場所を教えてください。")
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: 教わる

    /// 欄を一つずつ選んでもらい、そこに入れる項目を尋ねて覚える。選ぶたびにその場で入れて見せる。
    /// Esc か、ボタンをもう一度押すか、ページが移ると終わる。
    func teach(_ credentials: Credentials, title: String, on page: Page, at url: URL) async {
        guard let site = HiddenElementStore.site(for: url) else {
            state = .failed("このページでは入れる場所を教われません。")
            return
        }
        state = .teaching(title)
        teachingPage = page
        defer {
            if teachingPage === page { teachingPage = nil }
        }
        while state == .teaching(title), page.url == url {
            let assigned = places.places(on: site).map { place in
                ["selector": place.selector, "label": credentials.fields.first { $0.key == place.field }?.label ?? place.field]
            }
            guard let picked = try? await page.callJavaScript(Self.pickScript, arguments: [
                "host": Self.host(of: url), "title": title, "assigned": assigned,
            ], contentWorld: Self.world) as? [String: Any],
                let selector = picked["selector"] as? String,
                let x = picked["x"] as? Double, let y = picked["y"] as? Double,
                state == .teaching(title)
            else { break }
            let current = places.field(at: selector, on: site)
            let isPassword = picked["password"] as? Bool ?? false
            let fitting = credentials.fields.filter { Self.fits($0.key, passwordField: isPassword) }
            if fitting.isEmpty, current == nil {
                // 選べるものが一つもないメニューは出さない。パスワード欄でしか起きない。
                state = .failed(Self.noPassword(title))
                break
            }
            switch menu(fitting, current, CGPoint(x: x, y: y), page) {
            case .field(let field)?:
                places.set(field.key, at: selector, on: site)
                _ = try? await page.callJavaScript(Self.placeScript, arguments: [
                    "host": Self.host(of: url), "pairs": [["selector": selector, "value": field.value, "field": field.key]],
                ], contentWorld: Self.world)
            case .unassign?:
                places.set(nil, at: selector, on: site)
            case nil:
                break
            }
        }
        if state == .teaching(title) { state = .idle }
    }

    // MARK: ページの中

    /// ページのスクリプトから触られない実行環境。入れた値そのものはページから読めるが、入れる手順を横取りさせない。
    static let world = WKContentWorld.world(name: "password-fill")

    /// 入力欄を探して入れ、入れた項目の名前（`Credentials.Field.key`）を返す。トップのページだけを見る。
    /// 待っているあいだに別のアドレスへ移っていたら何も入れない。
    ///
    /// `places` はそのサイトで教わった場所。今のページにそのどれかがあればそこだけに入れ、一つもなければ欄の種類から推す。
    /// 何段にも分かれるログインでも、その段に出ている欄にだけ入る。
    static func fill(_ credentials: Credentials, into page: Page, at url: URL, places: [LoginFieldPlace] = []) async throws -> [String] {
        let host = host(of: url)
        let pairs = places.compactMap { place in
            credentials.value(for: place.field).map { ["selector": place.selector, "value": $0, "field": place.field] }
        }
        if !pairs.isEmpty {
            let placed = try await page.callJavaScript(placeScript, arguments: ["host": host, "pairs": pairs], contentWorld: world)
            if let placed = placed as? [String], !placed.isEmpty { return placed }
        }
        let result = try await page.callJavaScript(guessScript, arguments: [
            "host": host,
            "username": credentials.username,
            "passwordValue": credentials.password,
            "oneTimeCode": credentials.oneTimeCode ?? "",
        ], contentWorld: world)
        return result as? [String] ?? []
    }

    static func noPassword(_ title: String) -> String {
        "1Password の「\(title)」にはパスワードが登録されていません。"
    }

    /// その項目をその欄に入れてよいか。ユーザー名をパスワード欄に入れたり、パスワードを伏せない欄に入れて画面に出したりしない。
    /// 教わるときのメニューと、教わった場所に入れるときの両方で守る（取り違えて覚えたものも入れない）。
    static func fits(_ field: String, passwordField: Bool) -> Bool {
        switch field {
        case Credentials.usernameKey: !passwordField
        case Credentials.passwordKey: passwordField
        default: true
        }
    }

    /// ページの `location.host` と同じ形（ポートがあれば付ける）。
    private static func host(of url: URL) -> String {
        (url.host() ?? "") + (url.port.map { ":\($0)" } ?? "")
    }

    /// 見えていて書ける欄か、と、値の入れ方。どのスクリプトでも使う。
    /// 値は自分の実行環境から入れるので、React などがページの側で値の書き込みを見張っていても素通りし、
    /// 続けて出す `input` で変化に気づいてもらえる。
    private static let helpers = """
        const shown = el => !el.disabled && !el.readOnly && el.getClientRects().length > 0
            && getComputedStyle(el).visibility !== "hidden";
        const put = (el, value) => {
            el.focus();
            el.value = value;
            el.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertReplacementText", data: value }));
            el.dispatchEvent(new Event("change", { bubbles: true }));
        };
        """

    /// 教わった場所に入れる。見つかって、項目に合う欄（`fits` と同じ決まり）だけに、ページの上から順に入れる（フォーカスが最後の欄に残る）。
    private static let placeScript = """
        if (location.host !== host) return [];
        \(helpers)
        const find = selector => { try { return document.querySelector(selector); } catch { return null; } };
        const fits = (field, el) => field === "\(Credentials.usernameKey)" ? el.type !== "password"
            : field === "\(Credentials.passwordKey)" ? el.type === "password" : true;
        const found = pairs.map(pair => ({ ...pair, el: find(pair.selector) }))
            .filter(pair => pair.el && shown(pair.el) && fits(pair.field, pair.el));
        found.sort((a, b) => a.el.compareDocumentPosition(b.el) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1);
        for (const pair of found) put(pair.el, pair.value);
        return found.map(pair => pair.field);
        """

    /// 教わった場所がないときの欄の選び方:
    /// - パスワード欄は、フォーカスのあるものか、見えている最初のもの。
    /// - ユーザー名は、フォーカスのある文字の欄（パスワード欄と同じフォームのとき）か、パスワード欄の手前にある最後の文字の欄。
    ///   パスワード欄がない（ユーザー名だけ先に聞く）ページでは、名前やメールの欄らしいもの。
    /// - パスワード欄がなく、ワンタイムコードの欄があれば、コードだけ入れる。
    private static let guessScript = """
        if (location.host !== host) return [];
        \(helpers)
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

        const filled = [];
        if (name && username) { put(name, username); filled.push("\(Credentials.usernameKey)"); }
        if (password && passwordValue) { put(password, passwordValue); filled.push("\(Credentials.passwordKey)"); }
        if (code) { put(code, oneTimeCode); filled.push("\(Credentials.oneTimeCodeKey)"); }
        return filled;
        """

    /// 入力欄を一つクリックしてもらい、その欄のセレクタと、メニューを出す位置（欄の左下。ページの表示範囲の左上から）を返す。
    /// Esc か `haneStopPicking()` で `null` を返す。選んでいるあいだのクリックはページへ渡さない。
    ///
    /// 印は、ページの CSS に左右されないよう閉じたシャドウルートの中に置く。教わった欄には、入れる項目の名前を添える。
    /// セレクタは、ページが作り直されても当たりやすいよう、`name` などの属性で一つに絞れればそれを使う。
    private static let pickScript = """
        if (location.host !== host) return null;
        globalThis.haneStopPicking?.();
        return await new Promise(resolve => {
            const isField = el => el instanceof HTMLInputElement
                && !["hidden", "submit", "button", "checkbox", "radio", "image", "reset", "file", "range", "color"].includes(el.type);
            const style = (el, props) => { for (const [k, v] of Object.entries(props)) el.style.setProperty(k, v, "important"); };
            const overlay = document.createElement("div");
            style(overlay, { position: "fixed", inset: "0", "z-index": "2147483647", "pointer-events": "none" });
            const root = overlay.attachShadow({ mode: "closed" });
            const banner = document.createElement("div");
            banner.textContent = "入れる欄をクリック — " + title + "（Esc で終わる）";
            style(banner, { position: "fixed", left: "50%", bottom: "16px", transform: "translateX(-50%)",
                padding: "6px 12px", "border-radius": "8px", background: "rgba(0,0,0,0.8)", color: "white",
                font: "13px -apple-system, sans-serif" });
            const hover = document.createElement("div");
            style(hover, { position: "fixed", border: "2px solid #0a84ff", "border-radius": "4px", display: "none" });
            const tags = document.createElement("div");
            root.append(tags, hover, banner);
            document.documentElement.append(overlay);

            let current = null;
            const box = (el, target, color) => {
                const r = el.getBoundingClientRect();
                style(target, { left: (r.left - 2) + "px", top: (r.top - 2) + "px", width: r.width + "px", height: r.height + "px",
                    "border-color": color });
            };
            const render = () => {
                tags.replaceChildren();
                for (const { selector, label } of assigned) {
                    let el = null;
                    try { el = document.querySelector(selector); } catch {}
                    if (!el) continue;
                    const mark = document.createElement("div");
                    style(mark, { position: "fixed", border: "2px solid #30d158", "border-radius": "4px" });
                    box(el, mark, "#30d158");
                    const name = document.createElement("div");
                    name.textContent = label;
                    style(name, { position: "absolute", right: "0", top: "-20px", padding: "1px 6px", "border-radius": "4px",
                        background: "#30d158", color: "black", font: "11px -apple-system, sans-serif", "white-space": "nowrap" });
                    mark.append(name);
                    tags.append(mark);
                }
                if (current) { box(current, hover, "#0a84ff"); style(hover, { display: "block" }); }
                else style(hover, { display: "none" });
            };
            const unique = selector => { try { return document.querySelectorAll(selector).length === 1; } catch { return false; } };
            const selectorFor = el => {
                const tag = el.localName;
                for (const name of ["name", "autocomplete", "id", "type", "aria-label", "placeholder"]) {
                    const value = el.getAttribute(name);
                    if (!value) continue;
                    const selector = name === "id" ? "#" + CSS.escape(value) : tag + "[" + name + "=\\"" + CSS.escape(value) + "\\"]";
                    if (unique(selector)) return selector;
                }
                const parts = [];
                for (let node = el; node && node !== document.documentElement; node = node.parentElement) {
                    if (node.id && unique("#" + CSS.escape(node.id))) { parts.unshift("#" + CSS.escape(node.id)); break; }
                    let part = CSS.escape(node.localName);
                    const parentEl = node.parentElement;
                    if (parentEl) {
                        const sameTag = Array.from(parentEl.children).filter(child => child.localName === node.localName);
                        if (sameTag.length > 1) part += ":nth-of-type(" + (sameTag.indexOf(node) + 1) + ")";
                    }
                    parts.unshift(part);
                    if (unique(parts.join(" > "))) break;
                }
                return parts.join(" > ");
            };

            const swallow = event => {
                if (!isField(event.target)) return;
                event.preventDefault();
                event.stopImmediatePropagation();
            };
            const onMove = event => {
                const next = isField(event.target) ? event.target : null;
                if (next !== current) { current = next; render(); }
            };
            const onClick = event => {
                if (!isField(event.target)) return;
                swallow(event);
                const r = event.target.getBoundingClientRect();
                finish({ selector: selectorFor(event.target), x: r.left, y: r.bottom, password: event.target.type === "password" });
            };
            const onKey = event => {
                if (event.key !== "Escape") return;
                event.preventDefault();
                event.stopImmediatePropagation();
                finish(null);
            };
            const listeners = [["mousemove", onMove], ["mousedown", swallow], ["mouseup", swallow], ["click", onClick],
                ["keydown", onKey], ["scroll", render]];
            for (const [type, listener] of listeners) addEventListener(type, listener, true);
            const finish = value => {
                for (const [type, listener] of listeners) removeEventListener(type, listener, true);
                overlay.remove();
                if (globalThis.haneStopPicking === stop) delete globalThis.haneStopPicking;
                resolve(value);
            };
            const stop = () => finish(null);
            globalThis.haneStopPicking = stop;
            render();
        });
        """
}

/// 欄を選んだときに出す、入れる項目のメニュー。
@MainActor
enum FieldMenuPresenter {
    static func show(_ fields: [Credentials.Field], current: String?, at point: CGPoint, on page: Page) -> PasswordFill.FieldChoice? {
        let chooser = Chooser()
        let menu = NSMenu()
        for (index, field) in fields.enumerated() {
            let item = NSMenuItem(title: field.label, action: #selector(Chooser.choose(_:)), keyEquivalent: "")
            item.target = chooser
            item.tag = index
            item.state = field.key == current ? .on : .off
            menu.addItem(item)
        }
        if current != nil {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "この欄には入れない", action: #selector(Chooser.choose(_:)), keyEquivalent: "")
            item.target = chooser
            item.tag = -1
            menu.addItem(item)
        }
        // メニューは選ぶか閉じるまで戻らない。
        page.popUp(menu, at: point)
        guard let tag = chooser.chosen else { return nil }
        return tag < 0 ? .unassign : .field(fields[tag])
    }

    private final class Chooser: NSObject {
        var chosen: Int?

        @objc func choose(_ sender: NSMenuItem) {
            chosen = sender.tag
        }
    }
}
