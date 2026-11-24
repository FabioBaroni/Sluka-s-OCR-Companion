'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../Reader/sluka-controls.js'), 'utf8');

function fixture(initialStatus, options = {}) {
  let now = 0;
  let live = true;
  let opens = 0;
  let hovers = 0;
  let writes = 0;
  let authorizations = 0;
  let pinned = options.pinned ?? false;
  let shown = pinned;
  let selection = [];
  const tokens = [];
  const { surface = '行', key = '行', level = 'háng' } = options;
  const defaultView = { getComputedStyle: () => ({ visibility: 'visible' }) };
  const doc = { defaultView, querySelectorAll: selector => selector === '[data-llr-ui]' ? [host] : selection };
  let heading = node(options.wrongHead ?? surface);

  function node(value) {
    return {
      children: [], textContent: value, innerText: value, isConnected: true,
      ownerDocument: doc, getClientRects: () => [1],
    };
  }

  function addToken(word, identity, status, grammar = false) {
    const token = Object.assign(node(word), {
      dataset: { w: identity, s: String(status) },
      hasAttribute: name => grammar && name === 'data-rd-grammar',
      click() {
        ++opens;
        pinned = true;
        shown = true;
        heading = node(options.wrongHead ?? word);
        selection = [token];
      },
      dispatchEvent(event) {
        assert.equal(event.type, 'mouseover');
        ++hovers;
        if (!options.noPreview) {
          heading = node(options.wrongHead ?? word);
          shown = true;
        }
      },
    });
    tokens.push(token);
    return token;
  }

  const token = addToken(surface, key, initialStatus, options.grammar);
  if (pinned) selection = [token];
  const grades = Array.from({ length: 6 }, (_, index) => {
    const grade = index + 1;
    const isActive = () => grade === Number(token.dataset.s);
    return {
      dataset: { set: String(grade) },
      hasAttribute: name => name === 'data-active' && isActive(),
      isConnected: true, disabled: false, ownerDocument: doc,
      // On the actual Sluka hover card these buttons are CSS-hidden.
      getClientRects: () => pinned ? [1] : [],
      click() {
        ++writes;
        if (!options.refuse) {
          const status = isActive() ? 0 : grade;
          tokens.filter(item => item.dataset.w === key).forEach(item => { item.dataset.s = String(status); });
          options.onWrite?.(status);
          if ([5, 6].includes(status)) shown = false;
        }
      },
    };
  });
  const closeButton = {
    ...node('Close'),
    click() { shown = false; pinned = false; selection = []; },
  };
  const panel = {
    ...node(''), hasAttribute: name => name === 'data-preview' && !pinned || name === 'data-show' && shown,
    querySelector(selector) {
      if (selector === 'button[data-close]') return closeButton;
      assert.equal(selector, '.word');
      return heading;
    },
    querySelectorAll(selector) {
      if (selector === 'textarea, input, [contenteditable="true"]') return [];
      if (selector === '.levels > button[data-set][data-active]') return grades.filter(button => button.hasAttribute('data-active'));
      if (selector === '.levels > button[data-set]') return options.noGrades ? [] : grades;
      if (options.noDefinition) return [];
      if (selector === '.reading') return [node(level)];
      return now < (options.delayDefinition ?? 0) ? [] : [node('row or line')];
    },
  };
  const host = { shadowRoot: { querySelectorAll: () => shown ? [panel] : [] } };
  const article = { ownerDocument: doc, querySelectorAll: () => tokens, contains: element => tokens.includes(element) };
  const authorize = async command => {
    ++authorizations;
    return options.authorize ? options.authorize(command, token, () => { live = false; }) : true;
  };
  const context = vm.createContext({
    Date: { now: () => now },
    setTimeout(fn, delay) { now += delay; queueMicrotask(fn); },
    MouseEvent: class { constructor(type) { this.type = type; } },
  });
  vm.runInContext(source, context);
  const controls = context.createSlukaControls({ article, isCurrent: revision => live && revision === 7, authorize });
  let id = 1;
  return {
    token, addToken,
    prepareForCaptureChange: controls.prepareForCaptureChange,
    repaintHeading() { heading = node(heading.textContent); },
    isCardOpen: () => shown,
    replaceTokens(word, nextKey, status) {
      tokens.forEach(item => { item.isConnected = false; });
      tokens.length = 0;
      selection = [];
      addToken(word, nextKey, status);
    },
    supersede() { live = false; },
    setOutsideSelection() { selection = [{ ...token }]; },
    execute(grade, extra) {
      return controls.execute({
        id: String(id++), textRevision: 7, surface, key, expectedStatus: initialStatus, grade, ...extra,
      });
    },
    counts: () => ({ opens, hovers, writes, authorizations }),
  };
}

