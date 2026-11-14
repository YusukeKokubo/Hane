/// ページの中で走らせるJavaScript。いずれも関数本体で、文字列を返す（`snapshot` と `frame` は値の組を返す）。
///
/// `snapshot` が要素に番号を振って控え、`act` がその番号で要素を操作する。
/// 控えはページのスクリプトから見えない専用の実行環境に置く。
/// iframe の中はフレームごとに同じスクリプトを走らせる。番号はページ全体の通しで、
/// 控えはその要素のあるフレームが持ち、主フレームはどの番号がどのフレームにあるか（`__frameRefs`）を持つ。
enum PageScripts {
    /// 中を読む子フレーム（iframe と frame）。番号の振り方を `snapshot` と `frame` でそろえるため一か所に置く。
    private static let childFrames = """
    const childFrames = () => Array.from(document.querySelectorAll('iframe, frame')).filter(f => {
      if (!f.contentWindow || !f.getClientRects().length) return false;
      const style = getComputedStyle(f);
      return style.visibility !== 'hidden' && style.display !== 'none';
    });
    """

    /// 主フレームで、番号が子フレームの要素なら、そのフレームへの道筋（子フレームの順番の並び）を返す。引数: `ref`。
    private static let route = """
    if (ref > 0 && window === window.top) {
      const routed = (window.__frameRefs || []).find(r => ref >= r.from && ref <= r.to);
      if (routed) return JSON.stringify({ descend: routed.path });
    }
    """

    /// 番号がなく（0）フォーカスが子フレームにあれば、そのフレームへ一段下りる。キーはフォーカスのある所へ送るため。
    private static let routeFocus = """
    if (ref === 0 && document.activeElement && /^(iframe|frame)$/i.test(document.activeElement.localName)) {
      const index = childFrames().indexOf(document.activeElement);
      if (index >= 0) return JSON.stringify({ descend: [index] });
    }
    """

    /// 子フレームを一つ指して、その中で走らせるための手がかりを返す。
    /// 引数: `index`（`childFrames` の順番）, `reveal`（表示している範囲の外ならスクロールして出す）。
    /// 返すのは、フレームの窓を表す `handle`（アプリが `WKFrameInfo` に引き直す）、フレームの中身の左上の位置
    /// （CSS の画素。このフレームの表示している範囲の左上から）、このフレームの表示している範囲の大きさ。
    static let frame = childFrames + """
    if (!window.webkit || !window.webkit.createJSHandle) return { error: 'この WebKit では子フレームを引けない（macOS 27 から）。' };
    const f = childFrames()[index];
    if (!f) return { error: 'フレームが見つからない（ページが変わった）。snapshot を取り直すこと。' };
    if (reveal) {
      const r = f.getBoundingClientRect();
      if (r.left < 0 || r.top < 0 || r.right > innerWidth || r.bottom > innerHeight) {
        f.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
      }
    }
    const r = f.getBoundingClientRect();
    const style = getComputedStyle(f);
    return {
      handle: window.webkit.createJSHandle(f.contentWindow),
      left: r.left + f.clientLeft + parseFloat(style.paddingLeft || 0),
      top: r.top + f.clientTop + parseFloat(style.paddingTop || 0),
      width: innerWidth, height: innerHeight
    };
    """

