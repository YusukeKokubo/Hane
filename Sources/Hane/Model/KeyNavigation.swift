import WebKit

/// ページの中で文字のキーだけでスクロールやリンクの選択、タブの移動をする（Chrome の Vimium と同じ考え方）。
///
/// キーはページの中のスクリプトで拾う。入力欄に打っているかを正しく知っているのはページだけで、
/// アプリの局所モニタで拾うと、入力欄の文字まで横取りしてしまうため。スクロールとリンクの選択はページの中で済ませ、
/// タブの移動や戻る・進むのようにブラウザにしかできないものだけ、アプリへ知らせる（`KeyCommand`）。
///
/// ページのスクリプトから触られないよう専用の実行環境で動かし、合成されたキー（`isTrusted` でないもの）は無視する。
/// ページが勝手にタブを閉じたり開いたりできないようにするため。待っているのはキーと押した場所の事象だけで、
/// リンクの印はキーを押したときにだけ作る。
@MainActor
enum KeyNavigation {
    static let world = WKContentWorld.world(name: "key-navigation")
    static let handlerName = "haneKeys"

    /// どのサイトで使うか。設定（`SettingsStore`）が入れる。変わると、開いているページにもその場で効かせる。
    static var policy = Policy(UserSettings()) {
        didSet {
            guard policy != oldValue else { return }
            router.pushPolicy()
        }
    }

    struct Policy: Equatable {
        var isOn: Bool
        /// 使わないサイト。ホスト名で、そのサブドメインも含む。
        var excludedSites: [String]

        init(_ settings: UserSettings) {
            isOn = settings.usesKeyNavigation
            excludedSites = settings.keyNavigationExcludedSites
        }

        /// `host` が空なのは `file://` のページなど。除く一覧には当たらない。
        func allows(host: String) -> Bool {
            isOn && Self.match(host: host, in: excludedSites) == nil
        }

        /// `host` に当たる一覧の項目。そのホストそのものか、親のドメインのもの。
        static func match(host: String, in sites: [String]) -> String? {
            let host = host.lowercased()
            guard !host.isEmpty else { return nil }
            return sites.first { host == $0 || host.hasSuffix("." + $0) }
        }
    }