async function translateFixture({ captured, heading, span = captured, existing = false }) {
  let now = 0;
  let shown = existing;
  let selected;
  let closes = 0;
  const selection = {
    get rangeCount() { return Number(Boolean(selected)); },
    get isCollapsed() { return !selected; },
    getRangeAt: () => selected,
    removeAllRanges() { selected = undefined; },
    addRange(range) { selected = range; },
  };
  const doc = {
    getSelection: () => selection,
    createRange: () => ({
      selectNodeContents() {}, setStartBefore() {}, setEndAfter() {},
      cloneContents: () => node(span),
    }),
    querySelectorAll: () => [{ shadowRoot: {
      querySelectorAll: selector => shown && (heading || !selector.includes('not([data-card])')) ? [panel] : [],
    } }],
    defaultView: { getComputedStyle: () => ({ visibility: 'visible' }) },
  };
  const node = value => ({
    textContent: value, innerText: value, children: [],
    isConnected: true, ownerDocument: doc, getClientRects: () => [{}],
  });
  const head = heading ? node(heading) : null;
  const panel = {
    ...node(''),
    hasAttribute: name => name === 'data-show' && shown || name === 'data-card' && !heading,
    querySelector(selector) {
      if (selector === '.word') return head;
      if (selector === 'button[data-close]') return {
        ...node('Close'), click() { shown = false; closes++; },
      };
      return null;
    },
    querySelectorAll(selector) {
      if (selector === '.card-from, .word') return head ? [head] : [];
      if (selector.includes('.rg-google li') && now >= 100) return [node("What's your surname?")];
      return [];
    },
  };
  const tokens = [{}, { dispatchEvent: event => { assert.equal(event.type, 'mouseup'); shown = true; } }];
  const paragraph = { ...node(captured), querySelectorAll: () => tokens };
  const article = { ownerDocument: doc, children: [paragraph], firstElementChild: paragraph };
  const context = vm.createContext({
    Date: { now: () => now },
    setTimeout(fn, delay) { now += delay; queueMicrotask(fn); },
    MouseEvent: class { constructor(type) { this.type = type; } },
  });
  vm.runInContext(source, context);
  const controls = context.createSlukaControls({ article, isCurrent: revision => revision === 7 });
  const result = await controls.execute({ id: 'translate', textRevision: 7, surface: captured,
                                          grade: null, translatesPassage: true });
  return { result, closes, selectionCleared: selection.isCollapsed };
}

