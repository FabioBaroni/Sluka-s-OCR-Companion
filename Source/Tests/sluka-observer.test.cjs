'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const code = fs.readFileSync(path.join(__dirname, '../Reader/sluka-observer.js'), 'utf8');
const wordSelector = 'llr-w[data-w][data-s]';

function fixture() {
  const posts = [];
  const timers = new Map();
  let timerId = 0;
  let now = 1000;
  let showHost = true;
  let panel;
  let words = [];
  let pending;
  const doc = {
    defaultView: { getComputedStyle: () => ({ visibility: 'visible' }) },
    querySelector: selector => selector === '[data-llr-ui]' && showHost ? { shadowRoot: shadow } : null,
  };
  const shadow = {
    querySelector: () => panel?.shown ? panel : null,
  };
  const article = {
    ownerDocument: doc,
    hidden: false,
    querySelectorAll(selector) {
      assert(selector.startsWith(wordSelector));
      return selector.endsWith('[data-llr-sel]') ? words.filter(word => word.selected) : words;
    },
  };
  const vmContext = {
    Date: { now: () => now },
    TextEncoder,
    AbortSignal: { timeout: () => undefined },
    setTimeout(callback, delay) {
      const id = ++timerId;
      timers.set(id, { callback, due: now + delay });
      return id;
    },
    clearTimeout(id) {
      timers.delete(id);
    },
    async fetch(url, request) {
      posts.push({ url, request, data: JSON.parse(request.body), sentAt: now });
      return pending ? await pending.promise : { ok: true };
    },
  };
  vm.runInNewContext(code, vmContext);
  const observer = vmContext.createSlukaObserver({ article, session: 'a'.repeat(64) });

  const element = (text, visible = true) => ({
    children: [],
    ownerDocument: doc,
    innerText: text,
    textContent: text,
    getClientRects: () => (visible ? [{}] : []),
  });
  return {
    observer, article, posts, timers,
    host(value) { showHost = value; },
    words(value) { words = value.map(([surface, status, selected, key, tags]) => ({
      ...element(surface),
      dataset: { w: key ?? surface, s: String(status), ...tags },
      selected,
    })); },
    paragraph(index, line, wordIndexes) {
      article.children ??= [];
      const paragraph = { ...element(line), tagName: 'P',
        querySelectorAll: () => wordIndexes.map(([wordIndex]) => words[wordIndex]) };
      article.children[index] = paragraph;
      doc.createRange = () => {
        let parent;
        let end;
        return {
          selectNodeContents(value) { parent = value; },
          setEndBefore(word) { end = word; },
          cloneContents() {
            assert.equal(parent, paragraph);
            const start = wordIndexes.find(([wordIndex]) => words[wordIndex] === end)[1];
            return element(line.slice(0, start));
          },
        };
      };
    },
    panel({ headword, reading, definitions, shown = true, variant }) {
      let head = element(headword);
      if (variant) {
        head.children = [{}];
        head.textContent += ' ' + variant;
        head.cloneNode = () => {
          const clone = element(head.textContent);
          clone.querySelectorAll = selector => {
            assert.match(selector, /\.variant/);
            return [{ remove: () => { clone.textContent = headword; } }];
          };
          return clone;
        };
      }
      panel = {
        ...element(''),
        shown,
        querySelector: () => head,
        querySelectorAll: selector => selector === '.reading' ? [element(reading)]
          : selector === '.rg-dict .od-reading' ? []
          : definitions.map(line => typeof line === 'string' ? element(line) : element(line.hidden, false)),
      };
    },
    suspendFetch() {
      pending = Promise.withResolvers();
      return () => {
        pending.resolve({ ok: true });
        pending = null;
      };
    },
    async tick() {
      const [id, timer] = timers.entries().next().value;
      timers.delete(id);
      now = timer.due;
      return timer.callback();
    },
  };
}

