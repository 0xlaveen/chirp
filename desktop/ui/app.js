/* Local UI only: no microphone, network, credentials in storage, or transcript logs. */
'use strict';
const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;
const $ = id => document.getElementById(id);
const isHud = new URLSearchParams(location.search).has('hud');
if (isHud) { $('main').hidden = true; $('hud').hidden = false; document.body.classList.add('overlay'); }
let session = '';
let portalTrigger = 'CTRL+ALT+space';
let styleSource = 'builtin';
const keyLabel = key => ({ RightAlt: 'Right Alt', RightCtrl: 'Right Ctrl', RightOption: 'Right Option' }[key] || key);
function render(update) {
  $('status').textContent = update.detail;
  $('transcript').textContent = update.text;
  $('hud-status').textContent = update.detail;
  $('hud-text').textContent = update.text;
  $('use-raw').hidden = !update.raw_available;
  $('raw-help').hidden = !update.raw_available;
  $('result-copy').hidden = !['done', 'error'].includes(update.state) || !update.text;
  $('debug').hidden = !update.debug_retention;
  document.body.classList.toggle('listening', update.state === 'listening');
  const active = ['connecting', 'listening', 'processing'].includes(update.state);
  $('record').disabled = active;
  $('stop').disabled = !active;
  $('hud-stop').disabled = !active;
  $('hud-cancel').textContent = active ? 'Cancel' : 'Dismiss';
}
async function action(command) {
  try { await invoke(command); }
  catch (error) { render({ state: 'error', detail: String(error), text: '' }); }
}
$('use-raw').onclick = async () => {
  try { await invoke('dictation_use_raw'); }
  catch (error) { $('status').textContent = String(error); }
};
$('result-copy').onclick = async () => {
  try { await invoke('dictation_copy'); $('status').textContent = 'Copied'; }
  catch (error) { $('status').textContent = String(error); }
};
$('record').onclick = () => action('dictate_start');
$('stop').onclick = $('hud-stop').onclick = () => action('dictate_stop');
$('cancel').onclick = $('hud-cancel').onclick = () => action('dictate_cancel');
document.addEventListener('keydown', event => { if (event.key === 'Escape') action('dictate_cancel'); });
$('settings').onsubmit = async event => {
  event.preventDefault(); $('saved').textContent = 'Saving…';
  try {
    await invoke('save_preferences', {
      settings: { url: $('url').value, hotkey: $('hotkey').value, mode: $('mode').value, correction: $('correction').checked,
        correction_style: $('style').value || 'default', auto_enter: $('auto-enter').value || 'off',
        spoken_commands: $('spoken-commands').checked, history_enabled: $('history-enabled').checked, history_days: Number($('history-days').value),
        portal_enabled: $('portal-enabled').checked, portal_shortcut: portalTrigger },
      token: $('token').value || null, pairingLink: $('pairing').value || null,
    });
    $('token').value = ''; $('pairing').value = ''; $('saved').textContent = 'Saved';
    await load();
    await loadHistory();
  } catch (error) { $('saved').textContent = String(error); }
};
async function load() {
  const { settings, capabilities, paired, shortcut } = await invoke('preferences');
  session = capabilities.session || '';
  const wayland = session === 'wayland';
  $('portal-settings').hidden = !wayland;
  $('native-key').hidden = wayland;
  $('native-shortcut-hint').hidden = wayland;
  $('portal-enabled').checked = !!settings.portal_enabled;
  portalTrigger = settings.portal_shortcut || 'CTRL+ALT+space';
  $('url').value = settings.url; $('hotkey').value = settings.hotkey;
  $('spoken-commands').checked = !!settings.spoken_commands;
  $('history-enabled').checked = settings.history_enabled !== false;
  $('history-days').value = String(settings.history_days || 7);
  $('mode').value = settings.mode; $('correction').checked = settings.correction;
  $('auto-enter').value = settings.auto_enter || 'off';
  await loadStyles(settings.correction_style || 'default');
  await refreshConnection();
  $('shortcut-help').textContent = wayland ? 'Use Record or the shortcut approved by your desktop. Your selected hold or toggle mode applies.' : settings.mode === 'Hold' ? `Hold ${keyLabel(settings.hotkey)} to talk. Release to insert.` : `Tap ${keyLabel(settings.hotkey)} to start and stop.`;
  $('capabilities').textContent = capabilities.detail;
  $('status').textContent = paired ? 'Ready to dictate' : 'Pair with your computer to begin.';
  $('stop').disabled = true;
  if (shortcut) renderShortcut(shortcut);
}
function styleOptions(select) {
  return select.children ? [...select.children] : [...select.options];
}
function describeStyle() {
  const select = $('style');
  const chosen = styleOptions(select).find(option => option.value === select.value);
  const description = chosen ? chosen.getAttribute('data-description') : '';
  const rewrites = chosen && chosen.getAttribute('data-rewrites') === 'true' ? ' May restructure your text.' : '';
  const from = styleSource === 'server' ? ' Loaded from your computer.' : ' Built-in styles until your computer answers.';
  $('style-help').textContent = `${description || 'Clean-up uses the selected style.'}${rewrites}${from}`;
}
async function loadStyles(selected) {
  const payload = await invoke('cleanup_styles');
  styleSource = payload.source === 'server' ? 'server' : 'builtin';
  const select = $('style');
  const current = selected || select.value || 'default';
  select.replaceChildren();
  for (const style of payload.styles) {
    const option = document.createElement('option');
    option.value = style.id;
    option.textContent = style.name;
    option.setAttribute('data-description', style.description || '');
    option.setAttribute('data-rewrites', style.rewrites ? 'true' : 'false');
    select.append(option);
  }
  if (!styleOptions(select).some(option => option.value === current)) {
    const option = document.createElement('option');
    option.value = current;
    option.textContent = current;
    option.setAttribute('data-description', '');
    option.setAttribute('data-rewrites', 'false');
    select.append(option);
  }
  select.value = current;
  describeStyle();
}
function renderConnection(status) {
  const label = status && status.label ? status.label : 'Computer offline';
  $('connection-label').textContent = label;
  $('connection-chip').classList.toggle('connected', !!(status && status.state === 'connected'));
  $('connection-chip').setAttribute('aria-label', `Connection: ${label}. Open connection settings`);
}
async function refreshConnection() {
  renderConnection({ state: 'connecting', label: 'Connecting…' });
  try { renderConnection(await invoke('connection_status')); }
  catch { renderConnection({ state: 'offline', label: 'Computer offline' }); }
}
$('style').onchange = () => describeStyle();
$('refresh-styles').onclick = async () => {
  try { await loadStyles($('style').value); }
  catch (error) { $('style-help').textContent = String(error); }
};
$('connection-chip').onclick = () => {
  const open = $('show-dictation').onclick;
  if (open) open();
  $('url').focus();
};
function renderShortcut(status) {
  $('shortcut-status').textContent = status.detail;
  if (session === 'wayland') $('portal-enabled').checked = status.requested;
}
listen('dictation', event => render(event.payload));
listen('shortcut-status', event => renderShortcut(event.payload));
if (!isHud) load().catch(error => { $('status').textContent = String(error); });

