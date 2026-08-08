do %../convex.r3

url: "https://usable-reindeer-44.convex.cloud"
print ["open:" convex-open url "debug-0.1.0"]

port: sock-open
print ["port:" mold type? port]
either port [
    request: "POST /api/query HTTP/1.1^M^/Host: usable-reindeer-44.convex.cloud^M^/Content-Type: application/json^M^/Content-Length: 2^M^/^M^/{}"
    wok: sock-write-once port request 5.0
    print ["write ok:" wok]
    r1: sock-read-once port 5.0
    print ["read1 outcome:" r1/outcome "bytes:" length? r1/bytes]
    print ["read1 text:" copy/part to string! r1/bytes 200]
    r2: sock-read-once port 5.0
    print ["read2 outcome:" r2/outcome "bytes:" length? r2/bytes]
] [
    print ["sock-open failed:" convex-error-name convex-error-message]
]
quit
