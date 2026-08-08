do %../convex.r3

url: "https://usable-reindeer-44.convex.cloud"
convex-open url "debug-0.1.0"

args: make map! []
put args "room" "debug-room-1"
response: convex-query "demo:state" args
either response/ok [
    print ["OK:" mold response/value]
] [
    print ["FAILED:" convex-error-name convex-error-message]
]
quit
