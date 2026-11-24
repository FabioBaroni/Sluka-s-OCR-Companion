'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const script = fs.readFileSync(path.join(__dirname, '../Reader/reader.js'), 'utf8');
const key = 'a'.repeat(64);
const title = '0123456789ab';
const tick = () => new Promise(setImmediate);

function harness(hash, priorState, readerID = "11111111-1111-4111-8111-111111111111", hidden = false, focus = false) {
  const requests = [], observed = [];
  const article = {
    hidden: true,
    children: [],
    replaceChildren() { this.children = []; },
    append(child) { this.children.push(child); },
    querySelector() { return null; }
  };
  let timer, removed, onPageHide, savedState, reloads = 0, now = Date.now();
  const command = {id: 'word-grade', textRevision: 7, expiresAt: Date.now() + 10000, grade: 5};
  vm.runInNewContext(script, {
    window: {addEventListener(event, callback) { if (event === "pagehide") onPageHide = callback; }},
    document: {
      documentElement: {},
      querySelector: selector => selector === '#text' ? article : {getAttribute() {}, setAttribute() {}},
      createElement: () => ({}),
      hidden,
    },
    location: {hash, reload() { reloads++; }},
    history: {state: priorState, replaceState: (state, _title, path) => { removed = path; savedState = state; }},
    crypto: {randomUUID: () => readerID},
    URLSearchParams, AbortSignal,
    Date: {now: () => now},
    clearTimeout() {},
    setTimeout(callback, delay) { if (delay === 750) timer = callback; },
    createSlukaObserver() { return {observe: revision => observed.push(revision), clear() {}, refresh() {}}; },
    createSlukaControls({isCurrent, authorize}) {
      return {prepareForCaptureChange() {}, refresh() {}, async execute(value) {
        assert.equal(isCurrent(value.textRevision), true);
        assert.equal(await authorize(value), true);
        return {outcome: 'applied', status: value.grade};
      }};
    },
    async fetch(resource, options) {
      requests.push([resource, options]);
      assert.equal(options.headers['X-OCRCompanion-Session'], key);
      assert.equal(options.headers['X-OCRCompanion-Reader'], readerID);
      if (resource === '/state') {
        if (hidden && requests.length > 1) return {status: 403, ok: false};
        const ready = options.headers['X-OCRCompanion-Controls'] === 'ready';
        return {ok: true, json: async () => ({
          textRevision: 7, text: focus ? '戈' : '小青', language: 'zh-Hans',
          refreshIfUnannotated: focus, ...(ready && !focus ? {command} : {})
        })};
      }
      return {ok: true};
    },
  });
  return {article, requests, observed, get removed() { return removed; }, get savedState() { return savedState; },
    get reloads() { return reloads; }, advance: ms => { now += ms; }, poll: () => timer(), close: () => onPageHide()};
}

(async () => {
  const missing = harness('#session=' + key);
  await tick();
  assert.equal(missing.requests.length, 0);
  const reader = harness('#session=' + key + '&mode=compact&title=' + title);
  await tick();
  assert.equal(reader.removed, '/');
  assert.equal(reader.article.children[0].textContent, '小青');
  assert.deepEqual(reader.observed, [7]);
  const paragraph = reader.article.children[0];
  await reader.poll();
  await tick();
  assert.equal(reader.article.children[0], paragraph, 'Repeated polls preserve Sluka annotation nodes');
  assert.deepEqual(reader.requests.map(([route]) => route), ['/state', '/state', '/sluka-commit', '/sluka-result']);
  assert.deepEqual(JSON.parse(reader.requests.at(-1)[1].body), {
    id: 'word-grade', textRevision: 7, outcome: 'applied', status: 5
  });
  assert.equal(reader.requests[0][1].headers['X-OCRCompanion-Join'], '1');
  assert.equal(reader.requests[1][1].headers['X-OCRCompanion-Join'], undefined);
  const reload = harness('', reader.savedState, '22222222-2222-4222-8222-222222222222');
  await tick();
  assert.equal(reload.article.children[0].textContent, '小青');
  assert.equal(reload.requests[0][1].headers['X-OCRCompanion-Join'], '1');
  const background = harness('', reader.savedState, '33333333-3333-4333-8333-333333333333', true);
  await tick();
  assert.equal(background.requests[1][1].headers['X-OCRCompanion-Wait'], '7', 'Hidden reader keeps polling via the server');
  reader.close();
  await tick();
  assert.equal(reader.requests.at(-1)[0], '/sluka-disconnect');
  assert.equal(reader.requests.at(-1)[1].keepalive, true);
  const focused = harness('', reader.savedState, undefined, false, true);
  await tick();
  focused.advance(1700);
  await focused.poll();
  await tick();
  assert.equal(focused.reloads, 1);
  assert.equal(focused.savedState.ocrCompanion.seed.text, '戈');
  const fresh = harness('', focused.savedState, undefined, false, true);
  assert.equal(fresh.article.children[0].textContent, '戈', 'The word is on the page before the first poll returns');
  assert.deepEqual(fresh.observed, [], 'Wait for an authoritative revision before reporting the seeded word');
  await tick();
  fresh.advance(2000);
  await fresh.poll();
  await tick();
  assert.equal(fresh.reloads, 0, 'An inactive extension does not cause a reload loop');
  console.log('PASS reader connection, one-shot grades, and focused reload seeded before polling');
})().catch(error => { console.error(error); process.exitCode = 1; });
