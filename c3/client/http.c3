module c3_http;

import std::net::url;
import std::core::string;

faultdef INVALID_ENDPOINT, TRANSPORT_FAILED, HTTP_FAILURE;

// The shim only performs verified HTTPS bytes-on-the-wire. Keeping this
// declaration here makes it explicit that Convex request construction and
// response semantics belong to C3 rather than libcurl or a hidden C client.
extern fn CInt c3_http_request(char* method, char* url, char* body, char* bearer,
                               char* response, usz capacity, usz* response_length, CLong* status);

fn bool request(char* method, char* url, char* body, char* bearer, char* response,
                usz capacity, usz* response_length, CLong* status)
{
    return c3_http_request(method, url, body, bearer, response, capacity, response_length, status) != 0;
}

// Convex routing is intentionally C3 code. The transport shim receives a
// completed URL and never knows which Convex function or operation it carries.
fn String? endpoint_for(String deployment, String path)
{
    Url parsed = url::tparse(deployment)!;
    if ((parsed.scheme != "https" && parsed.scheme != "http") || !parsed.host)
    {
        return INVALID_ENDPOINT~;
    }
    return string::tformat("%s%s", deployment, path);
}

fn String query_envelope(String path, String args)
{
    return string::tformat(`{"path":%s,"args":%s,"format":"json"}`,
                           path.tescape(), args);
}

fn String mutation_envelope(String path, String args, String idempotency_key)
{
    return string::tformat(`{"path":%s,"args":%s,"format":"json","idempotencyKey":%s}`,
                           path.tescape(), args, idempotency_key.tescape());
}

fn CLong? post(String deployment, String endpoint_path, String payload, String bearer,
              char[] response, usz* response_length)
{
    String endpoint = endpoint_for(deployment, endpoint_path)!;
    CLong status = 0;
    if (!request("POST", endpoint.ptr, payload.ptr, bearer.ptr, response.ptr, response.len, response_length, &status)) {
        return TRANSPORT_FAILED~;
    }
    if (status < 200 || status > 299) return HTTP_FAILURE~;
    return status;
}
