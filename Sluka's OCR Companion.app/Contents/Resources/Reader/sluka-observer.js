'use strict';

(() => {
  const wordSelector = 'llr-w[data-w][data-s]';
  const selectedSelector = wordSelector + '[data-llr-sel]';
  const definitionSelector = [
    '.body .reading-group:not(.rg-google) > ol > li',
    '.body .rg-dict .od-def',
    '.body .rg-dict .od-defs > li',
  ].join(', ');
  const maxWords = 64;
  const maxBodyBytes = 18 * 1024;
  const interval = 1000;

  function clipped(value, length) {
    return value.trim().slice(0, length).replace(/[\uD800-\uDBFF]$/, '');
  }

  function readingText(node) {
    if (!node) return '';
    if (!node.children.length) return node.textContent;
    const copy = node.cloneNode(true);
    copy.querySelectorAll('rt, rp, .variant, [aria-hidden="true"]').forEach(child => child.remove());
    return copy.textContent;
  }

  function sourceText(element) { return readingText(element).trim(); }

  // The reader renders one paragraph per nonblank source line. Require the
  // annotated text to reconstruct the original line exactly before using offsets.
  function wordAtPointer(article, text, pointerOffset, words) {
    if (!Number.isSafeInteger(pointerOffset) || pointerOffset < 0 || pointerOffset >= text.length) return null;
    let start = 0;
    let row = 0;
    for (const line of text.split('\n')) {
      const end = start + line.length;
      if (line.trim()) {
        const paragraph = article.children[row++];
        if (pointerOffset < end) {
          if (paragraph?.tagName !== 'P' || readingText(paragraph) !== line) return null;
          const before = article.ownerDocument.createRange();
          before.selectNodeContents(paragraph);
          for (const element of paragraph.querySelectorAll(wordSelector)) {
            const surface = sourceText(element);
            if (!words.get(surface)) continue;
            before.setEndBefore(element);
            const prefix = readingText(before.cloneContents());
            const wordStart = start + prefix.length + readingText(element).indexOf(surface);
            if (wordStart <= pointerOffset && pointerOffset < wordStart + surface.length &&
                text.slice(wordStart, wordStart + surface.length) === surface) {
              return { surface, start: wordStart };
            }
          }
          return null;
        }
      }
      start = end + 1;
    }
    return null;
  }

  function wordData(element, surface) {
    const { w: key, s, rdGrammar, split, cont, splitVerb } = element.dataset;
    if (!surface || surface.length > 64 || !key?.trim() || key.length > 128 || !/^[0-7]$/.test(s)) return null;
    // Sluka uses the same tag for grammar hints and parts whose click may
    // open a different word. They are useful to read but unsafe to grade.
    const gradeable = [rdGrammar, split, cont, splitVerb].every(value => value === undefined);
    return { surface, key, status: Number(s), gradeable };
  }

  function isVisible(element) {
    if (!element || !element.getClientRects().length) return false;
    return element.ownerDocument.defaultView.getComputedStyle(element).visibility === 'visible';
  }

  function readLookup(article, shadow) {
    // Sluka sets this marker when its own word card is opened. A plain
    // hover, a translation card and Sluka UI outside the capture do not match.
    const panel = shadow.querySelector('.panel[data-show]:not([data-preview]):not([data-card])');
    if (!isVisible(panel)) return null;
    const headword = sourceText(panel.querySelector('.word'));
    if (!headword) return null;

    const selected = Array.from(article.querySelectorAll(selectedSelector), element => wordData(element, sourceText(element)));
    const key = selected[0]?.key;
    if (!key || selected.some(word => word?.key !== key)) return null;
    const word = selected.find(word => word.surface === headword) ??
      (key === headword ? selected[0] : null);
    if (!word) return null;

    const definitions = [];
    let length = 0;
    for (const line of panel.querySelectorAll(definitionSelector)) {
      if (!isVisible(line)) continue;
      const value = clipped(line.innerText, 1500 - length);
      if (!value || definitions.includes(value)) continue;
      definitions.push(value);
      length += value.length + 1;
      if (length >= 1500) break;
    }
    if (!definitions.length) return null;

    const shownReading = selector => Array.from(panel.querySelectorAll(selector))
      .find(node => isVisible(node) && node.innerText.trim());
    const reading = shownReading('.reading') ?? shownReading('.rg-dict .od-reading');
    const status = selected.every(item => item.status === word.status) ? word.status : null;
    return {
      surface: word.surface,
      key,
      reading: clipped(reading?.innerText ?? '', 128),
      definition: definitions.join('\n'),
      status,
      gradeable: status !== null && selected.every(item => item.gradeable),
    };
  }

  function snapshot(article, textRevision, text, pointerOffset) {
    if (article.hidden) return null;
    const shadow = article.ownerDocument.querySelector('[data-llr-ui]')?.shadowRoot;
    const card = shadow ? readLookup(article, shadow) : null;
    const words = new Map();
    const ambiguous = new Set();
    for (const element of article.querySelectorAll(wordSelector)) {
      const surface = sourceText(element);
      if (!surface || surface.length > 64) continue;
      const word = wordData(element, surface);
      if (!words.has(surface)) {
        if (words.size < maxWords || surface === card?.surface) words.set(surface, word);
        continue;
      }
      const previous = words.get(surface);
      // Different canonical words can have the same spelling and even the
      // same current grade. An invalid key also makes the surface ambiguous.
      if (!word || !previous || previous.key !== word.key || previous.status !== word.status) {
        words.set(surface, null);
        ambiguous.add(surface);
      } else {
        previous.gradeable &&= word.gradeable;
      }
    }
    const identity = words.get(card?.surface);
    const lookup = card && identity?.key === card.key
      ? { ...card, gradeable: card.gradeable && identity.gradeable } : null;
    const unique = Array.from(words.values()).filter(Boolean).slice(0, maxWords);
    if (lookup && identity && !unique.includes(identity)) {
      if (unique.length === maxWords) unique.pop();
      unique.push(identity);
    }
    const ambiguousSurfaces = Array.from(ambiguous).slice(0, maxWords);
    const pointerWord = wordAtPointer(article, text, pointerOffset, words);
    const positioned = pointerWord && unique.some(word => word.surface === pointerWord.surface) ? {pointerWord} : {};
    return unique.length || lookup || ambiguousSurfaces.length
      ? { textRevision, words: unique, lookup, ...positioned, ...(ambiguousSurfaces.length ? {ambiguousSurfaces} : {}) }
      : null;
  }

  function bodyFor(report) {
    const encoder = new TextEncoder();
    let body = JSON.stringify(report);
    while (encoder.encode(body).length > maxBodyBytes && report.words.length) {
      if (report.words.pop()?.surface === report.pointerWord?.surface) delete report.pointerWord;
      body = JSON.stringify(report);
    }
    return body;
  }

  function createSlukaObserver({ article, session, readerID }) {
    let revision = null;
    let publishedRevision = null;
    let text = '';
    let pointerOffset = null;
    let lastBody = '';
    let sendAfter = 0;
    let timer = null;
    let sending = false;

    function schedule() {
      if (timer !== null || sending || (revision === null && publishedRevision === null)) return;
      timer = setTimeout(tick, Math.max(0, sendAfter - Date.now()));
    }

    async function tick() {
      timer = null;
      sendAfter = Date.now() + interval;
      const current = revision === null ? null : snapshot(article, revision, text, pointerOffset);
      const report = current ?? (publishedRevision === null ? null : {
        textRevision: publishedRevision, words: [], lookup: null,
      });
      if (!report) {
        schedule();
        return;
      }

      const body = bodyFor(report);
      if (body !== lastBody) {
        sending = true;
        try {
          const response = await fetch('/sluka', {
            method: 'POST',
            headers: {
              'Content-Type': 'application/json',
              'X-OCRCompanion-Session': session,
              ...(readerID ? {'X-OCRCompanion-Reader': readerID} : {}),
            },
            credentials: 'omit',
            cache: 'no-store',
            mode: 'same-origin',
            redirect: 'error',
            // Keep the Origin header on this local POST without sending Referer.
            referrer: '',
            referrerPolicy: 'same-origin',
            body,
            signal: AbortSignal.timeout(4000),
          });
          if (response.ok) {
            lastBody = body;
            publishedRevision = current ? current.textRevision : null;
          } else if (!current && [403, 404, 409].includes(response.status)) {
            // The browser session ended or the native app already replaced this capture.
            lastBody = '';
            publishedRevision = null;
          }
        } catch {
          // Keep the reader usable when the native app goes away.
        } finally {
          sending = false;
        }
      }
      schedule();
    }

    return {
      observe(textRevision, source = '', offset = null) {
        if (!Number.isSafeInteger(textRevision) || textRevision < 0) return;
        if (revision !== textRevision) {
          revision = textRevision;
          text = source;
          pointerOffset = offset;
          if (publishedRevision !== textRevision) publishedRevision = null;
        }
        schedule();
      },
      refresh() {
        if (sending || revision === null || Date.now() < sendAfter) return;
        if (timer !== null) clearTimeout(timer);
        void tick();
      },
      clear() {
        revision = null;
        if (timer !== null) {
          clearTimeout(timer);
          timer = null;
        }
        schedule();
      },
    };
  }

  globalThis.createSlukaObserver = createSlukaObserver;
})();