    /// 打ったものや貼ったものから、除く一覧に入れるホスト名を取り出す。URL でもホスト名だけでもよい。
    static func site(from input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.contains("://") {
            text = URL(string: text)?.host() ?? ""
        } else if let slash = text.firstIndex(of: "/") {
            text = String(text[..<slash])
        }
        if text.hasPrefix("*.") { text.removeFirst(2) }
        if text.hasPrefix(".") { text.removeFirst() }
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace || $0 == ":" }) else { return nil }
        return text
    }

    /// プロファイルのページの設定に付ける。そのプロファイルの全ページに効く。
    static func attach(to controller: WKUserContentController) {
        controller.addUserScript(userScript)
        controller.addScriptMessageHandler(router, contentWorld: world, name: handlerName)
    }

    /// その Web ビューからの知らせを、このページへ流す。どちらかが消えれば対応も消える。
    static func route(from webView: WKWebView, to page: Page) {
        router.pages.setObject(page, forKey: webView)
    }

    private static let router = Router()

    private final class Router: NSObject, WKScriptMessageHandlerWithReply {
        let pages = NSMapTable<WKWebView, Page>.weakToWeakObjects()

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return (nil, nil) }
            // 使うかどうかは、ページの申告ではなく WebKit が知っているフレームの出どころで決める。
            let origin = message.frameInfo.securityOrigin
            let allowed = KeyNavigation.policy.allows(host: origin.host)
            if body["hello"] != nil { return (allowed, nil) }
            guard allowed,
                  let webView = message.webView,
                  let page = pages.object(forKey: webView),
                  let name = body["command"] as? String,
                  let command = KeyCommand(name: name, url: body["url"] as? String, fromProtocol: origin.protocol)
            else { return (nil, nil) }
            page.receive(command)
            return (nil, nil)
        }

        /// 設定が変わったら、開いているページのスクリプトに今の可否を伝える。読み込み直しを待たずに効かせるため。
        func pushPolicy() {
            let policy = KeyNavigation.policy
            for case let page as Page in pages.objectEnumerator() ?? NSEnumerator() {
                let allowed = policy.allows(host: page.url?.host() ?? "")
                Task {
                    _ = try? await page.callJavaScript(
                        "globalThis.haneKeys && globalThis.haneKeys.setEnabled(allowed)",
                        arguments: ["allowed": allowed], contentWorld: KeyNavigation.world)
                }
            }
        }
    }

    static let userScript = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world)

    private static let source = """
    (() => {
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
      if (!handler) return;
      const send = message => { try { return handler.postMessage(message); } catch { return Promise.resolve(null); } };

      // アプリが使ってよいと答えるまでは何もしない（答えはすぐ返る）。
      let enabled = false;
      send({ hello: true }).then(answer => { enabled = answer === true; }, () => {});
      globalThis.haneKeys = { setEnabled(value) { enabled = value === true; if (!enabled) { stopHints(); pending = ''; } } };

      // MARK: 入力欄かどうか

      const notText = new Set(['button', 'submit', 'reset', 'checkbox', 'radio', 'range', 'color', 'file', 'image', 'hidden']);
      const isEditable = el => {
        if (!el || el.nodeType !== 1) return false;
        if (el.isContentEditable) return true;
        const tag = el.localName;
        if (tag === 'textarea' || tag === 'select') return true;
        return tag === 'input' && !notText.has(el.type);
      };
      // 部品の中に閉じこめた DOM（シャドウ DOM）の中の入力欄までたどる。
      const deepActive = () => {
        let el = document.activeElement;
        while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
        return el;
      };
      const parentOf = el => el.parentElement || (el.parentNode && el.parentNode.host) || null;

      // MARK: スクロール

      // 最後に押した所の近くからスクロールできる箱を探す。ページ全体でなく中の箱がスクロールするサイトが多いため。
      let lastClicked = null;
      addEventListener('mousedown', event => { if (event.isTrusted) lastClicked = event.composedPath()[0]; }, true);

      const root = () => document.scrollingElement || document.documentElement;
      const canScroll = (el, vertical) => {
        const room = vertical ? el.scrollHeight - el.clientHeight : el.scrollWidth - el.clientWidth;
        if (room <= 1) return false;
        if (el === root()) {
          // 全体のスクロールを止めているページ（ダイアログを出している間など）は動かさない。
          const blocked = e => e && /hidden|clip/.test(vertical ? getComputedStyle(e).overflowY : getComputedStyle(e).overflowX);
          return !blocked(document.documentElement) && !blocked(document.body);
        }
        return /auto|scroll|overlay/.test(vertical ? getComputedStyle(el).overflowY : getComputedStyle(el).overflowX);
      };
      const scroller = vertical => {
        const starts = [];
        if (lastClicked && lastClicked.isConnected) starts.push(lastClicked);
        const center = document.elementFromPoint(innerWidth / 2, innerHeight / 2);
        if (center) starts.push(center);
        for (const start of starts) {
          for (let el = start; el && el.nodeType === 1; el = parentOf(el)) {
            if (canScroll(el, vertical)) return el;
          }
        }
        return root();
      };
      const viewHeight = el => el === root() ? innerHeight : el.clientHeight;
      // 動きは自分でフレームごとに刻む。押せば一歩ぶんを滑らかに進め、押しっぱなしの間は一定の速さで流し、離せば止める。
      // OS のキーの繰り返しに合わせて一歩ずつ動かすと、繰り返しの間隔（既定で0.09秒）ごとに飛んでカクつく。
      // ブラウザの smooth に任せると、続けて頼んだとき前の動きを打ち消して進まなくなる。
      // フレームを回すのは動いている間だけ。窓が隠れているとフレームの合図が止まるので、来なければタイマーで代わりに進める。
      const step = 70;
      const easing = 60;      // 残りの道のりを詰める速さ（ミリ秒）。小さいほどきびきび止まる。
      const holdSpeed = 1.0;  // 押しっぱなしの間の速さ（ピクセル/ミリ秒）。
      const holdDelay = 90;   // 押してから流し始めるまで。軽く叩いたときは一歩だけ進めるため。
      const holdRamp = 150;   // 流す速さまで上げきる時間。一歩の動きから途切れずにつなぐため。
      const glide = { el: null, x: 0, y: 0, carryX: 0, carryY: 0, hold: null, last: 0, frame: 0, timer: 0 };

      const unschedule = () => {
        cancelAnimationFrame(glide.frame);
        clearTimeout(glide.timer);
        glide.frame = glide.timer = 0;
      };
      const schedule = () => {
        glide.frame = requestAnimationFrame(tick);
        glide.timer = setTimeout(() => tick(performance.now()), 50);
      };
      const stopGlide = () => {
        unschedule();
        Object.assign(glide, { el: null, x: 0, y: 0, carryX: 0, carryY: 0, hold: null });
      };
      const tick = now => {
        unschedule();
        const el = glide.el;
        if (!el || !el.isConnected) { stopGlide(); return; }
        const dt = Math.max(0, Math.min(now - glide.last, 50));
        glide.last = now;
        const f = 1 - Math.exp(-dt / easing);
        const take = rest => Math.abs(rest) < 1 ? rest : rest * f;
        const mx = take(glide.x), my = take(glide.y);
        glide.x -= mx;
        glide.y -= my;
        let vx = 0, vy = 0;
        const hold = glide.hold;
        if (hold && now > hold.start) {
          const speed = holdSpeed * Math.min(1, (now - hold.start) / holdRamp) * dt;
          vx = hold.x * speed;
          vy = hold.y * speed;
        }
        // 1ピクセルに満たない分は持ち越す。小刻みに頼むと端数が丸められて消えるため。動きの終わりには丸めて片付ける。
        glide.carryX += mx + vx;
        glide.carryY += my + vy;
        const settle = (rest, carry, held) => rest === 0 && !held ? Math.round(carry) : Math.trunc(carry);
        const ix = settle(glide.x, glide.carryX, hold && hold.x), iy = settle(glide.y, glide.carryY, hold && hold.y);
        glide.carryX -= ix;
        glide.carryY -= iy;
        if (ix || iy) {
          const bx = el.scrollLeft, by = el.scrollTop;
          // 'instant' を明示する。ページの CSS が smooth にしていると、刻んだ動きがさらに遅れて重なるため。
          el.scrollBy({ left: ix, top: iy, behavior: 'instant' });
          // 端に着いたらその向きの動きをやめる。押しっぱなしのまま空回りさせないため。
          if (ix && el.scrollLeft === bx) { glide.x = glide.carryX = 0; if (hold && hold.x) glide.hold = null; }
          if (iy && el.scrollTop === by) { glide.y = glide.carryY = 0; if (hold && hold.y) glide.hold = null; }
        }
        if (glide.x || glide.y || glide.hold) schedule();
        else stopGlide();
      };
      const glideBy = (el, dx, dy) => {
        if (glide.el !== el) { stopGlide(); glide.el = el; }
        glide.x += dx;
        glide.y += dy;
        if (!glide.timer) { glide.last = performance.now(); schedule(); }
      };
      const releaseHold = code => { if (glide.hold && (code === undefined || glide.hold.code === code)) glide.hold = null; };
      // キーを離した知らせを取りこぼしても流れ続けないよう、窓から外れたら止める。
      addEventListener('blur', () => releaseHold());
      document.addEventListener('visibilitychange', () => releaseHold());

      const scrollBy = (dx, dy, event) => {
        // 押しっぱなしの繰り返しは流れのほうが受け持つ。
        if (event.repeat) return;
        glideBy(scroller(dy !== 0), dx, dy);
        glide.hold = { code: event.code, x: Math.sign(dx), y: Math.sign(dy), start: performance.now() + holdDelay };
      };
      const scrollPage = fraction => {
        const el = scroller(true);
        glideBy(el, 0, viewHeight(el) * fraction);
      };
      // 端までの一息の動きはブラウザに任せる。長い道のりを刻むと、窓が隠れてタイマーが間引かれたとき着くのが遅れるため。
      const scrollToEdge = bottom => {
        const el = scroller(true);
        stopGlide();
        el.scrollTo({ top: bottom ? el.scrollHeight : 0, behavior: 'smooth' });
      };

      // MARK: リンクの印

      const clickable = 'a[href],button,input,textarea,select,summary,label[for],[role=button],[role=link],[role=tab],' +
        '[role=menuitem],[role=menuitemcheckbox],[role=menuitemradio],[role=option],[role=checkbox],[role=radio],' +
        '[role=switch],[role=treeitem],[role=combobox],[contenteditable=""],[contenteditable=true],[onclick],' +
        '[tabindex]:not([tabindex="-1"])';
      const alphabet = 'sadfjklewcmpgh';

      const visibleRect = el => {
        for (const r of el.getClientRects()) {
          if (r.width < 3 || r.height < 3) continue;
          if (r.bottom <= 0 || r.right <= 0 || r.top >= innerHeight || r.left >= innerWidth) continue;
          return r;
        }
        return null;
      };
      // ほかの要素に覆われていないか。押したときに実際に届く要素かを、真ん中と左上寄りの点で確かめる。
      const reachable = (el, r) => {
        const points = [
          [r.left + r.width / 2, r.top + r.height / 2],
          [r.left + Math.min(4, r.width / 2), r.top + Math.min(4, r.height / 2)],
        ];
        for (const [x, y] of points) {
          if (x < 0 || y < 0 || x >= innerWidth || y >= innerHeight) continue;
          let hit = document.elementFromPoint(x, y);
          while (hit && hit.shadowRoot) {
            const inner = hit.shadowRoot.elementFromPoint(x, y);
            if (!inner || inner === hit) break;
            hit = inner;
          }
          for (let e = hit; e; e = parentOf(e)) if (e === el) return true;
        }
        return false;
      };
      const collect = (scope, out) => {
        for (const el of scope.querySelectorAll(clickable)) out.push(el);
        for (const el of scope.querySelectorAll('*')) if (el.shadowRoot) collect(el.shadowRoot, out);
        return out;
      };
      const labelsFor = count => {
        let length = 1;
        while (alphabet.length ** length < count) length++;
        return Array.from({ length: count }, (_, i) => {
          let label = '';
          for (let k = 0, n = i; k < length; k++, n = Math.floor(n / alphabet.length)) label = alphabet[n % alphabet.length] + label;
          return label;
        });
      };

      // ページの CSS に崩されないよう、閉じたシャドウルートの中に、文字列の HTML を使わずに組み立てる。
      const style = (el, props) => { for (const [k, v] of Object.entries(props)) el.style.setProperty(k, v, 'important'); };
      let hints = null;

      const startHints = newTab => {
        const picked = [];
        const seen = new Set();
        for (const el of collect(document, [])) {
          if (seen.has(el) || (el.localName === 'input' && el.type === 'hidden')) continue;
          // リンクやボタンの中の部品には付けない。押せば同じ所へ行くため。
          const outer = el.parentElement && el.parentElement.closest('a[href],button');
          if (outer && seen.has(outer)) continue;
          const r = visibleRect(el);
          if (!r || !reachable(el, r)) continue;
          seen.add(el);
          picked.push({ el, r });
        }
        if (!picked.length) return;
        const host = document.createElement('hane-key-hints');
        style(host, { all: 'initial', position: 'fixed', top: '0', left: '0', width: '0', height: '0', 'z-index': '2147483647' });
        const shadow = host.attachShadow({ mode: 'closed' });
        const labels = labelsFor(picked.length);
        const items = picked.map(({ el, r }, i) => {
          const tag = document.createElement('div');
          style(tag, { position: 'fixed', left: Math.max(0, r.left) + 'px', top: Math.max(0, r.top) + 'px',
            padding: '0 3px', background: '#ffd84d', color: '#1f1f1f', border: '1px solid #b8860b', 'border-radius': '3px',
            font: 'bold 11px/15px ui-monospace, monospace', 'text-transform': 'uppercase', 'pointer-events': 'none',
            'box-shadow': '0 1px 3px rgba(0,0,0,0.3)', 'white-space': 'nowrap' });
          const typed = document.createElement('span');
          style(typed, { opacity: '0.35' });
          const rest = document.createElement('span');
          rest.textContent = labels[i];
          tag.append(typed, rest);
          shadow.append(tag);
          return { el, label: labels[i], tag, typed, rest };
        });
        (document.body || document.documentElement).append(host);
        hints = { host, items, typed: '', newTab };
        // 印を出している間にページが動いたら、位置がずれるのでやめる。中の箱のスクロールは拾わない
        // （勝手に流れる箱がページにあると、印がすぐ消えてしまうため）。
        addEventListener('scroll', stopHints);
        addEventListener('resize', stopHints, true);
        addEventListener('mousedown', stopHints, true);
      };

      function stopHints() {
        if (!hints) return;
        hints.host.remove();
        hints = null;
        removeEventListener('scroll', stopHints);
        removeEventListener('resize', stopHints, true);
        removeEventListener('mousedown', stopHints, true);
      }

      const typeHint = key => {
        const typed = hints.typed + key;
        const matching = hints.items.filter(item => item.label.startsWith(typed));
        if (!matching.length) return;
        hints.typed = typed;
        if (matching.length === 1 && matching[0].label === typed) {
          const { el } = matching[0];
          const newTab = hints.newTab;
          stopHints();
          activate(el, newTab);
          return;
        }
        for (const item of hints.items) {
          const on = item.label.startsWith(typed);
          style(item.tag, { display: on ? 'block' : 'none' });
          item.typed.textContent = on ? typed : '';
          item.rest.textContent = on ? item.label.slice(typed.length) : item.label;
        }
      };

      const activate = (el, newTab) => {
        const link = el.closest('a[href]');
        if (newTab && link) {
          send({ command: 'openTab', url: link.href });
          return;
        }
        if (isEditable(el)) {
          el.focus();
          return;
        }
        // マウスで押したときと同じ順に事象を送る。押し下げで動くメニューやボタンが多いため。
        if (typeof el.focus === 'function') el.focus({ preventScroll: true });
        const r = el.getBoundingClientRect();
        const at = { bubbles: true, cancelable: true, composed: true, view: window, button: 0,
          clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 };
        for (const type of ['pointerover', 'mouseover', 'pointerdown', 'mousedown', 'pointerup', 'mouseup']) {
          const down = type.endsWith('down');
          const init = { ...at, buttons: down ? 1 : 0 };
          el.dispatchEvent(type.startsWith('pointer')
            ? new PointerEvent(type, { ...init, pointerId: 1, pointerType: 'mouse', isPrimary: true })
            : new MouseEvent(type, init));
        }
        el.click();
      };

      const focusFirstInput = () => {
        for (const el of document.querySelectorAll('input,textarea,[contenteditable=""],[contenteditable=true]')) {
          if (isEditable(el) && !el.disabled && visibleRect(el)) { el.focus(); return; }
        }
      };

      // MARK: キー

      const commands = {
        j: e => scrollBy(0, step, e), k: e => scrollBy(0, -step, e),
        h: e => scrollBy(-step, 0, e), l: e => scrollBy(step, 0, e),
        d: () => scrollPage(0.5), u: () => scrollPage(-0.5),
        gg: () => scrollToEdge(false), G: () => scrollToEdge(true),
        f: () => startHints(false), F: () => startHints(true),
        gi: focusFirstInput,
        H: () => send({ command: 'back' }), L: () => send({ command: 'forward' }),
        r: () => send({ command: 'reload' }),
        K: () => send({ command: 'nextTab' }), gt: () => send({ command: 'nextTab' }),
        J: () => send({ command: 'previousTab' }), gT: () => send({ command: 'previousTab' }),
        x: () => send({ command: 'closeTab' }),
        o: () => send({ command: 'focusAddressBar' }),
        yy: () => send({ command: 'copyURL' }),
      };
      const prefixes = new Set(['g', 'y']);
      let pending = '';
      // 受け取ったキーは、離したときもページへ渡さない。押したときだけ横取りすると、離したときだけ届いて誤動作するページがある。
      const swallowed = new Set();

      const consume = event => {
        event.preventDefault();
        event.stopImmediatePropagation();
        swallowed.add(event.code);
      };

      addEventListener('keydown', event => {
        if (!enabled || !event.isTrusted || event.isComposing || event.keyCode === 229) return;
        if (event.metaKey || event.ctrlKey || event.altKey) {
          // ⌘ の付いたキーはメニューへ。印を出していればやめる。
          stopHints();
          pending = '';
          return;
        }
        if (hints) {
          consume(event);
          if (event.key === 'Escape') stopHints();
          else if (event.key === 'Backspace') {
            hints.typed = hints.typed.slice(0, -1);
            typeHint('');
          }
          else if (event.key.length === 1 && alphabet.includes(event.key.toLowerCase())) typeHint(event.key.toLowerCase());
          return;
        }
        const active = deepActive();
        if (isEditable(event.composedPath()[0]) || isEditable(active)) {
          // 入力欄から抜ける。Esc はページにも渡す（候補の一覧を閉じるなど、ページ自身も使うため）。
          if (event.key === 'Escape' && active && typeof active.blur === 'function') active.blur();
          return;
        }
        if (event.key.length !== 1) {
          if (event.key === 'Escape') pending = '';
          return;
        }
        for (const sequence of pending ? [pending + event.key, event.key] : [event.key]) {
          if (commands[sequence]) {
            pending = '';
            consume(event);
            commands[sequence](event);
            return;
          }
          if (prefixes.has(sequence)) {
            pending = sequence;
            consume(event);
            return;
          }
        }
        pending = '';
      }, true);

      for (const type of ['keypress', 'keyup']) {
        addEventListener(type, event => {
          if (!event.isTrusted) return;
          if (type === 'keyup') releaseHold(event.code);
          if (!swallowed.has(event.code)) return;
          event.preventDefault();
          event.stopImmediatePropagation();
          if (type === 'keyup') swallowed.delete(event.code);
        }, true);
      }
    })();
    """
}

/// ページの中のキー操作から、アプリに頼むこと。
enum KeyCommand: Equatable {
    case back, forward, reload
    case nextTab, previousTab, closeTab
    case focusAddressBar, copyURL
    /// 印で選んだリンクを裏の新しいタブで開く。
    case openInNewTab(URL)

    /// `fromProtocol` は知らせてきたページの出どころの種類。`file://` のリンクは `file://` のページからだけ開く。
    init?(name: String, url: String?, fromProtocol: String) {
        switch name {
        case "back": self = .back
        case "forward": self = .forward
        case "reload": self = .reload
        case "nextTab": self = .nextTab
        case "previousTab": self = .previousTab
        case "closeTab": self = .closeTab
        case "focusAddressBar": self = .focusAddressBar
        case "copyURL": self = .copyURL
        case "openTab":
            guard let url = url.flatMap(URL.init(string:)), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" || (scheme == "file" && fromProtocol == "file")
            else { return nil }
            self = .openInNewTab(url)
        default: return nil
        }
    }
}
