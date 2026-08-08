Rebol [
    Title: "Convex REBOL client -- hardened X.509 chain and hostname verification"
    Purpose: {
        Oldes/Rebol3's native prot-tls.reb scheme completes a genuine TLS 1.2/1.3
        handshake and decodes every certificate the peer presents, but it never
        builds a chain to a trusted root and never checks the presented
        certificate's name against the hostname that was actually requested.
        Proved directly: this fork's https:// scheme accepts self-signed,
        expired, and wrong-hostname certificates with no error at all.

        This module supplies the missing verification, driven from the TLS
        port's own 'connect event (fired once the handshake finishes, before
        any HTTP request is written or any application data is read), so an
        untrusted peer is rejected before this client ever trusts a single
        byte it sent.
    }
]

;; ---------------------------------------------------------------------
;; DER TLV primitives -- just enough to find exact byte spans, not a full
;; ASN.1 decoder. codec-crt.reb (the fork's own CRT codec) already parses
;; certificate *fields*; what it does not give us is the raw byte range of
;; the signed tbsCertificate, which every chain-of-trust signature check
;; needs verbatim.
;; ---------------------------------------------------------------------

;; Read one DER tag+length header at 1-based position `pos`. Returns
;; [content-start content-length header-length].
der-tlv: function [data [binary!] pos [integer!]] [
    len-byte: data/(pos + 1)
    either len-byte < 128 [
        content-len: len-byte
        header-len: 2
    ] [
        n: len-byte - 128
        content-len: 0
        repeat i n [content-len: (content-len * 256) + data/(pos + 1 + i)]
        header-len: 2 + n
    ]
    reduce [pos + header-len content-len header-len]
]

;; Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
;; tbsCertificate is the first element inside that outer SEQUENCE; the
;; signature covers its *complete* encoding, tag+length included.
extract-tbs-certificate: function [cert-der [binary!]] [
    outer: der-tlv cert-der 1
    tbs-start: outer/1
    tbs: der-tlv cert-der tbs-start
    tbs-total-len: (tbs/1 - tbs-start) + tbs/2
    copy/part (at cert-der tbs-start) tbs-total-len
]

;; ---------------------------------------------------------------------
;; Trust bundle
;; ---------------------------------------------------------------------

;; Loads every %*.pem file in `dir` as a decoded certificate object via the
;; fork's own 'crt codec (which already handles PEM armour). This is a
;; small, curated bundle shipped in the image -- not the full system trust
;; store -- see manifest.yaml/README for exactly which roots and why.
load-trust-bundle: function [dir [file!]] [
    bundle: copy []
    foreach name read dir [
        if find name %.pem [
            append bundle decode 'crt read/binary (dir/:name)
        ]
    ]
    bundle
]

;; ---------------------------------------------------------------------
;; Signature verification -- dispatches to the generic rsa/ecdsa natives.
;; Both operate on arbitrary data/hashes and an arbitrary key; neither is
;; tied to the TLS handshake's own transcript, which is what makes reusing
;; them here for X.509 chain verification possible.
;; ---------------------------------------------------------------------

rsa-hash-by-algorithm: [
    sha256WithRSAEncryption sha256
    sha384WithRSAEncryption sha384
    sha512WithRSAEncryption sha512
    sha1WithRSAEncrption    sha1
]
ecdsa-hash-by-algorithm: [
    ecdsa-with-SHA224 sha224
    ecdsa-with-SHA256 sha256
    ecdsa-with-SHA384 sha384
    ecdsa-with-SHA512 sha512
]

;; Verifies that `subject-cert` was signed by `issuer-cert`'s key. Returns
;; true only on an explicit, checked match -- any unrecognised algorithm,
;; malformed key, or verification failure returns false (fail closed).
signed-by?: function [subject-cert [object!] issuer-cert [object!] subject-der [binary!]] [
    tbs: extract-tbs-certificate subject-der
    sig: next subject-cert/signature   ; strip BIT_STRING unused-bits byte
    algo: subject-cert/algorithm
    key-kind: issuer-cert/public-key/1

    verdict: case [
        all [key-kind = 'rsaEncryption hash: select rsa-hash-by-algorithm algo] [
            n: issuer-cert/public-key/2/1
            e: issuer-cert/public-key/2/2
            attempt [rsa/verify/hash (rsa-init n e) tbs sig hash]
        ]
        all [key-kind = 'ecPublicKey hash: select ecdsa-hash-by-algorithm algo] [
            pub-key: next issuer-cert/public-key/3   ; strip unused-bits byte
            curve: issuer-cert/public-key/2
            digest: checksum tbs hash
            attempt [ecdsa/verify/curve pub-key digest sig curve]
        ]
    ]
    true = verdict
]

;; ---------------------------------------------------------------------
;; Hostname / SAN verification (RFC 6125-style, single leftmost wildcard
;; label only, never for an IP literal). Falls back to the subject CN only
;; when no dNSName SAN entries are present at all.
;; ---------------------------------------------------------------------

digit-chars: charset [#"0" - #"9"]
is-ip-literal?: function [host [string!]] [
    any [
        parse host [some [some digit-chars "."] some digit-chars]  ; loose IPv4 shape
        find host ":"                                                ; any IPv6 shape
    ]
]

;; A pattern matches a host if it is identical (case-insensitive), or if
;; its leftmost label is "*" and every remaining label matches exactly.
;; The wildcard never matches more than one label and never matches an
;; IP literal target.
hostname-matches?: function [pattern [string!] host [string!]] [
    pattern: lowercase copy pattern
    host: lowercase copy host
    if is-ip-literal? host [return pattern = host]
    if pattern = host [return true]
    if not find pattern "*" [return false]
    pattern-parts: split pattern "."
    host-parts: split host "."
    if (length? pattern-parts) <> (length? host-parts) [return false]
    if pattern-parts/1 <> "*" [return false]
    (next pattern-parts) = (next host-parts)
]

;; dNSName entries from subjectAltName if present, else a single-element
;; block with the subject commonName, else an empty block.
names-for-cert: function [cert [object!]] [
    san: select cert/extensions 'subjectAltName
    either san [
        san/2
    ] [
        cn: select cert/subject 'commonName
        either cn [reduce [cn]] [copy []]
    ]
]

verify-hostname: function [cert [object!] host [string!]] [
    names: names-for-cert cert
    found: false
    foreach name names [
        if hostname-matches? name host [found: true]
    ]
    found
]

;; ---------------------------------------------------------------------
;; Validity window
;; ---------------------------------------------------------------------

cert-currently-valid?: function [cert [object!]] [
    all [
        cert/valid-from <= now
        now <= cert/valid-to
    ]
]

;; ---------------------------------------------------------------------
;; Full chain verification. `certs` is the presented chain in leaf-first
;; order (ctx/server-certs from prot-tls.reb); `ders` is the matching
;; block of each certificate's raw DER bytes (needed for the signature
;; check, since codec-crt.reb's parsed fields alone do not preserve the
;; exact signed byte range). `bundle` is the loaded trust anchors.
;;
;; Checks run in this deliberate order so each failure mode is reported
;; precisely rather than collapsing to one generic "rejected":
;;   1. hostname/SAN match on the leaf           -> catches a wrong-host cert
;;   2. validity window on every presented cert   -> catches an expired cert
;;   3. signature chain up to a trusted root      -> catches an untrusted/
;;                                                    self-signed cert
;; Returns an object: [trusted: true] or [trusted: false reason: "..."]
;; ---------------------------------------------------------------------
verify-chain: function [
    certs [block!] ders [block!] host [string!] bundle [block!]
][
    if empty? certs [
        return object [trusted: false reason: "no certificate presented"]
    ]

    unless verify-hostname certs/1 host [
        return object [
            trusted: false
            reason: rejoin ["certificate name does not match requested host " host]
        ]
    ]

    repeat i length? certs [
        unless cert-currently-valid? certs/:i [
            return object [
                trusted: false
                reason: rejoin ["certificate " i " in chain is outside its validity window ("
                    certs/:i/valid-from " to " certs/:i/valid-to ", now " now ")"]
            ]
        ]
    ]

    ;; Checks whether `cert` is directly issued by a trust anchor already
    ;; in the bundle: subject-name match alone is not proof (names are not
    ;; secret), so this also re-verifies the signature against that
    ;; specific bundled root's own key.
    trusted-by-bundle?: function [cert [object!] cert-der [binary!]] [
        found: none
        foreach root bundle [
            if all [
                root/subject = cert/issuer
                signed-by? cert root cert-der
            ] [ found: root ]
        ]
        found
    ]

    ;; Walk the presented chain leaf-first. A real server may present more
    ;; certificates than strictly needed -- e.g. a root that is itself
    ;; cross-signed by an older, still-trusted root for legacy client
    ;; compatibility (observed live: Google Trust Services' GTS roots are
    ;; sometimes served cross-signed by the older GlobalSign Root CA). So
    ;; trust is checked at *every* hop, not only after the presented chain
    ;; is exhausted -- the chain is trusted the moment any certificate in
    ;; it is directly issued by a bundled anchor, regardless of what the
    ;; server appended after that point.
    current: certs/1
    current-der: ders/1
    i: 2
    forever [
        if anchor: trusted-by-bundle? current current-der [
            return object [
                trusted: true
                reason: rejoin ["chain verified to bundled trust anchor " mold anchor/subject]
            ]
        ]
        if i > length? certs [break]
        unless signed-by? current certs/:i current-der [
            return object [
                trusted: false
                reason: rejoin ["signature check failed between presented certificates " (i - 1) " and " i]
            ]
        ]
        current: certs/:i
        current-der: ders/:i
        i: i + 1
    ]

    object [
        trusted: false
        reason: rejoin ["no bundled trust anchor found for issuer " mold current/issuer]
    ]
]

;; ---------------------------------------------------------------------
;; Raw-DER capture.
;;
;; prot-tls.reb's decode-certificates hands each presented certificate's
;; raw DER bytes to `decode 'CRT cert`, then keeps only the decoded
;; object -- the exact signed bytes are gone once that call returns.
;; Reconstructing tbsCertificate by re-encoding the decoded fields would
;; risk producing bytes that merely *describe* the same certificate
;; without matching what was actually signed (subtle DER form
;; differences would silently break or, worse, wrongly pass
;; verification). Wrapping the codec's own decode slot instead captures
;; the exact bytes as they pass through, with no re-encoding involved.
;; system/codecs/crt/decode is an ordinary mutable function slot (not a
;; sealed native), which is what makes this possible without patching
;; the interpreter itself.
;; ---------------------------------------------------------------------

captured-der-chain: copy []
original-crt-decode: :system/codecs/crt/decode
system/codecs/crt/decode: func [data [binary! block!]] [
    if binary? data [append/only captured-der-chain copy data]
    original-crt-decode data
]

;; ---------------------------------------------------------------------
;; Hardened connect: opens a tls:// port, verifies the presented chain
;; against `bundle` the instant the handshake finishes (the port's own
;; 'connect event, before any request is written or response read), and
;; fails closed -- an untrusted peer's port is closed immediately and no
;; caller ever sees a byte of its application data.
;;
;; Returns an object: either [ok: true port: <open tls port>] ready for
;; the caller to write/read, or [ok: false reason: "..."] with the port
;; already closed.
;; ---------------------------------------------------------------------
connect-verified-tls: function [host [string!] port-number [integer!] bundle [block!]] [
    clear captured-der-chain
    result: object [ok: false reason: "connection did not complete"]
    tls-port: make port! to-url rejoin ["tls://" host ":" port-number]
    tls-port/awake: func [event] [
        switch event/type [
            lookup [open event/port]
            connect [
                verdict: verify-chain
                    event/port/extra/server-certs
                    captured-der-chain
                    host
                    bundle
                either verdict/trusted [
                    result: object [ok: true port: event/port reason: verdict/reason]
                ] [
                    result: object [ok: false reason: verdict/reason]
                    try [close event/port]
                ]
                ;; Stop waiting the instant the verdict is known -- either
                ;; the caller takes over the now-trusted port, or a
                ;; rejected connection has nothing further to wait for.
                return true
            ]
            close [return true]
            error [
                result: object [ok: false reason: "transport error before TLS handshake completed"]
                return true
            ]
        ]
        false
    ]
    open tls-port
    wait [tls-port 20]
    result
]
