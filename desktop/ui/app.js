/* Local UI only: no microphone, network, credentials in storage, or transcript logs. */
'use strict';
const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;
const $ = id => document.getElementById(id);
const isHud = new URLSearchParams(location.search).has('hud');
if (isHud) { $('main').hidden = true; $('hud').hidden = false; document.body.classList.add('overlay'); }
let session = '';
let portalTrigger = 'CTRL+ALT+space';
const keyLabel = key => ({ RightAlt: 'Right Alt', RightCtrl: 'Right Ctrl', RightOption: 'Right Option' }[key] || key);
function render(update) {
  $('status').textContent = update.detail;
  $('transcript').textContent = update.text;
  $('hud-status').textContent = update.detail;
  $('hud-text').textContent = update.text;
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
$('record').onclick = () => action('dictate_start');
$('stop').onclick = $('hud-stop').onclick = () => action('dictate_stop');
$('cancel').onclick = $('hud-cancel').onclick = () => action('dictate_cancel');
document.addEventListener('keydown', event => { if (event.key === 'Escape') action('dictate_cancel'); });
$('settings').onsubmit = async event => {
  event.preventDefault(); $('saved').textContent = 'Saving…';
  try {
    await invoke('save_preferences', {
      settings: { url: $('url').value, hotkey: $('hotkey').value, mode: $('mode').value, correction: $('correction').checked,
        portal_enabled: $('portal-enabled').checked, portal_shortcut: portalTrigger },
      token: $('token').value || null, pairingLink: $('pairing').value || null,
    });
    $('token').value = ''; $('pairing').value = ''; $('saved').textContent = 'Saved';
    await load();
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
  $('mode').value = settings.mode; $('correction').checked = settings.correction;
  $('shortcut-help').textContent = wayland ? 'Use Record or the shortcut approved by your desktop. Your selected hold or toggle mode applies.' : settings.mode === 'Hold' ? `Hold ${keyLabel(settings.hotkey)} to talk. Release to insert.` : `Tap ${keyLabel(settings.hotkey)} to start and stop.`;
  $('capabilities').textContent = capabilities.detail;
  $('status').textContent = paired ? 'Ready to dictate' : 'Pair with your computer to begin.';
  $('stop').disabled = true;
  if (shortcut) renderShortcut(shortcut);
}
function renderShortcut(status) {
  $('shortcut-status').textContent = status.detail;
  if (session === 'wayland') $('portal-enabled').checked = status.requested;
}
listen('dictation', event => render(event.payload));
listen('shortcut-status', event => renderShortcut(event.payload));
if (!isHud) load().catch(error => { $('status').textContent = String(error); });
