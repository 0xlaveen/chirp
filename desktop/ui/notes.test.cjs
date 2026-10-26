const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(__dirname + '/notes.js', 'utf8');
const copy = value => structuredClone(value);
const deferred = () => { let resolve; return { promise: new Promise(r => { resolve = r; }), resolve: value => resolve(value) }; };
const tick = () => new Promise(resolve => setImmediate(resolve));
function ui() {
  const nodes = new Map(), callbacks = new Map(), timers = new Map(), calls = [], records = new Map();
  let active = null, nextId = 0, editHook = null, organizeHook = null;
  function node() { return { value: '', textContent: '', checked: false, hidden: false, disabled: false, children: [], selectionStart: 0, selectionEnd: 0, scrollTop: 0, classList: {toggle(name, enabled) { this[name] = enabled; }},
    append(...children) { this.children.push(...children); }, replaceChildren(...children) { this.children = children; }, setAttribute(name, value) { this[name] = value; }, focus() { this.focused = true; }, showModal() {},
    setRangeText(text, start, end) { this.value = this.value.slice(0, start) + text + this.value.slice(end); }, setSelectionRange(start, end) { this.selectionStart = start; this.selectionEnd = end; },
    set innerHTML(_) { throw new Error('User content must never use innerHTML'); },
  }; }
  function element(id) { if (!nodes.has(id)) nodes.set(id, node()); return nodes.get(id); }
  const invoke = async (command, args = {}) => {
    calls.push([command, copy(args)]);
    const n = records.get(args.id);
    switch (command) {
      case 'notes_list': return { entries: [...records.values()].filter(n => !!n.deleted_at === args.trash).map(n => ({ ...n, snippet: n.body, todos: 0 })), active, warnings: 0 };
      case 'notes_create': { const n = { id: String(++nextId), title: 'Untitled note', body: '', body_version: 0, created_at: 1, updated_at: 1, duration_ms: 0, segments: [], boundaries: [], deleted_at: null, paused: false, recording: false, last_error: '', organize_undo: null }; records.set(n.id, n); return copy(n); }
      case 'notes_get': return copy(n);
      case 'notes_edit': {
        let result = editHook ? await editHook(args) : { ...n, body: args.body, title: args.title ?? n.title, body_version: n.body_version + 1 };
        records.set(args.id, copy(result)); return copy(result);
      }
      case 'notes_record': active = args.id; n.recording = true; return;
      case 'notes_stop': for (const n of records.values()) n.recording = false; active = null; return;
      case 'notes_trash': n.deleted_at = args.deleted ? 1 : null; return;
      case 'notes_organize': return organizeHook ? organizeHook(args) : { id: n.id, version: n.body_version, markdown: '# Organized' };
      case 'notes_apply_organize': n.body = args.markdown; n.body_version++; return copy(n);
      case 'notes_discard_blank': return;
      case 'notes_export': return false;
      case 'notes_flush_complete': return;
      default: throw new Error(`Unexpected ${command}`);
    }
  };
  vm.runInNewContext(source, { window: { __TAURI__: { core: { invoke }, event: { listen(name, fn) { callbacks.set(name, fn); } } } },
    document: { body: element('body'), getElementById: element, createElement: node, createTextNode: text => ({ textContent: text }) }, location: { search: '' }, URLSearchParams,
    setTimeout(fn) { const key = timers.size + 1; timers.set(key, fn); return key; }, clearTimeout(key) { timers.delete(key); }, setInterval() {},
  });
  return { element, calls, records, event: (type, payload) => callbacks.get(type)({ payload }),
    editHook(fn) { editHook = fn; }, organizeHook(fn) { organizeHook = fn; },
    async save() { const fn = [...timers.values()].at(-1); timers.clear(); if (fn) await fn(); },
    async create() { await element('new-note').onclick(); return String(nextId); },
    async select(id) { await tick(); const buttons = element('note-list').children.filter(n => n.onclick); const entry = [...records.keys()].indexOf(id); await buttons[entry].onclick(); },
  };
}
test('automatic saving merges AI appended text with typing that continues during the write', async () => {
  const app = ui(); await app.create(); const wait = deferred(); let first = true;
  app.editHook(async args => {
    if (first) { first = false; await wait.promise; return { ...app.records.get(args.id), body: args.body + '\n\nAI point', body_version: 2 }; }
    return { ...app.records.get(args.id), body: args.body, body_version: 3 };
  });
  const body = app.element('note-body'); body.value = 'My edit'; body.oninput();
  const save = app.save(); await tick();
  body.value = 'My newer edit'; body.selectionStart = body.selectionEnd = 3; body.oninput();
  app.event('notes-changed', '1'); await tick(); assert.equal(body.value, 'My newer edit');
  wait.resolve(); await save;
  assert.equal(body.value, 'My newer edit\n\nAI point');
  assert.equal(body.selectionStart, 3);
  assert.equal(app.records.get('1').body, body.value);
  assert.equal(app.element('note-save-state').textContent, 'Saved on this computer');
});
test('Organize response is discarded if the user edited during the request', async () => {
  const app = ui(); await app.create(); const body = app.element('note-body'); body.value = 'Original'; body.oninput(); await app.save();
  const wait = deferred(); app.organizeHook(() => wait.promise);
  const organizing = app.element('note-organize').onclick(); await tick();
  body.value = 'New human edit'; body.oninput();
  wait.resolve({ id: '1', version: 1, markdown: 'Stale organized version' }); await organizing;
  assert.equal(body.value, 'New human edit');
  assert(!app.calls.some(([command]) => command === 'notes_apply_organize'));
  assert.match(app.element('notes-message').textContent, /edits were kept/);
});
test('late live events stay with the recording note while another document is open', async () => {
  const app = ui(); const first = await app.create(); await app.element('note-record').onclick(); const second = await app.create();
  assert.notEqual(first, second);
  app.element('note-live').textContent = '';
  app.event('notes-live', { id: first, update: { text: '<script>synthetic</script>', detail: 'Listening' } });
  assert.equal(app.element('note-live').textContent, '');
  app.event('notes-changed', first); await tick();
  assert.equal(app.element('note-title').value, app.records.get(second).title);
  assert.equal(app.element('jump-recording').hidden, false);
});
test('delete and Undo restore the same local document', async () => {
  const app = ui(); const id = await app.create(); app.element('note-body').value = 'Keep this'; app.element('note-body').oninput(); await app.save();
  await app.element('note-delete').onclick(); assert.equal(app.records.get(id).deleted_at, 1);
  await app.element('note-undo-delete').onclick(); assert.equal(app.records.get(id).deleted_at, null); assert.equal(app.element('note-body').value, 'Keep this');
});