    /// 操作できる要素と見出しを、番号つきの一覧にする。引数: `start`（最初の番号）, `limit`（まだ出せる要素の数）。
    /// 一覧の行、出した要素の数、上限で省いた数、子フレームの名札を返す。
    static let snapshot = childFrames + """
    const selector = 'a[href],button,input,textarea,select,summary,[role=button],[role=link],[role=tab],' +
      '[role=menuitem],[role=checkbox],[role=radio],[role=switch],[role=textbox],[role=searchbox],' +
      '[role=combobox],[role=option],[contenteditable=""],[contenteditable=true],[onclick],h1,h2,h3';
    const clean = s => (s == null ? '' : String(s)).replace(/\\s+/g, ' ').trim();
    const clip = (s, n) => s.length > n ? s.slice(0, n - 1) + '…' : s;
    const visible = el => {
      if (!el.getClientRects().length) return false;
      const style = getComputedStyle(el);
      return style.visibility !== 'hidden' && style.display !== 'none';
    };
    const roleOf = el => {
      const explicit = el.getAttribute('role');
      if (explicit) return explicit;
      const tag = el.tagName.toLowerCase();
      if (tag === 'a') return 'link';
      if (tag === 'select') return 'select';
      if (tag === 'textarea') return 'textbox';
      if (tag === 'summary') return 'button';
      if (tag === 'input') {
        const type = (el.type || 'text').toLowerCase();
        if (['button', 'submit', 'reset', 'image'].includes(type)) return 'button';
        if (['checkbox', 'radio'].includes(type)) return type;
        return type === 'text' ? 'textbox' : 'textbox(' + type + ')';
      }
      if (el.isContentEditable) return 'textbox';
      return 'button';
    };
    const nameOf = el => {
      const labelled = (el.getAttribute('aria-labelledby') || '').split(/\\s+/)
        .map(id => id && document.getElementById(id)).filter(Boolean).map(e => e.innerText).join(' ');
      const tag = el.tagName.toLowerCase();
      const isField = tag === 'input' || tag === 'textarea' || tag === 'select';
      return clean(el.getAttribute('aria-label')) || clean(labelled) ||
        clean(el.labels && el.labels[0] && el.labels[0].innerText) ||
        (isField ? '' : clean(el.innerText)) ||
        clean(el.getAttribute('placeholder')) || clean(el.getAttribute('title')) ||
        clean(el.querySelector && el.querySelector('img[alt]') && el.querySelector('img[alt]').alt) ||
        (tag === 'input' && ['button', 'submit', 'reset'].includes(el.type) ? clean(el.value) : '') ||
        clean(el.getAttribute('name')) || clean(el.id);
    };

    // 番号は通しなので、控えは番号の位置に置く（子フレームの控えは手前が空いた並びになる）。
    const refs = [];
    const lines = [];
    let count = 0;
    let skipped = 0;
    for (const el of document.querySelectorAll(selector)) {
      if (!visible(el)) continue;
      const tag = el.tagName.toLowerCase();
      if (/^h[1-3]$/.test(tag)) {
        const heading = clean(el.innerText);
        if (heading && count < limit) lines.push('#'.repeat(Number(tag[1])) + ' ' + clip(heading, 100));
        continue;
      }
      if (tag === 'input' && el.type === 'hidden') continue;
      if (count >= limit) { skipped++; continue; }

      const number = start + count;
      refs[number - 1] = el;
      count++;
      let line = '[' + number + '] ' + roleOf(el) + ' "' + clip(nameOf(el), 80) + '"';
      if (tag === 'a') line += ' -> ' + clip(el.href, 120);
      if (tag === 'input' || tag === 'textarea') {
        if (el.type === 'checkbox' || el.type === 'radio') line += el.checked ? ' (checked)' : ' (unchecked)';
        else if (el.type === 'password') line += el.value ? ' value="***"' : '';
        else if (!['button', 'submit', 'reset', 'image'].includes(el.type) && el.value) {
          line += ' value="' + clip(clean(el.value), 60) + '"';
        }
      }
      if (tag === 'select') {
        const chosen = el.selectedOptions[0];
        line += ' value="' + clip(clean(chosen ? chosen.text : ''), 60) + '"';
        line += ' options=[' + Array.from(el.options).slice(0, 20).map(o => clean(o.text)).join(' | ') + ']';
      }
      if (el.disabled || el.getAttribute('aria-disabled') === 'true') line += ' (disabled)';
      lines.push(line);
    }
    window.__refs = refs;
    if (window === window.top) window.__frameRefs = [];
    const frames = childFrames().map(f => {
      let label = f.localName;
      if (f.id) label += '#' + f.id;
      const name = clean(f.getAttribute('title') || f.getAttribute('aria-label') || f.getAttribute('name'));
      if (name) label += ' "' + clip(name, 60) + '"';
      return label;
    });
    return { lines, count, skipped, frames };
    """

