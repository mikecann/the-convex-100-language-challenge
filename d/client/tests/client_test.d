module client_test;

import convex : ConvexError, decodeResponse;
import std.json : JSONType;

void main() {}

unittest {
    auto result = decodeResponse("query", `{"status":"success","value":{"count":1},"logLines":["demo:state"]}`);
    assert(result.value.object["count"].integer == 1);
    assert(result.logs == ["demo:state"]);
}

unittest {
    bool failed;
    try {
        decodeResponse("query", `{"status":"error","errorMessage":"room failed","errorData":{"code":"ROOM_EMPTY"},"logLines":["failure"]}`);
    } catch (ConvexError error) {
        failed = error.kind == "FunctionError" && error.data.object["code"].str == "ROOM_EMPTY" && error.logs == ["failure"];
    }
    assert(failed);
}

unittest {
    bool failed;
    try {
        decodeResponse("query", `{"status":"success"}`);
    } catch (ConvexError error) {
        failed = error.kind == "ProtocolError";
    }
    assert(failed);
}
