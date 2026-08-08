(* ConvexUrl - splits a bare "scheme://host[:port][/path]" URL into its
   parts. Convex deployment URLs are always this simple shape (no query
   string, no userinfo), so this is a narrow helper, not a general URL
   parser, shared by both ConvexHttp and ConvexLive so the two
   transports can never disagree about how a URL is split. *)
INTERFACE ConvexUrl;

TYPE
  T = RECORD
        scheme: TEXT;
        host: TEXT;
        port: INTEGER;
        useTls: BOOLEAN;
        path: TEXT;
      END;

(* "defaultPath" is used when the URL itself has no "/..." suffix. *)
PROCEDURE Parse(url: TEXT; defaultPath: TEXT): T;

END ConvexUrl.