    /// 番号で指した要素を操作する。引数: `ref`（0なら今フォーカスのある要素）, `action`, `text`。
    /// 番号の要素が子フレームにあれば、そこへの道筋（`descend`）を返す。アプリはそのフレームで同じスクリプトを走らせ直す。
    static let act = childFrames + route + routeFocus + """
    const fail = message => JSON.stringify({ error: message });
    let el;
    if (ref > 0) {
      el = (window.__refs || [])[ref - 1];
      if (!el || !el.isConnected) return fail('番号 ' + ref + ' の要素が見つからない。snapshot を取り直すこと。');
    } else {
      el = document.activeElement || document.body;
    }
    const fire = (type, init) => el.dispatchEvent(new Event(type, Object.assign({ bubbles: true }, init)));

    if (action === 'click') {
      el.scrollIntoView({ block: 'center', inline: 'center' });
      if (el.focus) el.focus();
      el.click();
      return '{}';
    }

    if (action === 'fill') {
      el.scrollIntoView({ block: 'center', inline: 'center' });
      if (el.focus) el.focus();
      const tag = el.tagName.toLowerCase();
      if (tag === 'select') {
        const option = Array.from(el.options).find(o => o.value === text || o.text.trim() === text.trim());
        if (!option) return fail('選択肢 "' + text + '" がない。');
        el.value = option.value;
      } else if (tag === 'input' || tag === 'textarea') {
        // Reactなどが値の代入を横取りしているので、元の設定関数を直接呼ぶ。
        const proto = tag === 'input' ? HTMLInputElement.prototype : HTMLTextAreaElement.prototype;
        Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, text);
      } else if (el.isContentEditable) {
        el.textContent = text;
      } else {
        return fail('番号 ' + ref + ' は入力できる要素ではない。');
      }
      fire('input');
      fire('change');
      return '{}';
    }

    if (action === 'press') {
      const init = { key: text, code: text, bubbles: true, cancelable: true };
      const proceed = el.dispatchEvent(new KeyboardEvent('keydown', init));
      el.dispatchEvent(new KeyboardEvent('keyup', init));
      // 合成したキーイベントでは既定の動作が起きないので、Enterでの送信だけ補う。
      if (proceed && text === 'Enter' && el.form) {
        el.form.requestSubmit();
      }
      return '{}';
    }
    return fail('未知の操作: ' + action);
    """

    /// 本物の入力を渡す位置を測る。引数: `ref`（0なら `x`, `y` の位置をそのまま使う）, `x`, `y`。
    /// 位置（CSS の画素。表示している範囲の左上から）と、その位置で事象を受ける要素をJSONで返す。
    /// 番号の要素が子フレームにあれば、`act` と同じくそこへの道筋を返す。位置はそのフレームの表示している範囲から測る。
    static let locate = childFrames + route + """
    const fail = message => JSON.stringify({ error: message });
    const describe = el => {
      if (!el) return '(なにもない)';
      let text = el.localName;
      if (el.id) text += '#' + el.id;
      const words = (el.innerText || el.value || el.getAttribute('aria-label') || '').replace(/\\s+/g, ' ').trim();
      if (words) text += ' "' + (words.length > 40 ? words.slice(0, 39) + '…' : words) + '"';
      return text;
    };
    let px = x, py = y, el = null;
    if (ref > 0) {
      el = (window.__refs || [])[ref - 1];
      if (!el || !el.isConnected) return fail('番号 ' + ref + ' の要素が見つからない。snapshot を取り直すこと。');
      let r = el.getBoundingClientRect();
      const inside = r.left >= 0 && r.top >= 0 && r.right <= innerWidth && r.bottom <= innerHeight;
      if (!inside) {
        // ページの CSS が smooth にしていても、測る前に動き終えるよう instant にする。
        el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
        r = el.getBoundingClientRect();
      }
      if (!r.width || !r.height) return fail('番号 ' + ref + ' の要素は大きさがなく、押せない。');
      px = r.left + r.width / 2;
      py = r.top + r.height / 2;
    }
    if (px < 0 || py < 0 || px >= innerWidth || py >= innerHeight) {
      return fail('位置 ' + Math.round(px) + ',' + Math.round(py) + ' は表示している範囲（' + innerWidth + 'x' + innerHeight + '）の外。');
    }
    const hit = document.elementFromPoint(px, py);
    let target = describe(hit);
    // 番号の要素がほかの要素に覆われていれば、事象は手前の要素が受ける。
    if (el && hit && hit !== el && !el.contains(hit)) target = describe(el) + '（手前の ' + describe(hit) + ' が受ける）';
    return JSON.stringify({ x: px, y: py, target });
    """

    /// セレクタに合う要素を隠す。引数: `selector`。隠した数か、失敗の理由をJSONで返す。
    static let hide = """
    let found;
    try { found = document.querySelectorAll(selector); }
    catch { return JSON.stringify({ error: 'CSSセレクタとして読めない: ' + selector }); }
    if (!found.length) return JSON.stringify({ error: '合う要素がない: ' + selector });
    for (const el of found) el.style.setProperty('display', 'none', 'important');
    return JSON.stringify({ count: found.length });
    """

    /// 本文のテキスト。引数: `limit`（文字数の上限）。
    static let text = """
    const body = document.body ? document.body.innerText : '';
    return body.length > limit ? body.slice(0, limit) + '\\n… （以下省略。全' + body.length + '文字）' : body;
    """
}