test('Quit waits for the current edit to save and reports a failed write without discarding text', async () => {
  const app = ui(); await app.create(); const body = app.element('note-body');
  body.value = 'Last keystrokes'; body.oninput();
  await app.event('notes-save-for-quit', 1);
  assert.equal(app.records.get('1').body, 'Last keystrokes');
  assert.equal(app.calls.at(-1)[0], 'notes_flush_complete'); assert.equal(app.calls.at(-1)[1].ok, true);
  app.event('notes-status', {id:'',detail:'Continue editing'});
  app.editHook(async () => {throw new Error('Disk full');}); body.value = 'Keep my unsaved text'; body.oninput();
  await app.event('notes-save-for-quit', 2);
  assert.equal(app.calls.at(-1)[1].ok, false); assert.equal(body.value, 'Keep my unsaved text');
  assert.equal(app.element('main').inert, false);
});


test('tabs select the visible panel for clicks, keyboard and opening Notes from the tray', () => {
  const app = ui(), notes = app.element('show-notes'), dictation = app.element('show-dictation');
  function selected(isNotes) {
    assert.equal(notes['aria-selected'], String(isNotes));
    assert.equal(dictation['aria-selected'], String(!isNotes));
    assert.equal(notes.classList.quiet, !isNotes);
    assert.equal(dictation.classList.quiet, isNotes);
    assert.equal(notes.tabIndex, isNotes ? 0 : -1);
    assert.equal(dictation.tabIndex, isNotes ? -1 : 0);
    assert.equal(app.element('notes-view').hidden, !isNotes);
    assert.equal(app.element('dictation-view').hidden, isNotes);
  }
  dictation.onclick(); selected(false);
  notes.onclick(); selected(true);
  let prevented = false;
  notes.onkeydown({ key: 'ArrowRight', preventDefault() { prevented = true; } });
  assert(prevented); assert(dictation.focused); selected(false);
  dictation.onkeydown({ key: 'Home', preventDefault() {} }); selected(true);
  notes.onkeydown({ key: 'End', preventDefault() {} }); selected(false);
  app.event('open-notes'); selected(true);
});