(async () => {
  const positioned = fixture();
  const sentence = '📚 図書館\n\n図書館へ';
  const secondStart = sentence.lastIndexOf('図書館');
  positioned.words([['図書館', 0, false], ['図書館', 0, false]]);
  positioned.paragraph(1, '図書館へ', [[1, 0]]);
  positioned.observer.observe(8, sentence, secondStart + 1);
  await positioned.tick();
  assert.deepEqual(positioned.posts[0].data.pointerWord, {surface: '図書館', start: secondStart});
  positioned.paragraph(1, '図書館へ。', [[1, 0]]);
  await positioned.tick();
  assert.equal(positioned.posts[1].data.pointerWord, undefined, 'Reject positions in altered text');

  const f = fixture();
  f.observer.observe(-1);
  assert.equal(f.timers.size, 0);
  f.observer.observe(23);
  await f.tick();
  assert.equal(f.posts.length, 0, 'Plain capture text never uploads');

  f.words([['书', 5], ['书', 5], ['变', 99], ['銀行', 2, true], ['不变', 7]]);
  f.host(false);
  await f.tick();
  assert.equal(f.posts.length, 1, 'Token statuses arrive before the word panel mounts');
  assert.equal(f.posts[0].data.lookup, null);
  f.posts.length = 0;
  f.host(true);
  f.panel({ headword: '銀行', variant: '银行', reading: 'yín háng',
    definitions: [{ hidden: 'a hidden entry' }, 'bank', 'bank', 'financial institution'] });
  await f.tick();
  assert.equal(f.posts[0].url, '/sluka');
  assert.equal(f.posts[0].request.method, 'POST');
  assert.equal(f.posts[0].request.mode, 'same-origin');
  assert.equal(f.posts[0].request.referrer, '');
  assert.equal(f.posts[0].request.referrerPolicy, 'same-origin');
  assert.equal(f.posts[0].request.headers['X-OCRCompanion-Session'], 'a'.repeat(64));
  assert.deepEqual(f.posts[0].data, {
    textRevision: 23,
    words: [{ surface: '书', key: '书', status: 5, gradeable: true },
      { surface: '銀行', key: '銀行', status: 2, gradeable: true },
      { surface: '不变', key: '不变', status: 7, gradeable: true }],
    lookup: { surface: '銀行', key: '銀行', reading: 'yín háng', definition: 'bank\nfinancial institution', status: 2, gradeable: true },
  });

  await f.tick();
  assert.equal(f.posts.length, 1, 'An unchanged browser view sends nothing');
  f.panel({ headword: '无关', reading: '', definitions: ['unrelated'] });
  await f.tick();
  assert.equal(f.posts[1].data.lookup, null, 'A Sluka card outside the capture is ignored');
  f.words([['書', 2], ['書', 5], ['银行', 3]]);
  await f.tick();
  assert.deepEqual(f.posts[2].data.words, [{ surface: '银行', key: '银行', status: 3, gradeable: true }], 'Conflicting grades are omitted');
  assert.ok(f.posts[2].sentAt - f.posts[1].sentAt >= 1000);
  f.observer.clear();
  await f.tick();
  assert.deepEqual(f.posts[3].data, { textRevision: 23, words: [], lookup: null });
  assert.equal(f.timers.size, 0, 'Clearing a previously published capture stops observation');

  const limited = fixture();
  limited.words(Array.from({ length: 200 }, (_, i) => [i.toString().padStart(3, '0') + '字'.repeat(61), 1, false, 'key' + i]));
  limited.observer.observe(1);
  await limited.tick();
  assert.equal(limited.posts[0].data.words.length, 64);
  assert.ok(Buffer.byteLength(limited.posts[0].request.body) <= 18 * 1024);

  const ambiguous = fixture();
  ambiguous.words([['行', 0, true, '行1'], ['行', 0, false, '行2'],
    ['未定', 0, false, '未定'], ['未定', 0, false, '字'.repeat(129)],
    ['句尾', 6, false, '句尾', { rdGrammar: 'particle' }],
    ['片', 1, false, '一片', { cont: '' }], ['词首', 1, false, '词首尾', { split: '' }],
    ['看', 5, false, 'to-see', { splitVerb: '看见' }]]);
  ambiguous.panel({ headword: '行', reading: 'xíng', definitions: ['to go'] });
  ambiguous.observer.observe(3);
  await ambiguous.tick();
  assert.deepEqual(ambiguous.posts[0].data, {
    textRevision: 3,
    words: [{ surface: '句尾', key: '句尾', status: 6, gradeable: false },
      { surface: '片', key: '一片', status: 1, gradeable: false },
      { surface: '词首', key: '词首尾', status: 1, gradeable: false },
      { surface: '看', key: 'to-see', status: 5, gradeable: false }],
    lookup: null,
    ambiguousSurfaces: ['行', '未定'],
  }, 'Matching grades cannot disambiguate canonical words and non-gradeable words stay read-only');

  const controls = fixture();
  controls.words([['句尾', 6, true, '句尾', { rdGrammar: 'particle' }]]);
  controls.panel({ headword: '句尾', reading: '', definitions: ['grammar note'] });
  controls.observer.observe(4);
  await controls.tick();
  assert.equal(controls.posts[0].data.lookup.gradeable, false);

  const clipped = fixture();
  clipped.words([['词', 0, true]]);
  clipped.panel({ headword: '词', reading: 'x'.repeat(127) + '😀',
    definitions: ['x'.repeat(1499) + '😀', 'later'] });
  clipped.observer.observe(2);
  await clipped.tick();
  assert.equal(clipped.posts[0].data.lookup.definition.length, 1499);
  assert.equal(clipped.posts[0].data.lookup.reading.length, 127);
  assert.doesNotMatch(clipped.posts[0].request.body, /\\ud83d/);

  const inFlight = fixture();
  inFlight.words([['花', 0]]);
  inFlight.observer.observe(111);
  const resume = inFlight.suspendFetch();
  const sending = inFlight.tick();
  inFlight.observer.clear();
  assert.equal(inFlight.timers.size, 0);
  resume();
  await sending;
  await inFlight.tick();
  assert.deepEqual(inFlight.posts[1].data, { textRevision: 111, words: [], lookup: null });
  assert.equal(inFlight.timers.size, 0);
  console.log('PASS: passive Sluka reporting, exact lookups, authentication, limits, deduplication, and clearing');
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
