# TP Play link diagnostic

Settings → LINK DIAGNOSTIC. This is measured UDP load, not PS5 playback.
It does not change stream settings. Each direction tests 3/5/7/10/15/20 Mbps
for eight seconds per grade, then receives for ten more seconds without
offering load (about four minutes, 120 MB plus protocol overhead).
Leaving the page or backgrounding the app cancels the test. Only the latest
run, including partial results, is retained. Export contains metrics, not keys.

The companion Python service requires `--bind` and `--token-file` and uses
TCP/UDP 39876. Bind only to a trusted VPN interface: the protocol relies on
VPN encryption, not TLS. Never expose this port to WAN. Generate a random
32-byte token, protect the file with mode 600, and enter it in the app.
App credentials are saved to this-device-only Keychain. A developer may
provision `TPPLAY_DIAGNOSTIC_TOKEN` through launch environment once; open
the diagnostic page during that launch to persist it. Do not put tokens
in source control, build resources, logs, or exported reports.

`tpplay-diagnostic.init` is the optional OpenWrt procd service template.
Stop/disable it with `/etc/init.d/tpplay-diagnostic stop` and `disable`.

Metrics: application payload (1200-byte UDP datagrams), actual successful
sender count, unique receiver count, loss from those counts, eight-second
window-only received Mbps, late packet count, interarrival jitter EWMA,
and loaded probe RTT p95. Missing after the bounded ten-second drain is
reported as still missing, not permanent network loss. Legacy saved results
are labeled uncorrected and require retesting. Protocol v2 is required.
RTT is
not input-to-photon latency. Sender shortfall is reported independently:
a rate the sender did not offer cannot prove a network capacity limit.
The pacing budget is capped at 20ms to avoid unlimited catch-up bursts.
Results describe the tested VPN path to the gateway, not PS5 encoding,
subnet forwarding, decoding, rendering, or controller latency.

Receiver diagnostics record original/actual SO_RCVBUF, resize outcome,
active-phase loop gap max/p95 and gaps over 20ms, maximum receive batch,
batch-limit hits, and receive/send syscall errors. The diagnostic socket
tries 1MiB then smaller supported sizes, never intentionally requesting less
than the original. Streaming sockets are unchanged. iOS per-socket overflow
telemetry is unavailable (null), not zero. These counters cannot alone locate
packet loss outside the socket or prove an ISP rate limit. Upload-phase
receiver diagnostics describe the phone's probe receiver, not the gateway.

Verification:

```sh
python3 -B scripts/test_link_diagnostic_server.py
xcrun swiftc -parse-as-library ios/TPPlay/Features/Settings/LinkDiagnostic.swift scripts/link_diagnostic_smoke.swift -o /tmp/link-diagnostic-smoke
/tmp/link-diagnostic-smoke PRIVATE_VPN_IP TOKEN_FILE
```

The smoke runner compiles the actual app transport and tests both directions
at 3 Mbps. It validates protocol operation, not phone performance or UI.
