import WebKit

/// ⌥右クリックでページの要素を選び、隠すためのスクリプト。
///
/// 普通の右クリックの標準メニューは残したいので、WebKit for SwiftUI のメニュー差し替え
/// （`webViewContextMenu`。標準の項目がすべて消える）は使わず、ページの中で ⌥ 付きの右クリックだけを拾う。
/// ページのスクリプトから触られないよう、専用の実行環境で動かす。待っているのは
/// クリックの事象だけで、選んでいる間を除いて何も動かない。
@MainActor
enum ElementPicker {
    static let world = WKContentWorld.world(name: "element-picker")
    static let handlerName = "haneHideElement"

    static let userScript = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)

    private static let source = """
    (() => {
      const marker = 'haneElementPicker';

      // 子フレームの中で ⌥右クリックされたら、親へ知らせてフレームごと選ばせる。
      // 広告は別のサイトのフレームに入っていることが多く、隠したいのはフレームの方なので。
      if (window !== window.top) {
        addEventListener('contextmenu', event => {
          if (!event.altKey) return;
          event.preventDefault();
          event.stopImmediatePropagation();
          parent.postMessage({ [marker]: 'pick' }, '*');
        }, true);
        addEventListener('message', event => {
          if (event.data && event.data[marker] === 'pick') parent.postMessage({ [marker]: 'pick' }, '*');
        });
        return;
      }

      let picking = null;
      let ui = null;

      // ページのCSSやCSPに左右されないよう、閉じたシャドウルートの中に、
      // 文字列のHTMLやstyle要素を使わずに組み立てる。
      const style = (el, props) => { for (const [k, v] of Object.entries(props)) el.style.setProperty(k, v, 'important'); };
      const buildUI = () => {
        const host = document.createElement('hane-element-picker');
        style(host, { all: 'initial', position: 'fixed', top: '0', left: '0', width: '0', height: '0', 'z-index': '2147483647' });
        const root = host.attachShadow({ mode: 'closed' });
        const box = document.createElement('div');
        style(box, { position: 'fixed', border: '2px solid #e5484d', background: 'rgba(229,72,77,0.15)',
          'box-sizing': 'border-box', 'pointer-events': 'none', 'border-radius': '2px' });
        const panel = document.createElement('div');
        style(panel, { position: 'fixed', display: 'flex', gap: '6px', 'align-items': 'center', padding: '4px 6px',
          background: '#1f1f1f', color: '#fff', font: '12px -apple-system, sans-serif', 'border-radius': '6px',
          'box-shadow': '0 2px 8px rgba(0,0,0,0.3)', 'white-space': 'nowrap' });
        const label = document.createElement('code');
        style(label, { font: '11px ui-monospace, monospace', 'max-width': '360px', overflow: 'hidden', 'text-overflow': 'ellipsis' });
        panel.append(label);
        for (const [text, act] of [['親へ ↑', up], ['子へ ↓', down], ['隠す ⏎', confirm], ['やめる Esc', stop]]) {
          const button = document.createElement('button');
          button.textContent = text;
          style(button, { font: '12px -apple-system, sans-serif', padding: '2px 6px', border: '0', 'border-radius': '4px',
            background: '#444', color: '#fff', cursor: 'pointer' });
          button.addEventListener('click', event => { event.preventDefault(); event.stopPropagation(); act(); });
          panel.append(button);
        }
        root.append(box, panel);
        return { host, box, panel, label };
      };

      const current = () => picking.trail[picking.index];

      const describe = el => {
        let text = el.localName;
        if (el.id) text += '#' + el.id;
        for (const name of Array.from(el.classList).slice(0, 2)) text += '.' + name;
        return text;
      };

      const render = () => {
        if (!picking) return;
        const el = current();
        const r = el.getBoundingClientRect();
        style(ui.box, { left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px' });
        ui.label.textContent = describe(el) + '  ' + Math.round(r.width) + '×' + Math.round(r.height);
        const panelHeight = 30;
        const below = r.bottom + 6;
        const top = below + panelHeight < innerHeight ? below : Math.max(4, r.top - panelHeight - 6);
        const left = Math.min(Math.max(4, r.left), Math.max(4, innerWidth - ui.panel.offsetWidth - 4));
        style(ui.panel, { top: top + 'px', left: left + 'px' });
      };

      // 広告の枠は、右クリックした画像などの何段か上にあることが多いので、親へ広げられるようにする。
      function up() {
        const parentEl = current().parentElement;
        if (!parentEl || parentEl === document.documentElement || parentEl === document.body) return;
        if (picking.index === picking.trail.length - 1) picking.trail.push(parentEl);
        picking.index += 1;
        render();
      }

      function down() {
        if (picking.index === 0) return;
        picking.index -= 1;
        render();
      }

      const onKey = event => {
        const act = { ArrowUp: up, ArrowDown: down, Enter: confirm, Escape: stop }[event.key];
        if (!act) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        act();
      };

      function start(target) {
        if (picking) stop();
        ui = ui || buildUI();
        picking = { trail: [target], index: 0 };
        document.documentElement.append(ui.host);
        // 子フレームの中を右クリックしたときは、キーがフレームの方へ行ってしまうので取り戻す。
        if (document.activeElement && /^(iframe|frame)$/i.test(document.activeElement.localName)) {
          document.activeElement.blur();
          window.focus();
        }
        addEventListener('keydown', onKey, true);
        addEventListener('scroll', render, { capture: true, passive: true });
        addEventListener('resize', render, { passive: true });
        render();
      }

      function stop() {
        if (!picking) return;
        picking = null;
        ui.host.remove();
        removeEventListener('keydown', onKey, true);
        removeEventListener('scroll', render, { capture: true });
        removeEventListener('resize', render);
      }

      function confirm() {
        const el = current();
        const selector = selectorFor(el);
        stop();
        // 次に開いたときはルールで隠れるが、今のページはここで隠す。
        el.style.setProperty('display', 'none', 'important');
        window.webkit.messageHandlers.\(handlerName).postMessage({ selector });
      }

      // 要素をページの中でひとつに絞れるセレクタ。ページが作り直されても当たりやすいよう、
      // 一意なIDがあればそこで止め、なければクラスと兄弟の中の順番で上へたどる。
      const selectorFor = el => {
        const parts = [];
        for (let node = el; node && node !== document.documentElement; node = node.parentElement) {
          if (node.id) {
            const byID = '#' + CSS.escape(node.id);
            if (document.querySelectorAll(byID).length === 1) { parts.unshift(byID); break; }
          }
          let part = CSS.escape(node.localName);
          for (const name of Array.from(node.classList).slice(0, 3)) part += '.' + CSS.escape(name);
          const parentEl = node.parentElement;
          if (parentEl) {
            const siblings = Array.from(parentEl.children);
            if (siblings.filter(child => child.matches(part)).length > 1) {
              const sameTag = siblings.filter(child => child.localName === node.localName);
              part += ':nth-of-type(' + (sameTag.indexOf(node) + 1) + ')';
            }
          }
          parts.unshift(part);
          if (document.querySelectorAll(parts.join(' > ')).length === 1) break;
        }
        return parts.join(' > ');
      };

      addEventListener('contextmenu', event => {
        if (!event.altKey || !(event.target instanceof Element)) return;
        if (ui && ui.host.contains(event.target)) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        start(event.target);
      }, true);

      addEventListener('message', event => {
        if (!event.data || event.data[marker] !== 'pick') return;
        const frame = Array.from(document.querySelectorAll('iframe, frame')).find(f => f.contentWindow === event.source);
        if (frame) start(frame);
      });
    })();
    """
}
