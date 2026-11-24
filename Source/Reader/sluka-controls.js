'use strict';

(() => {
  const tokenSelector = 'llr-w[data-w][data-s]';
  const cardSelector = '.panel[data-show]:not([data-card])';
  const gradesSelector = '.levels > button[data-set]';
  const definitionSelector = [
    '.body .reading-group:not(.rg-google) > ol > li',
    '.body .rg-dict .od-def',
    '.body .rg-dict .od-defs > li',
  ].join(', ');

  function text(element) {
    if (!element) return '';
    if (!element.children.length) return element.textContent.trim();
    const copy = element.cloneNode(true);
    copy.querySelectorAll('rt, rp, .variant, [aria-hidden="true"]').forEach(node => node.remove());
    return copy.textContent.trim();
  }

  function clip(value, limit) {
    return value.trim().slice(0, limit).replace(/[\uD800-\uDBFF]$/, '');
  }

  function visible(element) {
    return element.isConnected && element.getClientRects().length > 0 &&
      element.ownerDocument.defaultView.getComputedStyle(element).visibility === 'visible';
  }

  function valid(command) {
    if (!command || typeof command.id !== 'string' || !/^[a-zA-Z0-9-]{1,96}$/.test(command.id) ||
        !Number.isSafeInteger(command.textRevision) || command.textRevision < 0) return false;
    if (command.translatesPassage === true) {
      return command.grade === null && typeof command.surface === 'string' &&
        command.surface.length >= 2 && command.surface.length <= 1200;
    }
    return typeof command.surface === 'string' && command.surface.length > 0 && command.surface.length <= 64 &&
      typeof command.key === 'string' && command.key.length > 0 && command.key.length <= 128 &&
      Number.isInteger(command.expectedStatus) && command.expectedStatus >= 0 && command.expectedStatus <= 7 &&
      (command.grade === null || Number.isInteger(command.grade) && command.grade >= 0 && command.grade <= 6);
  }

  function target(article, command) {
    const sameSurface = Array.from(article.querySelectorAll(tokenSelector)).filter(element =>
      element.isConnected && text(element) === command.surface);
    if (!sameSurface.length) return { outcome: 'unavailable' };
    if (sameSurface.some(element => element.dataset.w !== command.key)) return { outcome: 'ambiguous' };
    const gradeable = !sameSurface.some(element => ['data-rd-grammar', 'data-split', 'data-cont', 'data-split-verb']
      .some(name => element.hasAttribute(name)));
    if (command.grade !== null && !gradeable) return { outcome: 'unavailable' };
    const statuses = new Set(sameSurface.map(element => element.dataset.s));
    if (statuses.size !== 1) return { outcome: 'ambiguous' };
    const status = sameSurface[0].dataset.s;
    if (!/^[0-7]$/.test(status)) return { outcome: 'unavailable' };
    return { element: sameSurface[0], status: Number(status), gradeable };
  }

  function openPanels(article, includePassage = false) {
    const selector = includePassage ? '.panel[data-show]' : cardSelector;
    return Array.from(article.ownerDocument.querySelectorAll('[data-llr-ui]'))
      .flatMap(host => Array.from(host.shadowRoot?.querySelectorAll(selector) ?? []))
      .filter(visible);
  }

  function closePinnedCaptureCard(article) {
    const pinned = openPanels(article).filter(panel => !panel.hasAttribute('data-preview'));
    if (pinned.length === 0) return true;
    if (pinned.length !== 1) return false;
    const panel = pinned[0];
    const selected = Array.from(article.ownerDocument.querySelectorAll(tokenSelector + '[data-llr-sel]'));
    if (!selected.length || selected.some(element => !article.contains(element))) return false;
    return closePanel(panel);
  }

  function closePanel(panel) {
    const editor = Array.from(panel.querySelectorAll('textarea, input, [contenteditable="true"]')).some(visible);
    const close = panel.querySelector('button[data-close]');
    if (editor || !close || !visible(close)) return false;
    close.click();
    return !panel.hasAttribute('data-show');
  }

  function currentCard(article, command, allowPreview) {
    const panels = openPanels(article);
    if (panels.length !== 1) return null;
    const panel = panels[0];
    const head = text(panel.querySelector('.word'));
    if (!head || head !== command.surface && head !== command.key) return null;
    if (panel.hasAttribute('data-preview')) return allowPreview ? panel : null;

    // Sluka marks all occurrences of the pinned canonical key. Refuse a panel
    // selected from outside the current capture or spanning different keys.
    const selected = Array.from(article.ownerDocument.querySelectorAll(tokenSelector + '[data-llr-sel]'));
    if (!selected.length || selected.some(element => !article.contains(element) || element.dataset.w !== command.key)) {
      return null;
    }
    return selected.some(element => text(element) === command.surface) ? panel : null;
  }

  function readCard(panel, { surface, key }, status) {
    const definitions = [];
    let remaining = 1500;
    for (const row of panel.querySelectorAll(definitionSelector)) {
      if (!visible(row)) continue;
      const value = clip(row.innerText, remaining);
      if (!value || definitions.includes(value)) continue;
      definitions.push(value);
      remaining -= value.length + 1;
      if (remaining <= 0) break;
    }
    const shownReading = selector => Array.from(panel.querySelectorAll(selector))
      .find(node => visible(node) && node.innerText.trim());
    const reading = shownReading('.reading') ?? shownReading('.rg-dict .od-reading');
    if (!reading && !definitions.length) return undefined;
    return { surface, key, reading: clip(reading?.innerText ?? '', 128), definition: definitions.join('\n'), status };
  }

  function gradeButton(panel, status, grade) {
    const active = Array.from(panel.querySelectorAll(gradesSelector + '[data-active]'));
    if (status >= 1 && status <= 6) {
      if (active.length !== 1 || Number(active[0].dataset.set) !== status) return { outcome: 'conflict' };
    } else if (active.length) return { outcome: 'conflict' };
    const buttons = grade === 0 ? active : Array.from(panel.querySelectorAll(gradesSelector))
      .filter(button => button.dataset.set === String(grade) && !button.hasAttribute('data-active'));
    if (buttons.length !== 1 || !buttons[0].isConnected || buttons[0].disabled ||
        !panel.hasAttribute('data-preview') && !visible(buttons[0])) return { outcome: 'unavailable' };
    return { button: buttons[0] };
  }

  function createSlukaControls({ article, isCurrent, authorize }) {
    const commands = new Map();
    let pending = false;
    let nextPoll = null;
    let openedCard = null;
    let userInput = 0;
    const pause = () => new Promise(resolve => {
      const done = () => {
        nextPoll = null;
        resolve();
      };
      const timer = setTimeout(done, 50);
      nextPoll = () => { clearTimeout(timer); done(); };
    });
    const checkCurrent = command => !article.hidden && isCurrent(command.textRevision);

    function prepareForCaptureChange() {
      const previous = openedCard;
      openedCard = null;
      // Check ownership while Sluka's selected tokens still belong to the
      // outgoing capture. After replacement their selection markers are gone.
      if (previous && currentCard(article, previous.command, false) === previous.panel) {
        closePanel(previous.panel);
      }
    }

    // Sluka's desktop selection handler looks up a span on mouseup.
    async function translatePassage(command) {
      const normalize = value => value.normalize().trim().replace(/\s+/gu, ' ');
      // Sluka constructs a selection card from the first and last annotated
      // words, so sentence punctuation after the last word can be absent.
      const matchText = value => normalize(value).replace(/[\p{Sentence_Terminal}…]+$/u, '').trimEnd();
      const expected = matchText(command.surface);
      const inputAtStart = userInput;
      const isCurrentPassage = () => checkCurrent(command) && userInput === inputAtStart;
      const deadline = Date.now() + 12500;
      const paragraph = article.children.length === 1 ? article.firstElementChild : null;
      if (!paragraph || normalize(text(paragraph)) !== normalize(command.surface)) return { outcome: 'unavailable' };

      let words;
      do {
        if (!isCurrentPassage()) return { outcome: 'stale' };
        words = paragraph.querySelectorAll(tokenSelector);
        if (words.length >= 2) break;
        await pause();
      } while (Date.now() < deadline);
      const doc = article.ownerDocument;
      const selection = doc.getSelection();
      if (words.length < 2 || !selection?.isCollapsed || !closePinnedCaptureCard(article)) {
        return { outcome: 'unavailable' };
      }
      const range = doc.createRange();
      range.selectNodeContents(paragraph);
      const priorPanels = openPanels(article, true);
      const priorSources = new Set(priorPanels.flatMap(panel =>
        Array.from(panel.querySelectorAll('.card-from, .word'))));
      const priorTranslationCard = priorPanels.some(panel => panel.hasAttribute('data-card'));
      selection.removeAllRanges();
      selection.addRange(range);
      const hasOwnSelection = () => selection.rangeCount && selection.getRangeAt(0) === range;
      const ownsPanel = panel => {
        const source = panel.querySelector('.card-from') ?? panel.querySelector('.word');
        if (source) return !priorSources.has(source) && matchText(text(source)) === expected;

        // The desktop translation-only card can omit a source label. Bind it
        // to the range we just selected and require full annotated coverage.
        if (!panel.hasAttribute('data-card') || priorTranslationCard || !hasOwnSelection()) return false;
        const span = doc.createRange();
        span.setStartBefore(words[0]);
        span.setEndAfter(words[words.length - 1]);
        return matchText(text(span.cloneContents())) === expected;
      };
      let owned = null;
      let clicked = false;
      try {
        words[words.length - 1].dispatchEvent(new MouseEvent('mouseup', { bubbles: true, composed: true, button: 0 }));
        do {
          if (!isCurrentPassage()) return { outcome: 'stale' };
          const panels = openPanels(article, true).filter(panel => !panel.hasAttribute('data-preview'));
          if (panels.length === 1) {
            const panel = panels[0];
            if (ownsPanel(panel)) {
              owned = panel;
              const result = Array.from(panel.querySelectorAll('.card-text, .rg-google li, .rg-google .rg-line, .cmp-gtext'))
                .find(node => visible(node) && node.innerText.trim());
              if (result) return { outcome: 'translated', translation: clip(result.innerText, 4000) };
              const pendingTranslation = panel.querySelector('.rg-google, .card-status, .cmp-status');
              const trigger = panel.querySelector('button[data-card-tr], button[data-translate]');
              if (!clicked && !pendingTranslation && trigger && visible(trigger) && !trigger.disabled) {
                clicked = true;
                trigger.click();
              }
            }
          }
          await pause();
        } while (Date.now() < deadline);
        return { outcome: 'unavailable' };
      } finally {
        if (userInput === inputAtStart) {
          if (owned && isCurrentPassage() && openPanels(article, true).includes(owned) && ownsPanel(owned)) {
            closePanel(owned);
          }
          if (hasOwnSelection()) selection.removeAllRanges();
        }
      }
    }

    async function confirmGrade(command, lookup) {
      const deadline = Date.now() + 2500;
      do {
        if (!checkCurrent(command)) return { outcome: 'unconfirmed' };
        const after = target(article, command);
        if (after.status === command.grade) {
          return { outcome: 'applied', status: after.status, lookup: lookup && { ...lookup, status: after.status } };
        }
        await pause();
      } while (Date.now() < deadline);
      return { outcome: 'unconfirmed' };
    }

    async function perform(command) {
      if (!checkCurrent(command)) return { outcome: 'stale' };
      let match = target(article, command);
      if (!match.element) return match;
      if (match.status !== command.expectedStatus) return { outcome: 'conflict', status: match.status };

      let panel = currentCard(article, command, false);
      if (command.grade === match.status) {
        return { outcome: 'unchanged', status: match.status, lookup: panel ? readCard(panel, command, match.status) : undefined };
      }

      const allowPreview = match.status <= 4;
      if (!panel) {
        // Split and grammar tokens may open a different entry when clicked.
        // Read an existing exact card, or use the preview without a click.
        if (!allowPreview && !match.gradeable) return { outcome: 'unavailable' };
        const openingToken = match.element;
        const oldHead = currentCard(article, command, true)?.querySelector('.word');
        if (!closePinnedCaptureCard(article)) return { outcome: 'unavailable' };
        if (allowPreview) {
          // Sluka's hover preview reads the dictionary without enrolling a
          // New word or requesting a translation.
          openingToken.dispatchEvent(new MouseEvent('mouseover', { bubbles: true, composed: true }));
        } else {
          // Sluka suppresses previews for Known, Ignored and other-script
          // Known words. Its normal lookup opens their word card.
          openingToken.click();
        }
        const deadline = Date.now() + 2500;
        do {
          if (!checkCurrent(command)) return { outcome: 'stale' };
          if (!openingToken.isConnected || !article.contains(openingToken)) return { outcome: 'conflict' };
          panel = currentCard(article, command, allowPreview);
          // Sluka replaces the card's contents on each lookup. A preexisting
          // preview with identical spelling is not proof this hover opened it.
          const heading = panel?.querySelector('.word');
          if (heading && heading !== oldHead) {
            if (!allowPreview) openedCard = {command, panel};
            break;
          }
          panel = null;
          await pause();
        } while (Date.now() < deadline);
      }
      if (!checkCurrent(command)) return { outcome: 'stale' };
      if (!panel) return { outcome: 'unavailable' };
      match = target(article, command);
      if (!match.element) return match;
      if (match.status !== command.expectedStatus) return { outcome: 'conflict', status: match.status };
      if (panel !== currentCard(article, command, allowPreview)) return { outcome: 'conflict' };
      const lookup = readCard(panel, command, match.status);
      if (command.grade === null) {
        let result = lookup;
        const deadline = Date.now() + 1700;
        while (!result?.definition && Date.now() < deadline) {
          await pause();
          if (!checkCurrent(command)) return { outcome: 'stale' };
          if (panel !== currentCard(article, command, allowPreview)) return { outcome: 'unavailable' };
          const latest = target(article, command);
          if (latest.status !== match.status) return { outcome: 'conflict', status: latest.status };
          result = readCard(panel, command, match.status);
        }
        return result
          ? { outcome: 'lookup', status: match.status, lookup: result }
          : { outcome: 'noDefinition', status: match.status };
      }

      // Sluka toggles the currently lit button back to New. Use that only
      // for an explicit reset. Other writes use the unique unlit button.
      const candidate = gradeButton(panel, match.status, command.grade);
      if (!candidate.button) return candidate;
      if (!authorize || !await authorize(command) || !checkCurrent(command)) return { outcome: 'stale' };

      // Authorization is asynchronous. Re-check the page and get the current
      // button in case Sluka repainted its card while the request was in flight.
      match = target(article, command);
      if (!match.element) return match;
      if (match.status !== command.expectedStatus) return { outcome: 'conflict', status: match.status };
      if (panel !== currentCard(article, command, allowPreview)) return { outcome: 'conflict' };
      const ready = gradeButton(panel, match.status, command.grade);
      if (!ready.button) return ready;
      if (ready.button !== candidate.button) return { outcome: 'conflict' };

      // Preview CSS hides these controls. They are Sluka's real grade
      // controls, and are present only when its grade UI is available.
      ready.button.click();
      return confirmGrade(command, lookup);
    }

    return {
      prepareForCaptureChange,
      releaseOpenedCard() { openedCard = null; userInput++; },
      refresh() { nextPoll?.(); },
      execute(command) {
        if (!valid(command)) return Promise.resolve({ outcome: 'invalid' });
        if (commands.has(command.id)) return commands.get(command.id);
        if (pending) return Promise.resolve({ outcome: 'busy' });
        pending = true;
        const operation = (command.translatesPassage === true ? translatePassage : perform)({ ...command })
          .catch(() => ({ outcome: 'unconfirmed' }))
          .finally(() => { pending = false; });
        commands.set(command.id, operation);
        if (commands.size > 64) commands.delete(commands.keys().next().value);
        return operation;
      },
    };
  }

  globalThis.createSlukaControls = createSlukaControls;
})();
