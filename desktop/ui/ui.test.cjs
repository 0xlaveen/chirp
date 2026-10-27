const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(__dirname + '/app.js', 'utf8');
function ui({hud = true, history = []} = {}) {
  let entries = history;
  const nodes = new Map(); const callbacks = new Map(); const calls = [];
  const element = id => {
    if (!nodes.has(id)) nodes.set(id, { value:'', textContent:'', checked:false, hidden:false, disabled:false, children:[], append(...items){this.children.push(...items);}, replaceChildren(){this.children = [];}, showModal(){this.open = true;}, classList:{add(){},toggle(){}} });
    return nodes.get(id);
  };
  const context = vm.createContext({
    window: { __TAURI__: { core: { invoke: async (command, args) => {
      calls.push([command, args]);
      if (command === 'history_list') return entries;
      if (command === 'history_delete') { entries = entries.filter(e => e.id !== args.id); return; }
      if (command === 'history_clear') { entries = []; return; }
      if (command === 'preferences') return { settings:{url:'http://localhost:7899',hotkey:'RightCtrl',mode:'Hold',correction:false},capabilities:{detail:'X11'},paired:true };
    } }, event:{listen: (name, cb) => { callbacks.set(name, cb); }} } },
    document:{createElement:tag=>element(Symbol(tag)),getElementById:element,body:element('body'),addEventListener(){}},
    location:{search:hud ? '?hud' : ''}, URLSearchParams,
  });
  vm.runInContext(source, context);
  return { element, calls, update: payload => callbacks.get('dictation')({payload}), shortcut: payload => callbacks.get('shortcut-status')({payload}), event: (name,payload) => callbacks.get(name)({payload}) };
}
test('server text is rendered as text, including HTML-like dictation', () => {
  const app = ui();
  app.update({state:'listening',text:'<img src=x onerror=alert(1)>',detail:'Listening',debug_retention:true});
  assert.equal(app.element('hud-text').textContent, '<img src=x onerror=alert(1)>');
  assert.equal(app.element('record').disabled, true);
  assert.equal(app.element('debug').hidden, false);
  app.update({state:'done',text:'Finished',detail:'Inserted',debug_retention:false});
  assert.equal(app.element('record').disabled, false);
  assert.equal(app.element('debug').hidden, true);
});
test('pairing secrets are cleared after successful native save', async () => {
  const app = ui();
  app.element('url').value = 'http://localhost:7899';
  app.element('hotkey').value = 'RightCtrl'; app.element('mode').value = 'Hold';
  app.element('pairing').value = 'chirp://pair?token=test'; app.element('token').value = 'test';
  await app.element('settings').onsubmit({preventDefault(){}});
  assert.equal(app.calls[0][0], 'save_preferences');
  assert.equal(app.calls[0][1].pairingLink, 'chirp://pair?token=test');
  assert.equal(app.element('pairing').value, ''); assert.equal(app.element('token').value, '');
});
test('shortcut status remains separate from the current dictation', () => {
  const app = ui();
  app.update({state:'listening',text:'Synthetic speech',detail:'Listening',debug_retention:false});
  app.shortcut({available:false,requested:false,detail:'Portal unavailable — use Record'});
  assert.equal(app.element('hud-text').textContent, 'Synthetic speech');
  assert.equal(app.element('status').textContent, 'Listening');
  assert.equal(app.element('shortcut-status').textContent, 'Portal unavailable — use Record');
});

test('finished and error HUD states offer Dismiss; listening offers Cancel', () => {
  const app = ui();
  for (const state of ['done', 'error']) {
    app.update({state, text:'Synthetic example', detail:state});
    assert.equal(app.element('hud-cancel').textContent, 'Dismiss');
    assert.equal(app.element('hud-stop').disabled, true);
  }
  app.update({state:'listening', text:'', detail:'Listening…'});
  assert.equal(app.element('hud-cancel').textContent, 'Cancel');
});

test('Use raw is offered only for a final with an original, and invokes the native copy path', async () => {
  const app = ui();
  app.update({state:'done', text:'Polished.', detail:'Inserted', raw_available:true});
  assert.equal(app.element('use-raw').hidden, false);
  assert.equal(app.element('raw-help').hidden, false);
  await app.element('use-raw').onclick();
  assert.equal(app.calls.at(-1)[0], 'dictation_use_raw');
  app.update({state:'done', text:'original', detail:'Original copied', raw_available:false});
  assert.equal(app.element('use-raw').hidden, true);
  app.update({state:'listening', text:'partial', detail:'Listening…'});
  assert.equal(app.element('use-raw').hidden, true);
  assert.equal(app.element('result-copy').hidden, true);
});

test('new privacy and commands preferences are saved with explicit choices', async () => {
  const app = ui();
  app.element('spoken-commands').checked = true;
  app.element('history-enabled').checked = false;
  app.element('history-days').value = '30';
  await app.element('settings').onsubmit({preventDefault(){}});
  const settings = app.calls.find(([name]) => name === 'save_preferences')[1].settings;
  assert.equal(settings.spoken_commands, true);
  assert.equal(settings.history_enabled, false);
  assert.equal(settings.history_days, 30);
});

test('history searches originals, safely renders text, copies and deletes only the selected entry', async () => {
  const app = ui({hud:false,history:[
    {id:'one',time:1,text:'<img src=x onerror=alert(1)>',raw:'Original garden words'},
    {id:'two',time:2,text:'Library books',raw:null},
  ]});
  await new Promise(setImmediate);
  assert.equal(app.element('history-list').children.length, 2);
  assert.equal(app.element('history-list').children[0].children[1].textContent, '<img src=x onerror=alert(1)>');
  app.element('history-search').value = 'GARDEN';
  app.element('history-search').oninput();
  const rows = app.element('history-list').children;
  assert.equal(rows.length, 1);
  const actions = rows[0].children[2].children;
  await actions[1].onclick();
  assert.equal(app.calls.at(-1)[0], 'history_copy');
  assert.equal(app.calls.at(-1)[1].id, 'one');
  assert.equal(app.calls.at(-1)[1].original, true);
  await actions[2].onclick();
  assert.equal(app.element('history-list').children.length, 0);
  assert.match(app.element('history-status').textContent, /No results for “GARDEN”/);
  app.element('history-search').value = ''; app.element('history-search').oninput();
  assert.equal(app.element('history-list').children.length, 1);
});

test('history errors survive refresh, and deleting all waits for the confirmation action', async () => {
  const app = ui({hud:false,history:[{id:'one',time:1,text:'Synthetic',raw:null}]});
  await new Promise(setImmediate);
  app.event('history-error','Unlock your system credential store.');
  app.event('history-changed');
  await new Promise(setImmediate);
  assert.match(app.element('history-warning').textContent, /not saved/);
  app.element('history-delete-all').onclick();
  assert.equal(app.element('history-confirm').open, true);
  assert.equal(app.calls.some(([name]) => name === 'history_clear'), false);
  await app.element('history-confirm-delete').onclick();
  assert.equal(app.element('history-list').children.length, 0);
  assert.equal(app.element('history-warning').textContent, '');
});
