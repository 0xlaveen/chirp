#!/usr/bin/env python3
"""Disposable real-model server with content-free stop-order observations. Port 7899 only."""
import argparse
import asyncio
import json
from pathlib import Path
import uvicorn
from chirp_server.app import create_app
from chirp_server.config import Settings

parser = argparse.ArgumentParser()
parser.add_argument('--model-dir', type=Path, required=True)
parser.add_argument('--metadata', type=Path, required=True)
parser.add_argument('--cert')
parser.add_argument('--key')
# Seconds each `ready` is held back: the Notes check makes it long enough that audio waits past 5 s before Ready.
parser.add_argument('--ready-delay', type=float, default=2)
args = parser.parse_args()
settings = Settings.read()
settings.model_dir = args.model_dir
app = create_app(settings)

notes = {}


async def observed(scope, receive, send):
    if scope['type'] == 'http' and scope['path'].startswith('/v1/notes/'):
        # Content-free: only the endpoint and its status, for the Notes check.
        async def answer(event):
            if event['type'] == 'http.response.start':
                notes.setdefault(scope['path'].rsplit('/', 1)[-1], []).append(event['status'])
                args.metadata.with_name('notes.json').write_text(json.dumps(notes))
            await send(event)
        return await app(scope, receive, answer)
    state = {'frames': 0, 'partials': 0, 'stop': False, 'empty': False, 'correcting': False, 'error': None,
             'correction_requested': False, 'started': False, 'retired': False}
    def save():
        args.metadata.write_text(json.dumps(state))
    async def read():
        event = await receive()
        if event.get('bytes'): state['frames'] += 1
        if event.get('text'):
            control = json.loads(event['text'])
            if control.get('type') == 'start':
                state['started'] = True
                state['correction_requested'] = control.get('correction', False)
                save()
            if control.get('type') == 'stop': state['stop'] = True; save()
        return event
    async def write(event):
        if scope['type'] == 'websocket' and event.get('text'):
            frame = json.loads(event['text'])
            kind = frame.get('type')
            # Makes a native immediate double tap deterministically precede Ready.
            if kind == 'ready': await asyncio.sleep(args.ready_delay)
            if kind == 'partial': state['partials'] += 1
            if kind == 'correcting': state['correcting'] = True
            # Keep the real managed correction transition observable on a slow AVD.
            if kind == 'final' and state['correcting']: await asyncio.sleep(2)
            if kind == 'final': state['empty'] = not frame.get('text', '').strip()
            if kind == 'final' and not state['empty']:
                notes['finals'] = notes.get('finals', 0) + 1
                args.metadata.with_name('notes.json').write_text(json.dumps(notes))
            if kind == 'error': state['error'] = frame.get('code')
            save()
        await send(event)
    try:
        await app(scope, read, write)
    finally:
        if state['started']:
            state['retired'] = True
            save()

uvicorn.run(observed, host='127.0.0.1', port=7899, access_log=False, log_level='critical',
            ssl_certfile=args.cert, ssl_keyfile=args.key)
