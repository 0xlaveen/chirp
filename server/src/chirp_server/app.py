"""Frozen v1 HTTP/WS protocol. Logs contain metadata and safe error codes only."""

import asyncio
import base64
import contextlib
import json
import logging
import re
import secrets
import time
from collections import deque
from contextlib import asynccontextmanager
from uuid import uuid4

from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route, WebSocketRoute
from starlette.websockets import WebSocket, WebSocketDisconnect

from . import build, notes, notes_edit
from .activity import FLUSH_SECONDS, Activity
from .audio import MAX_FRAME, MAX_PCM, AudioError, decode_wav, levels, samples, silent
from .cleanup_models import DEFAULT_MODEL, model_spec
from .config import Settings, load_token, persist_keep_loaded, read_keep_loaded
from .correction import CorrectionResult, Corrector
from .devices import Credentials, direct_loopback, encode
from .engine import EngineWorker
from .learned import parse_learned
from .managed_cleanup import ManagedCleanup
from .profiles import LIVE_NOTES_ID, MAX_PROMPT_CHARS
from .retention import Retention
from .speakers import SpeakerLabels
from .voices import (
    DIMENSIONS,
    IMPORTABLE,
    MAX_CLIP_SECONDS,
    VOICE_ID,
    VoiceError,
    clean_name,
    decode,
    match,
)

