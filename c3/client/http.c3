module c3_http;

// The shim only performs verified HTTPS bytes-on-the-wire. Keeping this
// declaration here makes it explicit that Convex request construction and
// response semantics belong to C3 rather than libcurl or a hidden C client.
extern fn CInt c3_http_request(char* method, char* url, char* body,
                               char* response, usz capacity, CLong* status);

fn bool request(char* method, char* url, char* body, char* response,
                usz capacity, CLong* status)
{
    return c3_http_request(method, url, body, response, capacity, status) != 0;
}