async function run() {
  for (const punctuation of ['?', '？！', '。']) {
    const phrase = await translateFixture({ captured: '请问您贵姓' + punctuation, heading: '请问您贵姓' });
    assert.equal(phrase.result.outcome, 'translated');
    assert.equal(phrase.result.translation, "What's your surname?");
    assert.equal(phrase.closes, 1);
    assert.equal(phrase.selectionCleared, true);
  }
  const clause = await translateFixture({ captured: '请问，您贵姓？', span: '请问，您贵姓' });
  assert.equal(clause.result.outcome, 'translated');
  assert.equal(clause.closes, 1);
  const other = await translateFixture({ captured: '请问，您贵姓？', heading: '请问您贵姓' });
  assert.equal(other.result.outcome, 'unavailable', 'Preserve meaningful punctuation inside the capture');
  assert.equal(other.closes, 0);
  const partial = await translateFixture({ captured: '请问您贵姓？', span: '您贵姓' });
  assert.equal(partial.result.outcome, 'unavailable', 'Reject a partial selection without a source label');
  assert.equal(partial.closes, 0);
  const existing = await translateFixture({ captured: '请问您贵姓？', existing: true });
  assert.equal(existing.result.outcome, 'unavailable', 'Keep a preexisting translation card separate');
  assert.equal(existing.closes, 0);
  console.log('PASS translation handoff after Sluka drops sentence punctuation, with exact passage coverage');

  let sluka = fixture(0);
  const lookup = await sluka.execute(null);
  assert.equal(lookup.outcome, 'lookup');
  assert.equal(lookup.lookup.key, '行');
  assert.equal(lookup.lookup.reading, 'háng');
  assert.equal(lookup.lookup.definition, 'row or line');
  assert.deepEqual(sluka.counts(), { opens: 0, hovers: 1, writes: 0, authorizations: 0 });

  const delayed = fixture(0, {delayDefinition: 400, surface: '戈', key: '戈', level: 'gē'});
  const delayedResult = await delayed.execute(null);
  assert.equal(delayedResult.outcome, 'lookup');
  assert.equal(delayedResult.lookup.definition, 'row or line');
  assert.equal(delayed.counts().writes, 0);

  sluka = fixture(0);
  const applied = await sluka.execute(5, { id: 'once' });
  assert.equal(applied.outcome, 'applied');
  assert.equal(applied.status, 5);
  assert.equal(applied.lookup.status, 5);
  await sluka.execute(5, { id: 'once' });
  assert.deepEqual(sluka.counts(), { opens: 0, hovers: 1, writes: 1, authorizations: 1 });

  sluka = fixture(5);
  assert.equal((await sluka.execute(3)).status, 3);
  assert.deepEqual(sluka.counts(), { opens: 1, hovers: 0, writes: 1, authorizations: 1 });

  sluka = fixture(5, { surface: '土', key: '土', level: 'tǔ' });
  assert.equal((await sluka.execute(null)).lookup?.surface, '土');
  sluka.repaintHeading();
  sluka.prepareForCaptureChange();
  assert.equal(sluka.isCardOpen(), false, 'Close the card while its outgoing selection still exists');
  sluka.replaceTokens('火', '火', 5);
  const fire = await sluka.execute(null, { surface: '火', key: '火' });
  assert.equal(fire.lookup?.surface, '火');
  assert.equal(fire.lookup?.status, 5);
  assert.deepEqual(sluka.counts(), { opens: 2, hovers: 0, writes: 0, authorizations: 0 });

  sluka = fixture(5, { pinned: true });
  assert.equal((await sluka.execute(null)).outcome, 'lookup');
  sluka.prepareForCaptureChange();
  assert.equal(sluka.isCardOpen(), true, 'Leave a manually opened Sluka card alone');

  sluka = fixture(3, { pinned: true });
  assert.equal((await sluka.execute(3)).outcome, 'unchanged');
  assert.equal(sluka.counts().writes, 0);
  assert.equal((await sluka.execute(0)).status, 0);
  assert.equal(sluka.counts().writes, 1);

  sluka = fixture(0);
  sluka.addToken('行', '行-other', 0);
  assert.equal((await sluka.execute(5)).outcome, 'ambiguous');
  assert.equal(sluka.counts().authorizations, 0);

  sluka = fixture(0);
  sluka.addToken('行', '行', 3);
  assert.equal((await sluka.execute(5)).outcome, 'ambiguous');
  assert.equal(sluka.counts().authorizations, 0);

  sluka = fixture(0);
  sluka.supersede();
  assert.equal((await sluka.execute(5)).outcome, 'stale');
  assert.equal(sluka.counts().hovers, 0);

  sluka = fixture(5, { pinned: true });
  sluka.token.dataset.s = '1';
  assert.equal((await sluka.execute(6)).outcome, 'conflict');
  assert.equal(sluka.counts().authorizations, 0);

  sluka = fixture(0, { noPreview: true });
  assert.equal((await sluka.execute(4)).outcome, 'unavailable');
  assert.equal(sluka.counts().opens, 0);
  assert.equal(sluka.counts().writes, 0);

  sluka = fixture(0, { noGrades: true });
  assert.equal((await sluka.execute(4)).outcome, 'unavailable');
  assert.equal(sluka.counts().authorizations, 0);

  sluka = fixture(0, { authorize: () => false });
  assert.equal((await sluka.execute(4)).outcome, 'stale');
  assert.equal(sluka.counts().writes, 0);

  sluka = fixture(0, { authorize: (_command, token) => { token.dataset.s = '1'; return true; } });
  assert.equal((await sluka.execute(4)).outcome, 'conflict');
  assert.equal(sluka.counts().writes, 0);

  sluka = fixture(0, { authorize: (_command, _token, revoke) => { revoke(); return true; } });
  assert.equal((await sluka.execute(4)).outcome, 'stale');
  assert.equal(sluka.counts().writes, 0);

  sluka = fixture(0, { refuse: true });
  assert.equal((await sluka.execute(4, { id: 'refused' })).outcome, 'unconfirmed');
  assert.equal((await sluka.execute(4, { id: 'refused' })).outcome, 'unconfirmed');
  assert.equal(sluka.counts().writes, 1);

  sluka = fixture(0, { wrongHead: '银行' });
  assert.equal((await sluka.execute(4)).outcome, 'unavailable');
  assert.equal(sluka.counts().writes, 0);

  sluka = fixture(0, { grammar: true });
  assert.equal((await sluka.execute(4)).outcome, 'unavailable');
  assert.equal((await sluka.execute(null, { id: 'grammar-lookup' })).outcome, 'lookup');
  assert.equal(sluka.counts().writes, 0);

  sluka = fixture(0, { pinned: true, noPreview: true });
  sluka.setOutsideSelection();
  assert.equal((await sluka.execute(4)).outcome, 'unavailable');
  assert.equal(sluka.counts().writes, 0);
  assert.equal((await fixture(0, {noDefinition: true}).execute(null)).outcome, 'noDefinition');
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'ocr-grade-fixture-'));
  try {
    const storage = path.join(folder, 'grade');
    const reopen = () => fixture(fs.existsSync(storage) ? Number(fs.readFileSync(storage, 'utf8')) : 0, {
      onWrite: grade => fs.writeFileSync(storage, String(grade)),
    });
    assert.equal((await reopen().execute(5)).status, 5);
    assert.equal((await reopen().execute(null)).status, 5);
    assert.equal((await reopen().execute(0)).status, 0);
    assert.equal((await reopen().execute(null)).status, 0);
  } finally {
    fs.rmSync(folder, {recursive: true, force: true});
  }
  console.log('PASS Sluka lookup and grades use exact current tokens, require one authorization, and confirm their result');
}

run().catch(error => { console.error(error); process.exitCode = 1; });
