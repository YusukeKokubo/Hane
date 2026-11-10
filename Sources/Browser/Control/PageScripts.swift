/// ページの中で走らせるJavaScript。いずれも関数本体で、文字列を返す。
///
/// `snapshot` が要素に番号を振って控え、`act` がその番号で要素を操作する。
/// 控えはページのスクリプトから見えない専用の実行環境に置く。
enum PageScripts {
    /// 操作できる要素と見出しを、番号つきの一覧にする。引数: `limit`。
    static let snapshot = """
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

    const refs = [];
    const lines = [];
    let skipped = 0;
    for (const el of document.querySelectorAll(selector)) {
      if (!visible(el)) continue;
      const tag = el.tagName.toLowerCase();
      if (/^h[1-3]$/.test(tag)) {
        const heading = clean(el.innerText);
        if (heading && refs.length < limit) lines.push('#'.repeat(Number(tag[1])) + ' ' + clip(heading, 100));
        continue;
      }
      if (tag === 'input' && el.type === 'hidden') continue;
      if (refs.length >= limit) { skipped++; continue; }

      refs.push(el);
      let line = '[' + refs.length + '] ' + roleOf(el) + ' "' + clip(nameOf(el), 80) + '"';
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
    if (skipped) lines.push('… ほか ' + skipped + ' 個の要素を省略（snapshot --limit <数> で増やせる）');
    if (!refs.length) lines.push('（操作できる要素は見つからなかった）');
    return lines.join('\\n');
    """

    /// 番号で指した要素を操作する。引数: `ref`（0なら今フォーカスのある要素）, `action`, `text`。
    static let act = """
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

    /// いま画面に見えている範囲を、ページ内の座標で返す。
    static let viewport = """
    return JSON.stringify({ x: window.scrollX, y: window.scrollY, width: window.innerWidth, height: window.innerHeight });
    """

    /// 本文のテキスト。引数: `limit`（文字数の上限）。
    static let text = """
    const body = document.body ? document.body.innerText : '';
    return body.length > limit ? body.slice(0, limit) + '\\n… （以下省略。全' + body.length + '文字）' : body;
    """
}
