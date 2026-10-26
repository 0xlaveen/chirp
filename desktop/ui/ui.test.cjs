const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(__dirname + '/app.js', 'utf8');
function ui() {
  const nodes = new Map(); const callbacks = new Map(); const calls = [];
  const element = id => {
    if (!nodes.has(id)) nodes.set(id, { value:'', textContent:'', checked:false, hidden:false, disabled:false, classList:{add(){},toggle(){}} });
    return nodes.get(id);
  };
  const context = vm.createContext({
    window: { __TAURI__: { core: { invoke: async (command, args) => {
      calls.push([command, args]);
      if (command === 'preferences') return { settings:{url:'http://localhost:7899',hotkey:'RightCtrl',mode:'Hold',correction:false},capabilities:{detail:'X11'},paired:true };
    } }, event:{listen: (name, cb) => { callbacks.set(name, cb); }} } },
    document:{getElementById:element,body:element('body'),addEventListener(){}},
    location:{search:'?hud'}, URLSearchParams,
  });
  vm.runInContext(source, context);
  return { element, calls, update: payload => callbacks.get('dictation')({payload}), shortcut: payload => callbacks.get('shortcut-status')({payload}) };
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
