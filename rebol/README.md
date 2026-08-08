# Convex from REBOL

An in-progress, educational demonstration of talking to Convex from REBOL,
using Rebol/Bulk 3.22.1 (the [Oldes/Rebol3](https://github.com/Oldes/Rebol3)
fork)'s own native `tcp://`/`tls://` port schemes -- no OpenSSL, no FFI, no
delegated runtime.

This is educational and unofficial. It is not a production Convex SDK.

## Status

Implementation is in progress. The canonical example, the HTTP client, Live
sync, and the conformance adapter are not yet complete, so no capability has
been earned yet -- see `manifest.yaml`'s `capabilities: []`.

## What is proven so far

The hardest and highest-risk part of a REBOL Convex client is already built
and proven, ahead of the rest: **`client/x509.r3`**, a from-scratch
certificate chain and hostname verifier written directly against this
fork's own crypto primitives.

Rebol/Bulk's native `tls://` scheme completes a genuine TLS 1.2/1.3
handshake and decodes every certificate a peer presents -- but it performs
**no chain-of-trust check and no hostname check at all**. Verified directly:
its `https://` scheme connects to `self-signed.badssl.com`,
`expired.badssl.com`, and `wrong.host.badssl.com` with no error whatsoever.

`client/x509.r3` supplies that missing verification in REBOL itself, hooked
into the TLS port's own `'connect` event -- which fires once the handshake
finishes, before any request is written or response read -- so a rejected
peer never gets a single byte of trust from this client:

1. **Hostname/SAN match** on the leaf certificate (RFC 6125-style, a single
   leftmost wildcard label only, never for an IP literal).
2. **Validity window** on every certificate in the presented chain.
3. **Signature chain** up to a small, curated, bundled set of trust anchors
   (`client/ca-bundle/`: GTS Root R1, GTS Root R4, ISRG Root X1, and
   GlobalSign Root CA -- the last specifically because Google Trust
   Services' own roots are sometimes served cross-signed by it for legacy
   client compatibility, which is exactly what the real Convex host does on
   some connections). Trust is checked at every hop in the presented chain,
   not only the last certificate, so that cross-signed case is handled
   correctly rather than rejected as untrusted.

Checks run in that order deliberately, so each rejection is reported for
its own precise reason rather than one generic failure.

`client/tests/x509-verify-test.r3` proves this against four **live** hosts,
not fixtures:

```
PASS -- accepts the real Convex chain -- accepted
PASS -- rejects a self-signed certificate -- rejected (no bundled trust anchor found for issuer ...)
PASS -- rejects an expired certificate -- rejected (certificate 1 in chain is outside its validity window ...)
PASS -- rejects a certificate for the wrong hostname -- rejected (certificate name does not match requested host ...)
ALL TESTS PASSED
```

Run it yourself:

```
docker run --rm --platform linux/amd64 -v $(pwd)/client:/work/client rebol-spike:3.22.1 --quiet /work/client/tests/x509-verify-test.r3
```

(against the pinned spike image; the language's own `Dockerfile` will
supersede this once the rest of the client is built).

Two implementation notes worth recording honestly, since they were real
correctness traps while building this:

- Both the RSA public-key point and the DER `signature` field come back
  from this fork's own `BIT_STRING` parsing with their leading "unused
  bits" byte still attached; every key and signature this module handles
  strips it explicitly before use.
- The fork's certificate codec (`codec-crt.reb`) parses certificate
  *fields* but discards the exact raw bytes of `tbsCertificate` --the
  signed content-- once parsing finishes. Reconstructing those bytes by
  re-encoding the decoded fields would risk silently producing bytes that
  merely describe the same certificate without matching what was actually
  signed. Instead, `client/x509.r3` wraps the registered `crt` codec's own
  `decode` function (an ordinary mutable slot, not a sealed native) to
  capture the exact bytes as they pass through, with no re-encoding
  involved.

## Toolchain

Rebol/Bulk 3.22.1, tag `3.22.1` from
[github.com/Oldes/Rebol3](https://github.com/Oldes/Rebol3/releases/tag/3.22.1),
asset `rebol3-bulk-linux-x64.gz`, sha256
`1932a7048b09cad5fc7bd9c6e4649f9fcfb45245d55876871d6a89e1d5dbad32`.

## Remaining work

- Canonical `examples/basics/main.r3` and the HTTP query/mutation/action
  client built on `client/x509.r3`'s verified transport.
- JSON encoding (this fork's `to-json` mezzanine mis-encodes booleans and
  `none`; a small correct encoder is needed the same way several other
  language clients in this repo hand-roll their own rather than trust a
  stdlib one that does not fit).
- RFC 6455 WebSocket framing and the `/api/sync` `Connect` /
  `ModifyQuerySet` / `Transition` state machine over the same verified
  transport.
- The NDJSON conformance adapter (`client/tests/conformance/`), including
  `debugDisconnect`.
- `Dockerfile` exposing the house `test` / `example-runtime` / `runtime`
  targets, on a distroless base proven earlier in the feasibility spike to
  run clean as uid 65532, read-only root filesystem, all capabilities
  dropped.