log = logging.getLogger("chirp")
MAX_CONTEXT_CHARS = 500
SPEAKER_SESSION = re.compile(r"[A-Za-z0-9_-]{16,64}")
MESSAGES = {
    "auth": "Authentication required",
    "busy": "Speech engine busy; retry shortly",
    "too_long": "Maximum utterance is 120 seconds",
    "bad_request": "Invalid correction prompt",
    "bad_audio": "Invalid audio or control frame",
    "engine": "Speech engine unavailable",
    "unsupported": "keep_loaded requires managed correction mode",
    "bad_notes": "Invalid notes request",
    "notes_off": "Notes structuring needs correction enabled on the server",
    "bad_speakers": "Invalid speakers request",
    "forbidden": "Not available to this credential",
    "bad_activity": "Invalid activity request",
    "gone": "This note's speakers are no longer on the server; record a little more, then retry",
    "no_voice": "No saved voice has that id",
    "too_short": "Needs at least 20 seconds of this person's speech",
    "disabled": "Remember voices is off on this server",
    "full": "At most 50 saved voices; forget one first",
    "unavailable": "The speaker model is not downloaded",
    "clip_too_long": "A voice clip is at most 30 seconds",
    "failed": "The speaker model failed",
    "voices_file": "The saved voices file could not be read or written",
}
CLIENTS = {"mac", "android", "ios", "desktop"}
# Saved-voice errors and their HTTP status (issue #247).
VOICE_STATUS = {
    "bad_speakers": 400,
    "gone": 404,
    "no_voice": 404,
    "too_short": 409,
    "disabled": 409,
    "full": 409,
    "unavailable": 409,
    "clip_too_long": 413,
    "failed": 500,
    "voices_file": 500,
}
VOICE_ACTIONS = {
    "remember",
    "import",
    "identify",
    "rename",
    "forget",
    "forget_all",
    "enable",
    "disable",
}
# One clip of PCM16 at 16 kHz, base64; `identify` takes up to MAX_IDENTIFY people.
MAX_CLIP_BYTES = MAX_CLIP_SECONDS * 32000
MAX_IDENTIFY = 8
MAX_VOICES_BODY = MAX_IDENTIFY * (MAX_CLIP_BYTES * 4 // 3 + 256) + 1024


def error(code):
    return {"type": "error", "code": code, "message": MESSAGES[code]}


def authorized(token, value):
    if isinstance(token, Credentials):
        return token.check(value)
    # Comparing UTF-8 bytes also handles malicious non-ASCII credentials safely.
    return isinstance(value, str) and secrets.compare_digest(token.encode(), value.encode())


def device_field(token, value):
    """Authenticated health tells a device its own pairing name; the shared token has none."""
    name = token.name(value) if isinstance(token, Credentials) else None
    return {"device": name} if name else {}


def failure(code):
    """The activity outcome for a clean-up or notes result's `error` (a fixed code, never text)."""
    return (
        "ok" if code is None else code if code in {"rejected", "timeout", "preempted"} else "engine"
    )


def clip_field(value) -> bytes:
    """A base64 PCM16 16 kHz mono clip of at most MAX_CLIP_SECONDS."""
    if not isinstance(value, str):
        raise VoiceError("bad_speakers")
    if len(value) > (MAX_CLIP_BYTES + 2) // 3 * 4:
        raise VoiceError("clip_too_long")
    try:
        pcm = base64.b64decode(value, validate=True)
    except ValueError:
        raise VoiceError("bad_speakers") from None
    if len(pcm) > MAX_CLIP_BYTES:
        raise VoiceError("clip_too_long")
    if len(pcm) % 2:
        raise VoiceError("bad_speakers")
    return pcm


def small_int(value, limit) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= limit


def bearer(headers):
    value = headers.get("authorization", "")
    scheme, _, token = value.partition(" ")
    return token if scheme.lower() == "bearer" else ""


class Utterance:
    def __init__(self, ws, worker, settings, corrector, retention, speakers=None):
        self.ws, self.worker, self.settings = ws, worker, settings
        self.corrector, self.retention = corrector, retention
        self.speakers = speakers
        self.session = uuid4().hex
        self.pcm = bytearray()
        self.started = time.perf_counter()
        self.first_partial = None
        self.stream = None
        self.task = None
        self.changed = asyncio.Event()
        self.stopping = False
        self.offset = 0
        self.seq = 0
        self.correction = False
        self.profile = "default"
        self.instructions = ""
        self.correction_prompt = None
        # Opt-in `start.learned` (#220): the user's own terms and app preferences. Never logged.
        self.learned = None
        self.context = None
        self.leased = False
        self.failure = False
        self.aborted = False
        self.cancelled = False
        self.correcting = None
        self.peak = self.rms = 0.0
        # Opt-in `start.word_timings`: partials, correcting and the final carry `words`.
        self.word_timings = False
        # Opt-in `start.speakers.session`: the final carries `speakers` (Live Notes labels).
        self.speaker_session = None
        self.labelling = None
        # The activity entry for this utterance (metadata only), set by the stream loop.
        self.token = None
        self.disconnected = False

    async def start(self, control):
        if "correction_prompt" in control:
            prompt = control["correction_prompt"]
            if not isinstance(prompt, str) or len(prompt) > MAX_PROMPT_CHARS:
                raise AudioError("bad_request")
            self.correction_prompt = prompt
        self.set_context(control)
        if "learned" in control:
            try:
                self.learned = parse_learned(control["learned"]) or None
            except ValueError:
                raise AudioError("bad_request") from None
        profile = control.get("correction_profile", "default")
        instructions = control.get("correction_instructions", "")
        if (
            not isinstance(profile, str)
            or self.settings.correction.profile(profile) is None
            or not isinstance(instructions, str)
            or len(instructions) > 2000
        ):
            raise AudioError()
        if (
            control.get("sample_rate") != 16000
            or control.get("encoding") != "pcm_s16le"
            or control.get("client") not in CLIENTS
            or not isinstance(control.get("correction", False), bool)
            or not isinstance(control.get("word_timings", False), bool)
        ):
            raise AudioError()
        self.word_timings = control.get("word_timings", False)
        if "speakers" in control:
            labels = control["speakers"]
            if (
                not isinstance(labels, dict)
                or set(labels) != {"session"}
                or not isinstance(labels["session"], str)
                or not SPEAKER_SESSION.fullmatch(labels["session"])
                or self.speakers is None
            ):
                raise AudioError()
            self.speaker_session = labels["session"]
        helper = getattr(self.corrector, "managed", None)
        managed = helper if isinstance(helper, ManagedCleanup) else None
        if control.get("correction", False) and managed is not None:
            # Managed cleanup: begin the cold load while the user is still speaking.
            # This never delays the ack, partials or ASR, and never counts against
            # an utterance's correction timeout; only a final may wait for the load.
            managed.prewarm()
        await asyncio.wait_for(self.worker.lease.acquire(), self.settings.queue_timeout)
        self.leased = True
        self.correction = control.get("correction", False)
        self.profile = profile
        if self.token is not None:
            self.token.profile = profile
        self.instructions = instructions if profile == "custom" else ""
        self.stream = await self.worker.call(self.worker.engine.open_stream)
        await self.ws.send_json(
            {
                "type": "ready",
                "session": self.session,
                "engine": self.worker.engine.name,
                "debug_retention": self.settings.debug_retain,
            }
        )
        self.task = asyncio.create_task(self.partials())

    def set_context(self, control):
        # Optional previous Live Notes segment tail; a value on `stop` replaces the `start` one.
        if "context" in control:
            context = control["context"]
            if not isinstance(context, str) or len(context) > MAX_CONTEXT_CHARS:
                raise AudioError("bad_request")
            self.context = context or None

    def add(self, chunk):
        if len(chunk) >= MAX_FRAME or not chunk or len(chunk) % 2:
            raise AudioError()
        if len(self.pcm) + len(chunk) > MAX_PCM:
            raise AudioError("too_long")
        self.pcm.extend(chunk)
        if len(self.pcm) - self.offset >= 6400:  # 200 ms of new PCM16
            self.changed.set()

    async def partials(self):
        previous = previous_stable = ""
        try:
            while True:
                await self.changed.wait()
                self.changed.clear()
                if self.aborted or self.stopping:
                    return
                end = min(len(self.pcm), self.offset + 64000)
                chunk = samples(bytes(self.pcm[self.offset : end]))
                self.offset = end
                if chunk.size:
                    peak, rms = levels(chunk)
                    self.peak, self.rms = max(self.peak, peak), max(self.rms, rms)
                    # Still feed silence to preserve the model's time/context alignment.
                    partial = await self.worker.call(self.stream.feed, chunk)
                    stable = partial.stable if partial else ""
                    if self.correction and self.settings.correction.enabled:
                        stable = ""
                    if (
                        not self.aborted
                        and not self.stopping
                        and partial
                        and partial.text
                        and (partial.text != previous or stable != previous_stable)
                        and (not silent(chunk) or stable)
                    ):
                        previous, previous_stable = partial.text, stable
                        self.seq += 1
                        elapsed = (time.perf_counter() - self.started) * 1000
                        if self.first_partial is None:
                            self.first_partial = elapsed
                        message = {
                            "type": "partial",
                            "seq": self.seq,
                            "text": partial.text,
                            "stable": stable,
                        }
                        self.add_words(message, partial.words)
                        await self.ws.send_json(message)
                if self.stopping and self.offset == len(self.pcm):
                    return
                if len(self.pcm) - self.offset >= 6400 or (
                    self.stopping and self.offset < len(self.pcm)
                ):
                    self.changed.set()
        except (WebSocketDisconnect, RuntimeError):
            self.failure = True
        except Exception:
            # Never include library exception strings: they may contain user data.
            self.failure = True
            log.warning("code=engine session=%s", self.session)

    def add_words(self, message, words):
        """Attach `words` when the client asked for timings and the engine produced them.
        Without the flag every message is byte-identical to the pre-timings protocol."""
        if self.word_timings and words is not None:
            message["words"] = [word.payload() for word in words]

    def cancel(self):
        """Mark cancelled from the receive loop; also cancels a pending correction request."""
        self.cancelled = True
        if self.correcting is not None:
            self.correcting.cancel()

    def discard(self):
        # Cancelled during finalization: no correction, no retention, no final.
        if self.labelling is not None:
            self.labelling.cancel()
        log.info("session=%s bytes=%d cancelled_during_finalize=1", self.session, len(self.pcm))
        return None

    async def finish(self):
        started = time.perf_counter()
        self.stopping = True
        self.changed.set()
        await self.task
        if self.failure:
            raise RuntimeError("engine")
        if self.cancelled:
            return self.discard()
        if not self.pcm:
            # A tap released before the first audio frame: an empty final, not a protocol error.
            await self.worker.call(self.stream.cancel)
            self.stream = None
            self.release()
            final = await make_final(
                "",
                b"",
                self.first_partial,
                started,
                self.corrector,
                False,
                self.profile,
                self.instructions,
                self.correction_prompt,
                words=() if self.word_timings else None,
            )
            if self.speaker_session:
                final["speakers"] = await self.speakers.label(
                    self.speaker_session, b"", None, "", ""
                )
            return final
        if self.offset < len(self.pcm):
            pending = samples(bytes(self.pcm[self.offset :]))
            buffer = getattr(self.stream, "buffer", self.stream.feed)
            await self.worker.call(buffer, pending)
            if self.cancelled:
                return self.discard()
            self.offset = len(self.pcm)
        transcript = await self.worker.call(self.stream.finish)
        raw, words = transcript.text, transcript.words if self.word_timings else None
        self.stream = None
        self.release()
        if self.cancelled:
            return self.discard()
        if self.speaker_session:
            # Off the engine lease and beside clean-up: labels rarely add to the final's latency.
            labelled = time.perf_counter()
            self.labelling = asyncio.create_task(
                self.speakers.measure(self.speaker_session, bytes(self.pcm))
            )
        enabled = self.correction and self.settings.correction.enabled and bool(raw)
        if enabled:
            self.seq += 1
            message = {"type": "correcting", "seq": self.seq, "raw": raw, "profile": self.profile}
            self.add_words(message, words)
            await self.ws.send_json(message)
        if self.cancelled:
            return self.discard()
        # A cancel racing this task cancels the pending correction request with it.
        self.correcting = asyncio.create_task(
            make_final(
                raw,
                bytes(self.pcm),
                self.first_partial,
                started,
                self.corrector,
                enabled,
                self.profile,
                self.instructions,
                self.correction_prompt,
                words=words,
                context=self.context,
                learned=self.learned,
            )
        )
        try:
            final = await self.correcting
        except asyncio.CancelledError:
            return self.discard()
        finally:
            self.correcting = None
        if self.cancelled:
            return self.discard()
        if self.labelling is not None:
            measured = await self.labelling
            if self.cancelled:
                return self.discard()
            final["speakers"] = self.speakers.payload(
                measured, transcript.words, raw, final["text"], len(self.pcm) / 32000, labelled
            )
        self.retention.save(self.session, bytes(self.pcm), final)
        log.info(
            "session=%s bytes=%d peak=%.5f rms=%.5f finalize_ms=%.1f identity_present=%s",
            self.session,
            len(self.pcm),
            self.peak,
            self.rms,
            final["timings_ms"]["finalize"],
            "tailscale-user-login" in self.ws.headers,
        )
        return final

    def release(self):
        if self.leased:
            self.worker.lease.release()
            self.leased = False

    async def close(self):
        # Let an in-flight feed finish before disposing its thread-owned context.
        if self.labelling is not None and not self.labelling.done():
            self.labelling.cancel()
        self.aborted = True
        self.stopping = True
        self.changed.set()
        if self.task:
            with contextlib.suppress(Exception):
                await self.task
        try:
            if self.stream:
                await self.worker.call(self.stream.cancel)
        finally:
            self.stream = None
            self.pcm.clear()
            self.release()


async def make_final(
    raw,
    pcm,
    first_partial,
    started,
    corrector,
    enabled,
    profile="default",
    instructions="",
    correction_prompt=None,
    words=None,
    context=None,
    learned=None,
):
    finalized = (time.perf_counter() - started) * 1000
    correction_started = time.perf_counter()
    if enabled:
        args = (raw, profile, instructions)
        extra = {"context": context} if context and profile == LIVE_NOTES_ID else {}
        if learned and profile != LIVE_NOTES_ID:
            extra["learned"] = learned
        result = (
            await corrector.process(*args, correction_prompt, **extra)
            if correction_prompt is not None
            else await corrector.process(*args, **extra)
        )
    else:
        result = CorrectionResult(raw)
    final = {
        "type": "final",
        "text": result.text,
        "raw": raw,
        "corrected": result.corrected,
        "correction_error": result.error,
        "timings_ms": {
            "audio": len(pcm) / 32,
            "first_partial": first_partial,
            "finalize": finalized,
            "correction": (time.perf_counter() - correction_started) * 1000 if enabled else 0.0,
        },
    }
    if words is not None:
        # Timings describe `raw`; cleaned text cannot map onto the audio word for word.
        final["words"] = [word.payload() for word in words]
    return final


def create_app(settings=None, engine=None, token=None, corrector=None, speakers=None):
    settings = settings or Settings.read()
    speakers = speakers or SpeakerLabels()
    if engine is None:
        if settings.engine == "sensevoice":
            from .engine.sensevoice import SenseVoice

            engine = SenseVoice(settings.model_dir, settings.sensevoice_num_threads)
            settings.speech_model = "sensevoice-small"
        elif settings.engine == "onnx":
            from .engine.onnx import ParakeetONNX

            engine = ParakeetONNX(
                settings.model_dir,
                settings.finalization,
                intra_op_num_threads=settings.onnx.intra_op_num_threads,
                inter_op_num_threads=settings.onnx.inter_op_num_threads,
                providers=settings.onnx.providers,
            )
        else:
            from .engine.mlx import ParakeetMLX

            engine = ParakeetMLX(
                settings.model_dir, settings.precision, settings.streaming, settings.finalization
            )
    if settings.speech_model != "parakeet-v2" and settings.engine == "mlx":
        engine.name = f"parakeet-mlx:{settings.speech_model}"
    worker = EngineWorker(engine)
    retention = Retention(settings)
    corrector = corrector or Corrector(settings.correction)
    helper = getattr(corrector, "managed", None)
    managed = helper if isinstance(helper, ManagedCleanup) else None
    config = getattr(corrector, "config", settings.correction)
    # A client-persisted override wins over the toml value; server.toml is never rewritten.
    override = read_keep_loaded(settings.state_path)
    keep = {"value": bool(override if override is not None else config.keep_loaded)}
    if managed is not None:
        managed.keep_loaded = keep["value"]
    # A token given here works before lifespan too (tests drive handlers without it).
    credential = Credentials(token, settings.config_dir) if isinstance(token, str) else token
    owner = ""  # the owner token, read in lifespan; only the activity routes accept it
    activity = Activity(
        settings.activity_path,
        settings.activity.keep,
        settings.activity.max_events,
        settings.activity.max_days,
    )
    pending_auth = 0
    structuring = asyncio.Lock()  # at most one structuring pass server-wide

    async def housekeeping():
        while True:
            await asyncio.sleep(3600)
            retention.purge()

    async def saving():
        while True:
            await asyncio.sleep(FLUSH_SECONDS)
            if (data := activity.pending()) is not None:
                try:
                    await asyncio.to_thread(activity.write, data)
                except OSError:
                    activity.dirty = True  # silently; the next round tries again

    def reject(headers):
        """None for an authorized request; otherwise the 401, counted as a refusal."""
        value = bearer(headers)
        if authorized(credential, value):
            return None
        activity.refused(*credential.refusal(value))
        return JSONResponse(error("auth"), status_code=401, headers={"WWW-Authenticate": "Bearer"})

    @asynccontextmanager
    async def lifespan(app):
        nonlocal credential, owner
        if not isinstance(credential, Credentials):
            credential = Credentials(
                credential or load_token(settings.config_dir), settings.config_dir
            )
        owner = load_token(settings.config_dir, "owner-token")
        cleanup = None
        saver = asyncio.create_task(saving())
        try:
            if settings.debug_retain:
                log.warning("DEBUG: recording kept — debug retention is ENABLED")
                retention.purge()
                cleanup = asyncio.create_task(housekeeping())
            await worker.start()
            if managed is not None and keep["value"]:
                # keep_loaded: prewarm during server bring-up; the background load
                # never blocks readiness and never idle-unloads while enabled.
                managed.prewarm()
            yield
        finally:
            saver.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await saver
            activity.flush()
            if cleanup:
                cleanup.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await cleanup
            await worker.close()
            await speakers.close()
            if isinstance(corrector, Corrector):
                await corrector.close()

    async def health(request: Request):
        if not authorized(credential, value := bearer(request.headers)):
            if credential.revoked(value):
                # Only a revoked device token learns more, so its client can re-pair.
                activity.refused(*credential.refusal(value))
                return JSONResponse(
                    error("auth"), status_code=401, headers={"WWW-Authenticate": "Bearer"}
                )
            # Frozen protocol intentionally exposes only liveness without credentials.
            return JSONResponse({"ok": True})
        correction = settings.correction
        return JSONResponse(
            {
                "ok": True,
                "engine": engine.name,
                "speech_model": settings.speech_model,
                "correction_model": correction.model or DEFAULT_MODEL,
                "ready": worker.ready,
                "debug_retention": settings.debug_retain,
                "correction": "available" if correction.enabled else "off",
                "correction_mode": correction.mode,
                "correction_leaves_machine": correction.enabled and correction.leaves_machine,
                "correction_host": correction.host,
                "correction_profiles": [
                    profile.metadata() for profile in correction.resolved_profiles.values()
                ],
                # Effective configured budgets, in seconds; additive to the frozen v1 API.
                "operation_deadlines": {
                    "dictation": correction.timeout,
                    "notes_correction": correction.notes_timeout,
                    "notes_structure": correction.structure_timeout,
                    "notes_reorganize": correction.reorganize_timeout,
                    "notes_edit": correction.reorganize_timeout,
                },
                "correction_keep_loaded": keep["value"],
                **device_field(credential, value),
                "correction_loaded": bool(managed and managed.loaded),
                "notes_structure": True,
                # The hidden `live_notes` style for Live Notes segments exists.
                "notes_correction": True,
                "notes_reorganize": True,
                # `start`/`stop` may carry `context`, the previous segment's tail, for notes.
                "notes_context": True,
                "notes_edit": True,
                # `start.speakers` labels a note's speakers; the model downloads on request.
                "notes_speakers": True,
                # `start.learned` (version 1): the user's own terms and per-app preferences.
                "learned": 1,
                "speakers_model": speakers.health(),
                # Saved voices: `/v1/speakers/voices` and `final.speakers.matches` exist;
                # `speakers_voices` is the server-wide switch and how many are saved.
                "speaker_voices": True,
                "speakers_voices": speakers.library.health(),
                **build.info(),
            }
        )

    async def profiles(request: Request):
        if (refusal := reject(request.headers)) is not None:
            return refusal
        return JSONResponse(
            {
                "profiles": [
                    {
                        **profile.metadata(),
                        "prompt": profile.prompt,
                        "max_prompt_chars": MAX_PROMPT_CHARS,
                    }
                    for profile in settings.correction.resolved_profiles.values()
                ]
            }
        )

    def correction_settings_payload():
        if managed is None:
            return {
                "keep_loaded": keep["value"],
                "loaded": False,
                "loading": False,
                "model": None,
                "memory_mb": None,
                "memory_estimated": False,
                "mode": config.mode,
            }
        try:
            estimate = model_spec(config.model).memory_mb
        except ValueError:
            estimate = None
        memory, estimated = managed.memory(estimate)
        return {
            "keep_loaded": keep["value"],
            "loaded": managed.loaded,
            "loading": managed.loading,
            "model": config.model or DEFAULT_MODEL,
            "memory_mb": memory,
            "memory_estimated": estimated,
            "mode": config.mode,
        }

    async def correction_settings(request: Request):
        if (refusal := reject(request.headers)) is not None:
            return refusal
        if request.method == "GET":
            return JSONResponse(correction_settings_payload())
        try:
            body = json.loads(await request.body())
        except ValueError:
            body = None
        if (
            not isinstance(body, dict)
            or set(body) != {"keep_loaded"}
            or not isinstance(body["keep_loaded"], bool)
        ):
            return JSONResponse(error("bad_request"), status_code=400)
        if managed is None:
            return JSONResponse(error("unsupported"), status_code=409)
        try:
            persist_keep_loaded(settings.state_path, body["keep_loaded"])
        except OSError:
            return JSONResponse(error("engine"), status_code=500)
        keep["value"] = body["keep_loaded"]
        await managed.set_keep_loaded(body["keep_loaded"])
        if body["keep_loaded"]:
            # Load immediately in the background; while on, it never idle-unloads.
            managed.prewarm()
        return JSONResponse(correction_settings_payload())

    async def notes_pass(request: Request, kind, validate, run, respond):
        """Shared by the notes endpoints: stateless, no engine lease, no retention, and one
        notes generation at a time server-wide (`structuring`)."""
        if (refusal := reject(request.headers)) is not None:
            return refusal
        source = credential.source(bearer(request.headers), request.scope)
        with activity.track(source, None, kind) as token:
            if not config.enabled:
                token.outcome = "notes_off"
                return JSONResponse(error("notes_off"), status_code=409)
            try:
                body = bytearray()
                async for chunk in request.stream():
                    if len(body) + len(chunk) > notes.MAX_BODY_BYTES:
                        raise ValueError("Request too large")
                    body.extend(chunk)
                fields = validate(json.loads(bytes(body)))
            except ValueError:  # includes malformed JSON and invalid UTF-8
                token.outcome = "bad_notes"
                return JSONResponse(error("bad_notes"), status_code=400)
            if structuring.locked():
                token.outcome = "busy"
                return JSONResponse(error("busy"), status_code=503)
            async with structuring:
                started = time.perf_counter()
                if managed is not None:
                    managed.prewarm()
                result = await run(*fields[:2])
                elapsed = (time.perf_counter() - started) * 1000
            token.outcome = failure(result.error)
            return respond(fields, result, elapsed)

    async def notes_structure(request: Request):
        """Lengths-only logging; the transcript and Markdown never reach the log."""

        def respond(fields, result, elapsed):
            transcript, outline, _final = fields
            log.info(
                "notes_structure chars=%d outline=%d structured=%s error=%s reason=%s ms=%.1f",
                len(transcript),
                len(outline),
                result.structured,
                result.error,
                result.reason,
                elapsed,
            )
            body = {
                "markdown": result.markdown,
                "structured": result.structured,
                "error": result.error,
                "timings_ms": {"structure": elapsed},
            }
            return JSONResponse(body if result.structured else body | {"reason": result.reason})

        return await notes_pass(
            request,
            "notes_structure",
            notes.validate_request,
            lambda transcript, outline: notes.structure(corrector, transcript, outline),
            respond,
        )

    async def notes_reorganize(request: Request):
        """Lengths-only logging; the notes and Markdown never reach the log."""

        def respond(fields, result, elapsed):
            text, outline, _final = fields
            log.info(
                "notes_reorganize chars=%d outline=%d reorganized=%s changed=%s error=%s reason=%s "
                "ms=%.1f",
                len(text),
                len(outline),
                result.reorganized,
                result.changed,
                result.error,
                result.reason,
                elapsed,
            )
            body = {
                "markdown": result.markdown,
                "reorganized": result.reorganized,
                "changed": result.changed,
                "error": result.error,
                "timings_ms": {"reorganize": elapsed},
            }
            return JSONResponse(body if result.reorganized else body | {"reason": result.reason})

        return await notes_pass(
            request,
            "notes_reorganize",
            notes.validate_reorganize_request,
            lambda text, outline: notes.reorganize(corrector, text, outline),
            respond,
        )

    async def notes_edit_route(request: Request):
        """Lengths-only logging; the notes, instruction and Markdown never reach the log."""

        def respond(fields, result, elapsed):
            (edit,) = fields
            log.info(
                "notes_edit chars=%d instruction=%d selection=%s edited=%s changed=%s error=%s "
                "reason=%s ms=%.1f",
                len(edit.text),
                len(edit.instruction),
                edit.selection is not None,
                result.edited,
                result.changed,
                result.error,
                result.reason,
                elapsed,
            )
            body = {
                "markdown": result.markdown,
                "edited": result.edited,
                "changed": result.changed,
                "error": result.error,
                "timings_ms": {"edit": elapsed},
            }
            return JSONResponse(body if result.edited else body | {"reason": result.reason})

        return await notes_pass(
            request,
            "notes_edit",
            lambda body: (notes_edit.validate_edit_request(body),),
            lambda edit: notes_edit.edit(corrector, edit),
            respond,
        )

    async def speakers_route(request: Request):
        """The speaker model: download, cancel an active download, or remove an installed model.
        The download runs in the background; health reports its state."""
        if (refusal := reject(request.headers)) is not None:
            return refusal
        source = credential.source(bearer(request.headers), request.scope)
        with activity.track(source, None, "speaker_model") as token:
            body = await request.body()
            try:
                action = json.loads(body) if len(body) <= 1024 else None
            except ValueError:
                action = None
            if not isinstance(action, dict) or set(action) != {"action"}:
                token.outcome = "bad_speakers"
                return JSONResponse(error("bad_speakers"), status_code=400)
            if action["action"] == "download":
                await speakers.start_download()
                status = 202 if speakers.state == "downloading" else 200
                token.outcome = "ok"
                return JSONResponse(speakers.health(), status_code=status)
            if action["action"] == "cancel":
                await speakers.cancel_download()
                token.outcome = "ok"
                return JSONResponse(speakers.health())
            if action["action"] == "remove":
                if not await speakers.remove():
                    token.outcome = "busy"
                    return JSONResponse(speakers.health(), status_code=409)
                token.outcome = "ok"
                return JSONResponse(speakers.health())
            token.outcome = "bad_speakers"
            return JSONResponse(error("bad_speakers"), status_code=400)

    async def voice_action(action) -> dict:
        library = speakers.library
        kind = action.get("action") if isinstance(action, dict) else None
        if not isinstance(kind, str) or kind not in VOICE_ACTIONS:
            raise VoiceError("bad_speakers")
        keys = set(action)
        if kind == "remember":
            source = keys & {"from", "audio"}
            if len(source) != 1 or keys - {"action", "name", "voice", "from", "audio"}:
                raise VoiceError("bad_speakers")
            name = clean_name(action.get("name"))
            voice = action.get("voice")
            if voice is not None and not (isinstance(voice, str) and VOICE_ID.fullmatch(voice)):
                raise VoiceError("bad_speakers")
            if not (await asyncio.to_thread(library.read))["enabled"]:
                raise VoiceError("disabled")
            if "from" in action:
                origin = action["from"]
                if (
                    not isinstance(origin, dict)
                    or set(origin) != {"session", "generation", "speaker"}
                    or not isinstance(origin["session"], str)
                    or not SPEAKER_SESSION.fullmatch(origin["session"])
                    or not isinstance(origin["generation"], str)
                    or not 0 < len(origin["generation"]) <= 64
                    or not small_int(origin["speaker"], 63)
                ):
                    raise VoiceError("bad_speakers")
                embedding, seconds = speakers.person(
                    origin["session"], origin["generation"], origin["speaker"]
                )
            else:
                embedding, seconds = await speakers.clip(clip_field(action["audio"]))
            saved = await asyncio.to_thread(library.remember, name, embedding, seconds, voice)
            return {**await asyncio.to_thread(library.listing), "voice": saved}
        if kind == "import":
            # A voice the Mac saved before the shared library (#18), from a model that agrees.
            if (
                keys != {"action", "name", "embedding", "seconds", "model"}
                or not isinstance(action["model"], str)
                or action["model"] not in IMPORTABLE
                or not isinstance(action["embedding"], str)
                or isinstance(action["seconds"], bool)
                or not isinstance(action["seconds"], int | float)
                or not 0 <= action["seconds"] < 1e6
            ):
                raise VoiceError("bad_speakers")
            name = clean_name(action["name"])
            try:
                embedding = decode(action["embedding"])
            except ValueError:
                raise VoiceError("bad_speakers") from None
            if embedding.shape != (DIMENSIONS,):
                raise VoiceError("bad_speakers")
            saved = await asyncio.to_thread(
                library.remember, name, embedding, float(action["seconds"])
            )
            return {**await asyncio.to_thread(library.listing), "voice": saved}
        if kind == "identify":
            people = action.get("people")
            if (
                keys != {"action", "people"}
                or not isinstance(people, list)
                or not 0 < len(people) <= MAX_IDENTIFY
                or not all(
                    isinstance(p, dict)
                    and set(p) == {"person", "audio"}
                    and small_int(p["person"], 999)
                    for p in people
                )
                or len({p["person"] for p in people}) != len(people)
            ):
                raise VoiceError("bad_speakers")
            clips = {p["person"]: clip_field(p["audio"]) for p in people}
            if not (await asyncio.to_thread(library.read))["enabled"]:
                raise VoiceError("disabled")
            candidates = await asyncio.to_thread(library.candidates)
            if not candidates:
                return {"matches": []}
            heard = {person: await speakers.clip(pcm) for person, pcm in clips.items()}
            found = match(heard, candidates)
            log.info("speakers voices count=%d matched=%d", len(candidates), len(found))
            return {
                "matches": [
                    {"person": person, "voice": voice.id, "name": voice.name}
                    for person, voice in sorted(found.items())
                ]
            }
        expected = {
            "rename": {"action", "voice", "name"},
            "forget": {"action", "voice"},
            "forget_all": {"action"},
            "enable": {"action"},
            "disable": {"action", "forget"} if "forget" in action else {"action"},
        }[kind]
        voice = action.get("voice")
        if (
            keys != expected
            or ("voice" in expected and not (isinstance(voice, str) and VOICE_ID.fullmatch(voice)))
            or not isinstance(action.get("forget", False), bool)
        ):
            raise VoiceError("bad_speakers")
        if kind == "rename":
            await asyncio.to_thread(library.rename, voice, action["name"])
        elif kind == "forget":
            await asyncio.to_thread(library.forget, voice)
        elif kind == "forget_all":
            await asyncio.to_thread(library.forget_all)
        elif kind == "enable":
            await asyncio.to_thread(library.enable)
        else:
            await asyncio.to_thread(library.disable, action.get("forget", False))
        return await asyncio.to_thread(library.listing)

    async def voices_route(request: Request):
        """Saved voices (#247): `GET` lists them (names and seconds, never a voiceprint); `POST`
        takes one action. Logs carry the action and a code only."""
        if not authorized(credential, bearer(request.headers)):
            return JSONResponse(
                error("auth"), status_code=401, headers={"WWW-Authenticate": "Bearer"}
            )
        kind = "list"
        try:
            if request.method == "POST":
                body = bytearray()
                async for chunk in request.stream():
                    body.extend(chunk)
                    if len(body) > MAX_VOICES_BODY:
                        raise VoiceError("clip_too_long")
                try:
                    action = json.loads(body)
                except ValueError:
                    action = None
                if (
                    isinstance(action, dict)
                    and isinstance(action.get("action"), str)
                    and action["action"] in VOICE_ACTIONS
                ):
                    kind = action["action"]
                else:
                    kind = "unknown"
                result = await voice_action(action)
            else:
                result = await asyncio.to_thread(speakers.library.listing)
        except VoiceError as exc:
            log.info("speakers voices action=%s code=%s", kind, exc.code)
            return JSONResponse(error(exc.code), status_code=VOICE_STATUS[exc.code])
        except (OSError, ValueError):
            log.warning("speakers voices action=%s code=voices_file", kind)
            return JSONResponse(error("voices_file"), status_code=500)
        if kind != "list":
            log.info("speakers voices action=%s code=ok", kind)
        return JSONResponse(result)

    async def transcribe(request: Request):
        if (refusal := reject(request.headers)) is not None:
            return refusal
        source = credential.source(bearer(request.headers), request.scope)
        with activity.track(source, None, "transcribe") as token:
            try:
                body = bytearray()
                async for chunk in request.stream():
                    if len(body) + len(chunk) > MAX_PCM + 65536:
                        raise AudioError("too_long")
                    body.extend(chunk)
                pcm = decode_wav(bytes(body))
                token.audio_ms = len(pcm) // 32
                await asyncio.wait_for(worker.lease.acquire(), settings.queue_timeout)
                try:
                    started = time.perf_counter()
                    raw = await worker.call(engine.transcribe, samples(pcm))
                finally:
                    worker.lease.release()
                final = await make_final(raw, pcm, None, started, corrector, False)
                retention.save(uuid4().hex, pcm, final)
                log.info(
                    "bytes=%d identity_present=%s",
                    len(pcm),
                    "tailscale-user-login" in request.headers,
                )
                token.outcome = "ok"
                return JSONResponse(final)
            except AudioError as exc:
                token.outcome = exc.code
                return JSONResponse(
                    error(exc.code), status_code=413 if exc.code == "too_long" else 400
                )
            except TimeoutError:
                token.outcome = "busy"
                return JSONResponse(error("busy"), status_code=503)
            except Exception:
                token.outcome = "engine"
                log.warning("code=engine")
                return JSONResponse(error("engine"), status_code=503)

    def owner_gate(request: Request):
        """None for the owner token used directly on this machine, else the refusal. Neither the
        shared token, a device token nor a proxied owner token may read activity."""
        value = bearer(request.headers)
        if owner and secrets.compare_digest(encode(owner), encode(value)):
            if direct_loopback(request.scope):
                return None
            return JSONResponse(error("forbidden"), status_code=403)
        if authorized(credential, value):
            return JSONResponse(error("forbidden"), status_code=403)
        activity.refused(*credential.refusal(value))
        return JSONResponse(error("auth"), status_code=401, headers={"WWW-Authenticate": "Bearer"})

    async def device_activity(request: Request):
        if (refusal := owner_gate(request)) is not None:
            return refusal
        return JSONResponse(activity.snapshot(credential.roster()))

    async def device_activity_settings(request: Request):
        """`{"keep": false}` stops recording and deletes the stored activity; `true` resumes."""
        if (refusal := owner_gate(request)) is not None:
            return refusal
        try:
            body = json.loads(await request.body())
        except ValueError:
            body = None
        if (
            not isinstance(body, dict)
            or set(body) != {"keep"}
            or not isinstance(body["keep"], bool)
        ):
            return JSONResponse(error("bad_activity"), status_code=400)
        activity.set_keep(body["keep"])
        return JSONResponse({"keep": activity.keep})

    async def receive(ws, deadline=None):
        message = await asyncio.wait_for(
            ws.receive(), settings.idle_seconds if deadline is None else deadline
        )
        if message["type"] == "websocket.disconnect":
            raise WebSocketDisconnect(message.get("code", 1000))
        value = message.get("text")
        if value is not None:
            if len(value.encode()) >= MAX_FRAME:
                raise AudioError()
            try:
                control = json.loads(value)
            except (ValueError, TypeError) as exc:
                raise AudioError() from exc
            if not isinstance(control, dict):
                raise AudioError()
            return control
        return message.get("bytes", b"")

    async def finalize(ws, utterance):
        """Await finish() while still observing the socket (R2-01).

        Cancel or disconnect during finalization marks the utterance cancelled, which
        suppresses correction, retention and final delivery; native inference still
        drains on its owning thread. Frames racing with finalization are returned for
        normal dispatch afterwards, and a read still in flight is returned rather than
        cancelled: cancelling it could drop a frame it had already taken off the socket (a
        `start` sent right after `cancel`).
        """
        finisher = asyncio.create_task(utterance.finish())
        raced = []
        while not finisher.done():
            reader = asyncio.create_task(receive(ws))
            done, _ = await asyncio.wait({finisher, reader}, return_when=asyncio.FIRST_COMPLETED)
            if finisher in done:
                if not reader.done():
                    return finisher.result(), raced, reader
                # A completed reader's frame must not be lost; keep it for re-dispatch.
                if not reader.cancelled():
                    with contextlib.suppress(Exception):
                        raced.append(reader.result())
                break
            try:
                message = reader.result()
            except WebSocketDisconnect:
                utterance.disconnected = True
                utterance.cancel()
                await finisher
                break
            except TimeoutError:
                continue  # The idle deadline restarts; keep waiting for finalization.
            except AudioError:
                utterance.cancel()
                await finisher
                raise
            if isinstance(message, bytes):
                raced.append(message)
            elif message.get("type") == "cancel":
                utterance.cancel()
            else:
                raced.append(message)
        return finisher.result(), raced, None

    async def stream(ws: WebSocket):
        nonlocal pending_auth
        utterance = None
        pending = None  # A read finalize() left in flight; the next frame comes from it.

        def settle(outcome, final=None):
            """Close the utterance's activity entry (metadata only; a no-op once closed)."""
            if utterance is None or utterance.token is None:
                return
            if final is not None:
                utterance.token.corrected = bool(final.get("corrected"))
            activity.end(utterance.token, outcome, len(utterance.pcm) // 32)

        await ws.accept()
        try:
            presented = bearer(ws.headers)
            valid = authorized(credential, presented)
            # An explicitly supplied wrong header cannot switch authentication paths.
            if not valid and "authorization" not in ws.headers:
                if pending_auth >= settings.max_pending_auth:
                    activity.refused("no_token")
                    await ws.send_json(error("auth"))
                    await ws.close(code=4401)
                    return
                pending_auth += 1
                presented = None
                try:
                    auth = await receive(ws, settings.auth_seconds)
                    presented = auth.get("token") if isinstance(auth, dict) else None
                    valid = (
                        isinstance(auth, dict)
                        and auth.get("type") == "auth"
                        and authorized(credential, presented)
                    )
                except (AudioError, TimeoutError):
                    valid = False
                finally:
                    pending_auth -= 1
            if not valid:
                activity.refused(*credential.refusal(presented))
                await ws.send_json(error("auth"))
                await ws.close(code=4401)
                return
            source = credential.source(presented, ws.scope)
            carry = deque()
            while True:
                if carry:
                    message = carry.popleft()
                elif pending is not None:
                    reader, pending = pending, None
                    try:
                        message = await reader
                    except TimeoutError:
                        # Its idle deadline started during finalization; give the client a
                        # full one from now.
                        message = await receive(ws)
                else:
                    message = await receive(ws)
                if isinstance(message, bytes):
                    if utterance is None:
                        raise AudioError()
                    utterance.add(message)
                    continue
                kind = message.get("type")
                if kind == "start" and utterance is None:
                    utterance = Utterance(ws, worker, settings, corrector, retention, speakers)
                    client = message.get("client")
                    utterance.token = activity.begin(
                        source,
                        client if isinstance(client, str) and client in CLIENTS else None,
                        "notes_segment"
                        if message.get("correction_profile") == LIVE_NOTES_ID
                        else "dictation",
                    )
                    await utterance.start(message)
                elif kind == "cancel" and utterance:
                    settle("cancelled")
                    await utterance.close()
                    utterance = None
                elif kind == "stop" and utterance:
                    utterance.set_context(message)
                    final, raced, pending = await finalize(ws, utterance)
                    # A cancelled utterance sends nothing: no final, no error; the
                    # socket stays usable for the next start.
                    if final is not None:
                        await ws.send_json(final)
                        settle(failure(final["correction_error"]), final)
                    else:
                        settle("disconnected" if utterance.disconnected else "cancelled")
                    await utterance.close()
                    utterance = None
                    carry.extend(raced)
                else:
                    raise AudioError()
        except WebSocketDisconnect:
            settle("disconnected")
        except TimeoutError:
            # Still queued for the engine: busy; otherwise the client went quiet.
            settle("busy" if utterance is not None and utterance.task is None else "timeout")
            if utterance is not None:
                await ws.send_json(error("busy"))
            await ws.close(code=1000)
        except AudioError as exc:
            settle(exc.code)
            await ws.send_json(error(exc.code))
            await ws.close(code=1009 if exc.code == "too_long" else 1003)
        except Exception:
            settle("engine")
            log.warning("code=engine")
            with contextlib.suppress(Exception):
                await ws.send_json(error("engine"))
                await ws.close(code=1011)
        finally:
            if pending is not None:
                pending.cancel()
            settle("disconnected")
            if utterance:
                await utterance.close()

    app = Starlette(
        routes=[
            Route("/v1/health", health),
            Route("/v1/correction/profiles", profiles),
            Route("/v1/correction/settings", correction_settings, methods=["GET", "PUT"]),
            Route("/v1/transcribe", transcribe, methods=["POST"]),
            Route("/v1/notes/structure", notes_structure, methods=["POST"]),
            Route("/v1/notes/reorganize", notes_reorganize, methods=["POST"]),
            Route("/v1/notes/edit", notes_edit_route, methods=["POST"]),
            Route("/v1/speakers/model", speakers_route, methods=["POST"]),
            Route("/v1/devices/activity", device_activity, methods=["GET"]),
            Route("/v1/devices/activity/settings", device_activity_settings, methods=["PUT"]),
            Route("/v1/speakers/voices", voices_route, methods=["GET", "POST"]),
            WebSocketRoute("/v1/stream", stream),
        ],
        lifespan=lifespan,
    )
    app.state.worker = worker
    return app


def accept_prefix(app, prefix):
    """Serve the same routes with or without `prefix`, whichever form the proxy forwards.

    `tailscale serve --set-path /chirp` may or may not strip its mount point; both work.
    """
    prefix = "/" + prefix.strip("/") if prefix and prefix.strip("/") else ""
    if not prefix:
        return app

    async def wrapped(scope, receive, send):
        path = scope.get("path", "")
        if scope["type"] in ("http", "websocket") and (
            path == prefix or path.startswith(prefix + "/")
        ):
            scope = dict(scope, path=path[len(prefix) :] or "/")
            if "raw_path" in scope and scope["raw_path"] is not None:
                scope["raw_path"] = scope["raw_path"][len(prefix) :] or b"/"
        await app(scope, receive, send)

    return wrapped
