#!/usr/bin/env python3
"""Serve actual desktop UI with synthetic in-memory native fixtures for browser review.

This never connects to a Chirp server, captures audio, reads preferences or writes history.
Run from any directory; --port 0 chooses a free loopback port. Refresh resets all fixtures.
"""
import argparse
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

UI = Path(__file__).resolve().parent.parent / "ui"
MOCK = r"""
<script>
'use strict';
const callbacks = new Map();
window.reviewCalls = []; window.reviewErrors = [];
window.addEventListener('error', e => window.reviewErrors.push(e.message));
window.addEventListener('unhandledrejection', e => window.reviewErrors.push(String(e.reason)));
const settings = {url:'http://127.0.0.1:7899',hotkey:'RightCtrl',mode:'Hold',correction:true,
  spoken_commands:true,history_enabled:true,history_days:7,portal_enabled:false,portal_shortcut:'CTRL+ALT+space'};
let entries = [
  {id:'synthetic-one',time:1793097600000,text:'The garden opens at nine. Bring a notebook.',raw:'the garden opens at nine bring a notebook'},
  {id:'synthetic-two',time:1793094000000,text:'Pick up the library books on Friday.',raw:null},
  {id:'synthetic-three',time:1793007600000,text:'A quiet morning by the pond.\n\n',raw:null}
];
const completed = () => ({state:'done',text:'The garden opens at nine. Bring a notebook.',detail:'Inserted',raw_available:true});
window.reviewEmit = (name, payload) => { for (const cb of callbacks.get(name) || []) cb({payload}); };
window.__TAURI__ = {
  event:{listen:async (name,cb) => {if (!callbacks.has(name)) callbacks.set(name,[]); callbacks.get(name).push(cb); return () => {}; }},
  core:{invoke:async (command,args) => {
    window.reviewCalls.push({command,args});
    switch(command) {
      case 'preferences': return {settings,paired:true,capabilities:{session:'x11',detail:'Hold the selected right modifier alone to dictate. Chords cancel dictation.'},shortcut:{available:true,requested:false,detail:'Shortcut ready'}};
      case 'save_preferences': Object.assign(settings,args.settings); return;
      case 'history_list': return structuredClone(entries);
      case 'history_copy': case 'dictation_copy': return;
      case 'history_delete': entries = entries.filter(e => e.id !== args.id); return;
      case 'history_clear': entries = []; return;
      case 'notes_list': return {entries:[],active:null,warnings:0};
      case 'dictate_start': window.reviewEmit('dictation',{state:'listening',text:'The garden opens at nine',detail:'Listening…'}); return;
      case 'dictate_stop': window.reviewEmit('dictation',completed()); return;
      case 'dictate_cancel': window.reviewEmit('dictation',{state:'idle',text:'',detail:'Cancelled'}); return;
      case 'dictation_use_raw': window.reviewEmit('dictation',{state:'done',text:'the garden opens at nine bring a notebook',detail:'Original copied — select the previous result in your app and paste',raw_available:false}); return;
      default: throw new Error('Unsupported review command: '+command);
    }
  }}
};
</script>
"""

class Review(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(UI), **kwargs)

    def do_GET(self):
        if self.path.split("?")[0] in ("/", "/index.html"):
            html = (UI / "index.html").read_text().replace('<script src="app.js"', MOCK + '<script src="app.js"')
            body = html.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            super().do_GET()

    def log_message(self, *_args):
        pass

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Review)
    print(f"Desktop review fixture: http://127.0.0.1:{server.server_port}", flush=True)
    server.serve_forever()
