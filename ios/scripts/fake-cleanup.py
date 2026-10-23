"""Deterministic OpenAI-compatible stand-in: drops um/uh fillers so clean-up visibly changes text. Live Notes requests
("Notes JSON: ") get the cleaned transcript as one bullet (structure) or the notes back unchanged (reorganize)."""
import json, re, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        user = body["messages"][-1]["content"]
        notes = json.loads(user.split("Notes JSON: ", 1)[1]) if user.startswith("Notes JSON: ") else None
        raw = json.loads(user.split("Transcript JSON: ", 1)[1]) if "Transcript JSON: " in user else user
        if notes is not None:
            raw = notes.get("transcript", notes.get("notes", ""))
        text = re.sub(r"\b(?:um|uh)\b[,.]?\s*", "", raw, flags=re.I).strip()
        text = text[:1].upper() + text[1:]
        if notes is not None:
            text = notes["notes"] if "notes" in notes else "- " + " ".join(text.split())
        out = json.dumps({"choices": [{"message": {"role": "assistant", "content": text}, "finish_reason": "stop"}]}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)

ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
