/* Native storage and transport own the data. This view never writes browser storage. */
'use strict';
(() => {
  if (new URLSearchParams(location.search).has('hud')) return;
  const { invoke } = window.__TAURI__.core;
  const { listen } = window.__TAURI__.event;
  const el = id => document.getElementById(id);
  let note = null, active = null, trash = false, revision = 0, savedRevision = 0;
  let titleDirty = false, saving = null, debounce, selectedGeneration = 0, listGeneration = 0, deletedId = null;
  let recordStarted = 0, recordOffset = 0, stopping = false;
  const frozenPreviews = new Map();
  const duration = ms => `${Math.floor(ms / 60000)}:${String(Math.floor(ms / 1000) % 60).padStart(2, '0')}`;
  const message = text => { el('notes-message').textContent = text; };
  const dirty = () => revision !== savedRevision;
  const tabs = ['show-notes', 'show-dictation'];
  function showView(notes) {
    el('notes-view').hidden = !notes; el('dictation-view').hidden = notes;
    for (const [index, id] of tabs.entries()) {
      const selected = notes === (index === 0), tab = el(id);
      tab.setAttribute('aria-selected', String(selected));
      tab.tabIndex = selected ? 0 : -1;
      tab.classList.toggle('quiet', !selected);
    }
  }
  function showNotes() { showView(true); }
  for (const [index, id] of tabs.entries()) {
    el(id).onclick = () => showView(index === 0);
    el(id).onkeydown = event => {
      let next;
      if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') next = 1 - index;
      else if (event.key === 'Home') next = 0;
      else if (event.key === 'End') next = 1;
      else return;
      event.preventDefault(); showView(next === 0); el(tabs[next]).focus();
    };
  }
  function appendPreservingCursor(suffix) {
    const editor = el('note-body'), start = editor.selectionStart, end = editor.selectionEnd, scroll = editor.scrollTop;
    editor.setRangeText(suffix, editor.value.length, editor.value.length, 'preserve');
    editor.setSelectionRange(start, end); editor.scrollTop = scroll;
  }
  async function flush() {
    clearTimeout(debounce);
    if (saving) { await saving; if (dirty()) return flush(); return; }
    saving = (async () => {
      while (note && dirty()) {
        const current = revision, text = el('note-body').value, title = titleDirty ? el('note-title').value : null;
        el('note-save-state').textContent = 'Saving…';
        const result = await invoke('notes_edit', { id: note.id, version: note.body_version, body: text, title });
        const suffix = result.body.startsWith(text) ? result.body.slice(text.length) : '';
        if (suffix) appendPreservingCursor(suffix);
        note = result; savedRevision = current;
        if (revision === current) titleDirty = false;
        el('note-save-state').textContent = dirty() ? 'Saving…' : 'Saved on this computer';
      }
    })();
    try { await saving; } catch (error) { el('note-save-state').textContent = `Not saved: ${String(error)}`; throw error; }
    finally { saving = null; }
    await refreshList();
  }
  function edited(title) {
    revision++; if (title) titleDirty = true;
    el('note-save-state').textContent = 'Saving…';
    clearTimeout(debounce); debounce = setTimeout(() => flush().catch(message), 300);
  }
  el('note-body').oninput = () => edited(false);
  el('note-title').oninput = () => edited(true);
  function highlighted(container, text, query) {
    if (!query) { container.textContent = text; return; }
    const i = text.toLowerCase().indexOf(query.toLowerCase());
    if (i < 0) { container.textContent = text; return; }
    container.append(document.createTextNode(text.slice(0, i)));
    const mark = document.createElement('mark'); mark.textContent = text.slice(i, i + query.length); container.append(mark, document.createTextNode(text.slice(i + query.length)));
  }
  function group(entry) {
    if (entry.recording) return 'Recording';
    const today = new Date(); today.setHours(0, 0, 0, 0);
    const days = Math.floor((today.getTime() - new Date(entry.updated_at).setHours(0, 0, 0, 0)) / 86400000);
    return days <= 0 ? 'Today' : days === 1 ? 'Yesterday' : days < 7 ? 'Previous 7 days' : days < 30 ? 'Previous 30 days' : new Date(entry.updated_at).toLocaleDateString(undefined, { month: 'long', year: 'numeric' });
  }
  async function refreshList() {
    const generation = ++listGeneration, query = el('notes-search').value;
    const result = await invoke('notes_list', { query, trash });
    if (generation !== listGeneration) return;
    if (active !== result.active) {
      recordStarted = Date.now();
      recordOffset = result.entries.find(e => e.id === result.active)?.duration_ms || 0;
      frozenPreviews.clear();
    }
    active = result.active;
    document.body.classList.toggle('notes-recording', !!active);
    el('jump-recording').hidden = !active;
    const entries = result.entries;
    if (result.warnings) message(`${result.warnings} unreadable note file(s) were kept. Other notes are available.`);
    el('note-list').replaceChildren();
    el('notes-empty').hidden = entries.length > 0;
    el('notes-empty').textContent = query ? `No results for “${query}”` : trash ? 'Recently Deleted is empty.' : 'Your notes will live here. Create a note or record to begin.';
    let previous = '';
    for (const entry of entries) {
      const heading = group(entry);
      if (heading !== previous) { const h = document.createElement('h3'); h.textContent = heading; el('note-list').append(h); previous = heading; }
      const row = document.createElement('button'); row.className = 'note-row'; row.setAttribute('aria-current', String(note?.id === entry.id));
      const title = document.createElement('strong'); highlighted(title, entry.title, query);
      const snippet = document.createElement('span'); snippet.className = 'note-snippet';
      if (entry.recording && !frozenPreviews.has(entry.id)) frozenPreviews.set(entry.id, entry.snippet);
      highlighted(snippet, entry.recording ? frozenPreviews.get(entry.id) : entry.snippet, query);
      if (entry.recording) {
        const ripple = document.createElement('span'); ripple.className = 'ripple'; ripple.setAttribute('aria-hidden', 'true');
        for (let i = 0; i < 3; i++) ripple.append(document.createElement('i'));
        const glyph = document.createElement('img'); glyph.src = 'assets/glyph.png'; glyph.alt = ''; ripple.append(glyph); row.append(ripple);
      }
      const meta = document.createElement('small'); meta.textContent = `${new Date(entry.updated_at).toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' })} · ${duration(entry.duration_ms)} · ${entry.todos} open to-dos${entry.recovered ? ' · Recovered' : ''}${entry.paused ? ' · Paused' : ''}`;
      row.append(title, snippet, meta); row.onclick = () => select(entry.id).catch(message); el('note-list').append(row);
      if (entry.id === active) el('jump-recording').textContent = `Recording · ${entry.title} · ${duration(entry.duration_ms)}`;
    }
    if (active && !entries.some(e => e.id === active)) el('jump-recording').textContent = 'Jump to recording';
    controls();
  }
  function controls() {
    if (!note) return;
    const recording = note.id === active, deleted = note.deleted_at !== null;
    el('note-record').hidden = deleted || recording;
    el('note-record').disabled = stopping;
    el('note-record').textContent = active && active !== note.id ? 'Stop current and record here' : note.paused ? 'Resume' : note.segments.length ? 'Continue recording' : 'Record';
    el('note-pause').hidden = !recording; el('note-stop').hidden = !recording && !note.paused;
    el('note-pause').disabled = stopping; el('note-stop').disabled = stopping;
    el('note-stop').textContent = stopping ? 'Finishing…' : 'Stop';
    el('note-delete').hidden = deleted; el('note-delete').disabled = recording || note.paused;
    el('note-restore').hidden = !deleted;
    el('note-body').readOnly = deleted; el('note-title').readOnly = deleted;
    el('note-organize').disabled = recording || note.paused || deleted;
    el('note-undo').hidden = !note.organize_undo || deleted;
  }
  function draw(result, initial = false) {
    const before = note; note = result;
    if (initial) {
      el('note-body').value = result.body; el('note-title').value = result.title;
      revision = savedRevision = 0; titleDirty = false; el('note-save-state').textContent = 'Saved on this computer';
    } else if (before && result.body !== before.body) {
      if (result.body.startsWith(before.body) && el('note-body').value === before.body) appendPreservingCursor(result.body.slice(before.body.length));
      else el('note-body').value = result.body;
      if (!titleDirty) el('note-title').value = result.title;
    }
    el('note-editor').hidden = false;
    el('note-meta').textContent = `${duration(result.duration_ms)} · ${result.recovered ? 'Recovered · ' : ''}${result.paused ? 'Paused · ' : ''}${new Date(result.created_at).toLocaleString()}`;
    el('note-segments').replaceChildren();
    for (const segment of result.segments) {
      for (const boundary of result.boundaries.filter(b => b.at_ms === segment.start_ms)) {
        const divider = document.createElement('p'); divider.className = 'muted'; divider.textContent = `Continued · ${new Date(boundary.created_at).toLocaleString()}`; el('note-segments').append(divider);
      }
      const part = document.createElement('div'); part.className = 'segment';
      const time = document.createElement('small'); time.textContent = `${duration(segment.start_ms)}${segment.notes_state === 'pending' ? ' · Smart notes pending' : ''}`;
      const text = document.createElement('p'); text.textContent = segment.text; part.append(time, text); el('note-segments').append(part);
    }
    if (result.last_error) message(result.last_error);
    controls();
  }
  async function select(id) {
    await flush();
    if (note && note.id !== id) await invoke('notes_discard_blank', { id: note.id });
    const generation = ++selectedGeneration;
    el('note-editor').inert = true;
    try {
      const result = await invoke('notes_get', { id });
      if (generation !== selectedGeneration) return;
      message(''); draw(result, true); await refreshList();
    } finally { if (generation === selectedGeneration) el('note-editor').inert = false; }
  }
  async function reloadSelected(id) {
    if (note?.id !== id || dirty() || saving) return;
    const generation = selectedGeneration;
    const result = await invoke('notes_get', { id });
    if (generation === selectedGeneration && note?.id === id && !dirty() && !saving && result.body_version >= note.body_version) draw(result);
  }
  const run = fn => async () => { try { await fn(); } catch (error) { message(String(error)); } };
  el('new-note').onclick = run(async () => { await flush(); const result = await invoke('notes_create'); trash = false; el('show-trash').textContent = 'Recently Deleted'; el('empty-trash').hidden = true; await select(result.id); showNotes(); el('note-body').focus(); });
  el('notes-search').oninput = () => refreshList().catch(message);
  el('jump-recording').onclick = run(async () => { if (active) { showNotes(); await select(active); } });
  el('show-trash').onclick = run(async () => { await flush(); trash = !trash; el('show-trash').textContent = trash ? 'All notes' : 'Recently Deleted'; el('empty-trash').hidden = !trash; await refreshList(); });
  el('note-record').onclick = run(async () => { const id = note.id; await flush(); if (active && active !== id) await invoke('notes_stop', { pause: false, id: active }); await invoke('notes_record', { id, structure: el('note-structure').checked }); message('Recording… completed segments save automatically.'); await refreshList(); await reloadSelected(note.id); });
  async function stop(pause) {
    stopping = true; controls(); message('Stopping microphone and finishing queued audio…');
    try { await invoke('notes_stop', { pause, id: note?.id || null }); el('note-live').textContent = ''; message(pause ? 'Paused. Resume to continue this capture.' : 'Recording stopped. Pending smart notes will finish in this note.'); }
    finally { stopping = false; await refreshList(); if (note) await reloadSelected(note.id); }
  }
  el('note-pause').onclick = run(() => stop(true)); el('note-stop').onclick = run(() => stop(false));
  el('note-delete').onclick = run(async () => { await flush(); deletedId = note.id; await invoke('notes_trash', { id: deletedId, deleted: true }); note = null; el('note-editor').hidden = true; el('note-deleted').hidden = false; await refreshList(); });
  el('note-undo-delete').onclick = run(async () => { if (!deletedId) return; await invoke('notes_trash', { id: deletedId, deleted: false }); el('note-deleted').hidden = true; await select(deletedId); deletedId = null; });
  el('note-restore').onclick = run(async () => { await invoke('notes_trash', { id: note.id, deleted: false }); trash = false; el('show-trash').textContent = 'Recently Deleted'; el('empty-trash').hidden = true; await reloadSelected(note.id); await refreshList(); });
  el('empty-trash').onclick = () => el('trash-confirm').showModal();
  el('trash-confirm-delete').onclick = run(async () => { await invoke('notes_empty_trash'); if (note?.deleted_at) { note = null; el('note-editor').hidden = true; } await refreshList(); });
  el('note-organize').onclick = run(async () => {
    await flush(); const id = note.id, requestedRevision = revision; message('Organizing… you can keep editing.');
    const proposal = await invoke('notes_organize', { id });
    if (note?.id !== id || revision !== requestedRevision || dirty()) { message('Note changed while organizing. Your edits were kept.'); return; }
    saving = (async () => {
      const applied = await invoke('notes_apply_organize', { id, version: proposal.version, markdown: proposal.markdown });
      if (note?.id !== id) return;
      if (revision === requestedRevision && !dirty()) draw(applied);
      else note = applied; // Keep edits made while the atomic apply was in flight.
    })();
    try { await saving; } finally { saving = null; }
    if (dirty()) { await flush(); message('Your newer edits were kept.'); }
    else message('Organized. Undo is available until your next edit.');
    await refreshList();
  });
  el('note-undo').onclick = run(async () => { await flush(); const id = note.id; await invoke('notes_undo_organize', { id }); await reloadSelected(id); });
  el('note-export').onclick = run(async () => { await flush(); if (await invoke('notes_export', { id: note.id })) message('Markdown exported. Your library note still saves automatically.'); });
  listen('notes-changed', event => { refreshList().catch(message); reloadSelected(event.payload).catch(message); });
  listen('notes-status', event => { if (!event.payload.id || event.payload.id === note?.id) { el('main').inert = false; message(event.payload.detail); } });
  listen('notes-live', event => { if (event.payload.id === note?.id) { el('note-live').textContent = event.payload.update.text || event.payload.update.detail; if (event.payload.update.debug_retention) message('Server debug retention is enabled. The server may keep this recording.'); } });
  listen('notes-save-for-quit', async event => {
    let ok = true; el('main').inert = true; message('Saving Notes before quitting…');
    try { await flush(); } catch (error) { ok = false; el('main').inert = false; message(String(error)); }
    await invoke('notes_flush_complete', { request: event.payload, ok });
  });
  listen('open-notes', showNotes);
  setInterval(() => { if (active && note?.id === active && !stopping) el('jump-recording').textContent = `Recording · ${note.title} · ${duration(recordOffset + Date.now() - recordStarted)}`; }, 1000);
  refreshList().catch(message);
})();
