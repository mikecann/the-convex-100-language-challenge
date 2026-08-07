/*
 * The public-shaped client: HTTP query/mutation/action calls plus a
 * Live subscription pump, tied together behind one object. Everything
 * Convex-specific about HTTP framing lives in convexhttp.prg, everything
 * about the Live sync protocol lives in convexlive.prg; this file only
 * wires them to one parsed deployment URL and one bearer token.
 */

#include "hbclass.ch"

CREATE CLASS TConvexClient

   VAR oUrl
   VAR cToken INIT ""
   VAR oLive

   METHOD New( cUrl, bOnEvent )
   METHOD SetAuth( cToken )
   METHOD Call( cOpName, cPath, xArgs, nTimeoutMs )
   METHOD Subscribe( cSubId, cPath, xArgs )
   METHOD Unsubscribe( cSubId )
   METHOD DebugDisconnect()
   METHOD ConnectionCount()
   METHOD Close()

ENDCLASS

/* cUrl must already be a valid http(s) deployment URL; callers validate
 * it with ConvexParseUrl() themselves first so a malformed CONVEX_URL can
 * be reported before any thread or socket exists. bOnEvent, when given,
 * is called on the Live worker thread as
 * bOnEvent(cSubscriptionId, xValue, hError, xLogs) for every delivered
 * update or failure; xValue and hError are never both non-NIL. */
METHOD New( cUrl, bOnEvent ) CLASS TConvexClient
   ::oUrl := ConvexParseUrl( cUrl )
   IF ::oUrl != NIL
      ::oLive := TConvexLive():New( ::oUrl, bOnEvent )
      ::oLive:Start()
   ENDIF
   RETURN Self

METHOD SetAuth( cToken ) CLASS TConvexClient
   ::cToken := cToken
   RETURN Self

/* cOpName is "query", "mutation" or "action". Returns the
 * ConvexHttpCall() result hash directly: { "ok" => .T., "value" => ...,
 * "logs" => ... } or { "ok" => .F., "error" => ..., "logs" => ... }. */
METHOD Call( cOpName, cPath, xArgs, nTimeoutMs ) CLASS TConvexClient
   RETURN ConvexHttpCall( ::oUrl, ::cToken, cOpName, cPath, xArgs, ConvexNowMs() + nTimeoutMs )

METHOD Subscribe( cSubId, cPath, xArgs ) CLASS TConvexClient
   ::oLive:Subscribe( cSubId, cPath, xArgs )
   RETURN Self

METHOD Unsubscribe( cSubId ) CLASS TConvexClient
   ::oLive:Unsubscribe( cSubId )
   RETURN Self

METHOD DebugDisconnect() CLASS TConvexClient
   ::oLive:DebugDisconnect()
   RETURN Self

METHOD ConnectionCount() CLASS TConvexClient
   RETURN ::oLive:ConnectionCount()

METHOD Close() CLASS TConvexClient
   ::oLive:Stop()
   RETURN Self