// History never enters browser storage. Search works over this bounded, decrypted in-memory view.
let historyEntries = [], historyGeneration = 0;
function showHistory() {
  const query = $('history-search').value.trim().toLocaleLowerCase();
  const entries = historyEntries.filter(entry => `${entry.text} ${entry.raw || ''}`.toLocaleLowerCase().includes(query));
  $('history-list').replaceChildren();
  $('history-status').textContent = entries.length ? `${entries.length} dictation${entries.length === 1 ? '' : 's'}` : query ? `No results for “${$('history-search').value}”` : 'Your dictations will appear here.';
  for (const entry of entries) {
    const row = document.createElement('article'); row.className = 'history-entry';
    const meta = document.createElement('p'); meta.className = 'muted';
    meta.textContent = new Date(entry.time).toLocaleString();
    if (entry.raw) {
      const chip = document.createElement('span'); chip.className = 'polished-chip'; chip.textContent = 'Polished'; meta.append(chip);
    }
    const text = document.createElement('p'); text.className = 'history-text'; text.textContent = entry.text;
    const actions = document.createElement('div'); actions.className = 'actions';
    const button = (label, command, args) => {
      const control = document.createElement('button'); control.className = 'quiet'; control.textContent = label;
      control.onclick = async () => {
        try {
          await invoke(command, {id: entry.id, ...args});
          if (command === 'history_delete') await loadHistory();
          else $('history-status').textContent = label === 'Copy original' ? 'Original copied' : 'Copied';
        } catch (error) { $('history-status').textContent = String(error); }
      };
      actions.append(control);
    };
    button('Copy', 'history_copy', {original:false});
    if (entry.raw) button('Copy original', 'history_copy', {original:true});
    button('Delete', 'history_delete', {});
    row.append(meta, text, actions); $('history-list').append(row);
  }
}
async function loadHistory() {
  const generation = ++historyGeneration;
  try {
    const entries = await invoke('history_list');
    if (generation !== historyGeneration) return;
    historyEntries = entries; showHistory();
  } catch (error) {
    if (generation !== historyGeneration) return;
    historyEntries = []; $('history-list').replaceChildren(); $('history-status').textContent = String(error);
  }
}
$('history-search').oninput = showHistory;
$('history-delete-all').onclick = () => $('history-confirm').showModal();
$('history-confirm-delete').onclick = async () => {
  try { await invoke('history_clear'); $('history-warning').textContent = ''; await loadHistory(); }
  catch (error) { $('history-status').textContent = String(error); }
};
listen('history-changed', () => { if (!isHud) loadHistory(); });
listen('history-error', event => { if (!isHud) $('history-warning').textContent = `Dictation history was not saved. ${event.payload}`; });
if (!isHud) loadHistory();
