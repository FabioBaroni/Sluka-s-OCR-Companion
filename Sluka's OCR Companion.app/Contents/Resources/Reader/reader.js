'use strict';

const article = document.querySelector('#text');
const status = document.querySelector('#status');
const fragment = new URLSearchParams(location.hash.slice(1));
const previous = history.state?.ocrCompanion;
const session = fragment.get('session') ?? previous?.session;
const suffix = fragment.get('title') ?? previous?.suffix;
const mode = fragment.get('mode') ?? previous?.mode;
if (/^[a-f0-9]{64}$/.test(session || '') && /^[a-f0-9]{12}$/.test(suffix || '') && mode === 'compact') {
  if (location.hash) history.replaceState({ocrCompanion: {session, suffix, mode}}, '', '/');
  document.title = 'OCR Companion • Sluka ' + suffix;
  connect();
}

function connect() {
  // A reload inherits the launch capability but always obtains a new document identity.
  const readerID = crypto.randomUUID();
  const observer = createSlukaObserver({article, session, readerID});
  const headers = {'X-OCRCompanion-Session': session, 'X-OCRCompanion-Reader': readerID};
  let joining = true;
  let latest = null;
  let revision = null;
  let command = null;
  let unannotatedSince = 0;
  let refreshed = false;
  let connected = false;
  const controls = createSlukaControls({
    article,
    isCurrent,
    async authorize(offer) {
      if (!isCurrent(offer.textRevision)) return false;
      return (await post('/sluka-commit', {id: offer.id, textRevision: offer.textRevision})).ok;
    }
  });

  function isCurrent(value) {
    return connected && revision === value && command?.textRevision === value && command.expiresAt > Date.now();
  }

  function post(path, payload) {
    return fetch(path, {
      method: 'POST',
      headers: {...headers, 'Content-Type': 'application/json'},
      body: JSON.stringify(payload),
      cache: 'no-store', credentials: 'omit', mode: 'same-origin', redirect: 'error',
      referrer: '', referrerPolicy: 'same-origin', signal: AbortSignal.timeout(4000),
    });
  }

  async function execute(offer) {
    if (command || !offer || typeof offer.id !== 'string' ||
        !Number.isSafeInteger(offer.textRevision) || !Number.isSafeInteger(offer.expiresAt)) return;
    command = {...offer, grade: offer.grade ?? null};
    try {
      let outcome;
      try {
        outcome = await controls.execute(command);
      } catch {
        outcome = {outcome: 'unconfirmed'};
      }
      await post('/sluka-result', {id: offer.id, textRevision: offer.textRevision, ...outcome});
    } catch {
      // Sluka might have applied the grade. Never replay one after losing its acknowledgment.
    } finally {
      command = null;
    }
  }

  function render(data) {
    if (data.text !== latest?.text || data.language !== latest?.language) {
      controls.prepareForCaptureChange();
      article.replaceChildren();
      for (const line of data.text.split('\n').filter(line => line.trim())) {
        const paragraph = document.createElement('p');
        paragraph.textContent = line;
        article.append(paragraph);
      }
      article.lang = data.language;
      document.documentElement.lang = data.language;
      article.hidden = !article.children.length;
    }
    latest = data;
    if (data.textRevision === revision) return;
    revision = data.textRevision;
    unannotatedSince = Date.now();
    if (article.hidden) observer.clear();
    else {
      observer.observe(revision, data.text, data.pointerOffset);
    }
  }

  function refreshUnannotated(data) {
    if (article.querySelector('llr-w[data-w][data-s]')) {
      refreshed = false;
      unannotatedSince = Date.now();
      return false;
    }
    if (refreshed || command || data.command || !data.refreshIfUnannotated ||
        !data.text.trim() || data.text.length > 64 || Date.now() - unannotatedSince < 1600) return false;
    // Give Sluka's initial scan the focused word in the document. Consume
    // the seed on arrival and wait for /state before publishing annotations.
    history.replaceState({ocrCompanion: {session, suffix, mode, seed: {
      text: data.text, language: data.language, expiresAt: Date.now() + 15000,
    }}}, '', '/');
    refreshed = true;
    location.reload();
    return true;
  }

  if (previous?.seed && !location.hash) {
    const seed = previous.seed;
    history.replaceState({ocrCompanion: {session, suffix, mode}}, '', '/');
    refreshed = true;
    if (seed.expiresAt > Date.now() && typeof seed.text === 'string' && seed.text.length <= 64 &&
        /^[a-zA-Z0-9-]{1,24}$/.test(seed.language)) {
      render({...seed, textRevision: null});
    }
  }

  function say(message) {
    if (status.getAttribute('aria-label') !== message) status.setAttribute('aria-label', message);
  }

  async function poll() {
    let expired = false;
    try {
      const response = await fetch('/state', {
        headers: {...headers, 'X-OCRCompanion-View': 'compact',
          ...(joining ? {'X-OCRCompanion-Join': '1'} : {}),
          ...(document.hidden && revision !== null ? {'X-OCRCompanion-Wait': String(revision)} : {}),
          ...(connected && revision !== null && !command ? {'X-OCRCompanion-Controls': 'ready'} : {})},
        cache: 'no-store', credentials: 'omit', signal: AbortSignal.timeout(5000),
      });
      expired = [403, 409].includes(response.status);
      if (!response.ok) throw new Error();
      const data = await response.json();
      if (!Number.isSafeInteger(data.textRevision) || typeof data.text !== 'string' ||
          data.text.length > 700000 || typeof data.language !== 'string') throw new Error();
      joining = false;
      connected = true;
      say(data.text ? 'Leave this tab open to use Sluka from the Mac panel.' : 'Waiting for a lookup in OCR Companion…');
      render(data);
      if (refreshUnannotated(data)) return;
      observer.refresh();
      controls.refresh();
      if (data.command) void execute(data.command);
      // While hidden, the server paces the next request instead of a Chrome timer.
      if (document.hidden) { void poll(); return; }
    } catch {
      connected = false;
      if (revision !== null) observer.clear();
      revision = null;
      if (expired) { article.replaceChildren(); article.hidden = true; }
      say(expired ? 'Session ended. Reconnect Sluka from the Mac app.' : 'Waiting for OCR Companion…');
    }
    if (!expired) setTimeout(poll, 750);
  }

  window.addEventListener('pageshow', event => { if (event.persisted) location.reload(); });
  const releaseOnUserInput = event => { if (event.isTrusted) controls.releaseOpenedCard(); };
  window.addEventListener('click', releaseOnUserInput, true);
  window.addEventListener('keydown', releaseOnUserInput, true);
  window.addEventListener('pagehide', () => {
    void fetch('/sluka-disconnect', {
      method: 'POST', headers: {...headers, 'Content-Type': 'application/json'},
      body: '{}', credentials: 'omit', keepalive: true, referrerPolicy: 'same-origin',
    }).catch(() => {});
  });
  void poll();
}
