/* Minimal, safe Markdown renderer for iThoughts topic text and notes.
 *
 * Everything is HTML-escaped first; only a whitelist of inline tags that
 * iThoughts itself emits (<u> <del> <mark> <sup> <sub> <br>) is re-enabled.
 * URLs are restricted to http(s)/mailto/relative/data:image.
 * Supported: # headings, paragraphs, line breaks, * - + and 1. lists
 * (nested by indentation), > quotes, ``` code, `code`, **bold**, *em*,
 * _em_, ~~strike~~, [text](url), [text][ref], ![alt](src), ![][ref],
 * <http://autolinks>, bare http(s) URLs, --- rules.
 *
 *   ItmzMarkdown.render(src, { resolve: url => url })   -> HTML string
 */
(function (global) {
  'use strict';
  const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
  const esc = s => String(s).replace(/[&<>"']/g, c => ESC[c]);
  const ALLOWED_TAGS = /&lt;(\/?)(u|del|mark|sup|sub|s|strike|br\s*\/?)&gt;/gi;

  function safeUrl(u) {
    u = String(u || '').trim();
    if (/^(https?:|mailto:|#)/i.test(u)) return u;
    if (/^data:image\/(png|jpe?g|gif|webp);/i.test(u)) return u;
    if (/^[a-z][a-z0-9+.-]*:/i.test(u)) return null;          // javascript:, file: ...
    return u;                                                 // relative
  }

  function inline(src, ctx) {
    const codes = [];
    let s = esc(src).replace(/`([^`]+)`/g, (_, c) => { codes.push(c); return `\u0000${codes.length - 1}\u0000`; });
    const link = (text, url, isImg) => {
      const raw = ctx.resolve ? ctx.resolve(url) : url;
      const u = safeUrl(raw);
      if (u == null) return text;
      const href = esc(u).replace(/&amp;(?=[#\w]+;)/g, '&');
      if (isImg) return `<img src="${href}" alt="${text}" loading="lazy">`;
      return `<a href="${href}" target="_blank" rel="noopener noreferrer">${text || href}</a>`;
    };
    const unesc = t => t.replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>');
    // images & links (inline and reference style)
    s = s.replace(/!\[([^\]]*)\]\(([^)\s]+)(?:\s+&quot;[^&]*&quot;)?\)/g, (_, a, u) => link(a, unesc(u), true));
    s = s.replace(/!\[([^\]]*)\]\[([^\]]*)\]/g, (m, a, r) => { const u = ctx.refs[(r || a).toLowerCase()]; return u ? link(a, u, true) : m; });
    s = s.replace(/\[([^\]]+)\]\(([^)\s]+)(?:\s+&quot;[^&]*&quot;)?\)/g, (_, t, u) => link(t, unesc(u)));
    s = s.replace(/\[([^\]]+)\]\[([^\]]*)\]/g, (m, t, r) => { const u = ctx.refs[(r || t).toLowerCase()]; return u ? link(t, u) : m; });
    s = s.replace(/&lt;((?:https?:\/\/|mailto:)[^\s&]+)&gt;/g, (_, u) => link(u, unesc(u)));
    s = s.replace(/(^|[\s(])(https?:\/\/[^\s<"]+[^\s<".,;:!?)])/g, (m, p, u) => p + link(u, unesc(u)));
    // emphasis
    s = s.replace(/\*\*(?=\S)([\s\S]*?\S)\*\*/g, '<strong>$1</strong>')
         .replace(/__(?=\S)([\s\S]*?\S)__/g, '<strong>$1</strong>')
         .replace(/(^|[^*\w])\*(?=\S)([^*]*?\S)\*(?!\*)/g, '$1<em>$2</em>')
         .replace(/(^|[^_\w])_(?=\S)([^_]*?\S)_(?![_\w])/g, '$1<em>$2</em>')
         .replace(/~~(?=\S)([\s\S]*?\S)~~/g, '<del>$1</del>');
    s = s.replace(ALLOWED_TAGS, (_, slash, tag) => /^br/i.test(tag) ? '<br>' : `<${slash}${tag.toLowerCase()}>`);
    return s.replace(/\u0000(\d+)\u0000/g, (_, i) => `<code>${codes[+i]}</code>`);
  }

  const LIST_RE = /^(\s*)([*+-]|\d+[.)])\s+(.*)$/;
  const indentOf = l => l.replace(/\t/g, '    ').match(/^ */)[0].length;

  function blocks(lines, ctx) {
    const out = [];
    let i = 0;
    const isBlank = l => !l.trim();
    const startsBlock = l => /^\s{0,3}(#{1,6}\s|>|```|([-*_])(\s*\2){2,}\s*$)/.test(l) || LIST_RE.test(l);
    while (i < lines.length) {
      const line = lines[i];
      if (isBlank(line)) { i++; continue; }
      let m;
      if ((m = line.match(/^\s{0,3}```/))) {                 // fenced code
        const buf = []; i++;
        while (i < lines.length && !/^\s{0,3}```/.test(lines[i])) buf.push(lines[i++]);
        i++;
        out.push(`<pre><code>${esc(buf.join('\n'))}</code></pre>`);
      } else if ((m = line.match(/^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$/))) {
        const n = m[1].length; out.push(`<h${n}>${inline(m[2], ctx)}</h${n}>`); i++;
      } else if (/^\s{0,3}([-*_])(\s*\1){2,}\s*$/.test(line)) {
        out.push('<hr>'); i++;
      } else if (/^\s{0,3}>/.test(line)) {
        const buf = [];
        while (i < lines.length && /^\s{0,3}>/.test(lines[i])) buf.push(lines[i++].replace(/^\s{0,3}>\s?/, ''));
        out.push(`<blockquote>${blocks(buf, ctx)}</blockquote>`);
      } else if (LIST_RE.test(line)) {
        const base = indentOf(line), buf = [];
        while (i < lines.length) {
          const l = lines[i];
          if (isBlank(l)) {                                  // blank: continue only if list goes on
            const nx = lines.slice(i + 1).find(x => !isBlank(x));
            if (nx !== undefined && (indentOf(nx) > base || (LIST_RE.test(nx) && indentOf(nx) >= base))) { buf.push(''); i++; continue; }
            break;
          }
          if (indentOf(l) < base && !LIST_RE.test(l)) break;
          if (indentOf(l) < base) break;
          if (indentOf(l) === base && !LIST_RE.test(l) && buf.length && startsBlock(l)) break;
          buf.push(l); i++;
        }
        out.push(list(buf, base, ctx));
      } else {
        const buf = [];
        while (i < lines.length && !isBlank(lines[i]) && !(buf.length && startsBlock(lines[i]))) buf.push(lines[i++].trim());
        out.push(`<p>${buf.map(l => inline(l, ctx)).join('<br>')}</p>`);
      }
    }
    return out.join('');
  }

  function list(lines, base, ctx) {
    const first = lines[0].match(LIST_RE);
    const ordered = /\d/.test(first[2]);
    const items = [];
    for (const l of lines) {
      const m = l.match(LIST_RE);
      if (m && indentOf(l) === base) items.push([m[3]]);
      else if (items.length) items[items.length - 1].push(l.slice(Math.min(indentOf(l), base + 2)).replace(/^\s{0,2}/, ''));
    }
    const lis = items.map(([head, ...rest]) => {
      const sub = rest.length ? blocks(rest, ctx) : '';
      return `<li>${inline(head, ctx)}${sub}</li>`;
    });
    return ordered ? `<ol>${lis.join('')}</ol>` : `<ul>${lis.join('')}</ul>`;
  }

  function render(src, opts) {
    const ctx = { refs: {}, resolve: (opts && opts.resolve) || null };
    const lines = String(src || '').replace(/\r\n?/g, '\n').split('\n').filter(l => {
      const m = l.match(/^\s{0,3}\[([^\]]+)\]:\s*(\S+)\s*(?:["'(].*)?$/);
      if (m) { ctx.refs[m[1].toLowerCase()] = m[2]; return false; }
      return true;
    });
    return blocks(lines, ctx);
  }

  /** Plain text (for search, tooltips, measuring) */
  function plain(src) {
    return String(src || '')
      .replace(/^\s*\[[^\]]+\]:.*$/gm, '')
      .replace(/!\[[^\]]*\]\[[^\]]*\]|!\[[^\]]*\]\([^)]*\)/g, '')
      .replace(/\[([^\]]+)\]\([^)]*\)|\[([^\]]+)\]\[[^\]]*\]/g, '$1$2')
      .replace(/<\/?(u|del|mark|sup|sub|s|br)\s*\/?>/gi, '')
      .replace(/^\s{0,3}#{1,6}\s+/gm, '').replace(/^\s*([*+-]|\d+[.)])\s+/gm, '• ')
      .replace(/(\*\*|__|~~|`)/g, '').trim();
  }

  global.ItmzMarkdown = { render, plain, safeUrl };
})(typeof window !== 'undefined' ? window : globalThis);
