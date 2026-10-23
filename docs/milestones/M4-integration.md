# M4: Integration (`chirp/integration`)

Owner: the orchestrator, with optional helper workers. Starts once M1, M2 and M3 have merged into `chirp/integration`.

1. Run every track's test suite on the integration head.
2. Run the server against the real model on 127.0.0.1:7821, then:
   - Run `client_sim.py`, the Mac `--selftest` and the Android unit tests against it.
3. Tailnet exposure, tailnet-only and never Funnel:
   - `tailscale serve --bg --set-path /chirp http://127.0.0.1:7821`
   - Verify `wss://<your-mac>.<tailnet>.ts.net/chirp/v1/stream` from this Mac with `client_sim.py --url`.
   - Document the rollback: `tailscale serve --set-path /chirp off`.
4. Optional LaunchAgent for the server: `chirp-server service install`, which keeps the model warm.
5. `docs/TESTING.md` lists the exact operator commands for the Mac and the Fold 8 (pairing, install, permissions, dictation, debug retention on/off, battery session).
6. Fill `docs/bench.md` with the end-to-end numbers once the phone is attached.
7. Present the integration branch for the operator's approval before any merge into `main`.
