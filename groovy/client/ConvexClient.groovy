package convex

import groovy.json.JsonOutput
import groovy.json.JsonSlurper
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.time.Duration

/** Native Groovy access to Convex's JSON HTTP functions API. */
final class ConvexClient implements AutoCloseable {
  static final JsonSlurper JSON = new JsonSlurper()
  private final URI deployment
  private final HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(10)).build()
  private volatile String token = ''
  private volatile boolean closed = false

  ConvexClient(String deploymentUrl) {
    URI parsed = URI.create(deploymentUrl)
    if (!(parsed.scheme in ['http', 'https']) || !parsed.host || parsed.userInfo) {
      throw new IllegalArgumentException('Convex deployment URL must be http(s), have a host, and omit user info')
    }
    deployment = URI.create(parsed.toString().replaceAll('/+$', ''))
  }

  void setAuth(String bearerToken) { ensureOpen(); token = bearerToken ?: '' }
  Result query(String path, Map args) { call('query', path, args) }
  Result mutation(String path, Map args) { call('mutation', path, args) }
  Result action(String path, Map args) { call('action', path, args) }

  private Result call(String operation, String path, Map args) {
    ensureOpen()
    if (!path?.trim()) throw new IllegalArgumentException('Convex function path is required')
    if (args == null) throw new IllegalArgumentException('Convex arguments must be a named JSON object')
    Map body = [path: path, args: args, format: 'json']
    HttpRequest.Builder request = HttpRequest.newBuilder(deployment.resolve('/api/' + operation))
      .timeout(Duration.ofSeconds(30)).header('Content-Type', 'application/json')
      .header('Accept', 'application/json').header('Convex-Client', 'groovy-0.1.0')
      .POST(HttpRequest.BodyPublishers.ofString(JsonOutput.toJson(body)))
    if (token) request.header('Authorization', 'Bearer ' + token)
    HttpResponse<String> response
    try { response = http.send(request.build(), HttpResponse.BodyHandlers.ofString()) }
    catch (Exception error) { throw new TransportException(operation, error) }
    Map decoded
    try { decoded = (Map) JSON.parseText(response.body()) }
    catch (Exception error) { throw new TransportException(operation, new IllegalStateException('non-Convex HTTP response', error)) }
    List<String> logs = decoded.logLines instanceof List ? decoded.logLines.collect { it.toString() } : []
    if (decoded.status == 'success') {
      if (!decoded.containsKey('value')) throw new ProtocolException('success response omitted value')
      return new Result(decoded.value, logs)
    }
    if (decoded.status == 'error') throw new FunctionException(operation, decoded.errorMessage?.toString() ?: 'Convex function failed', decoded.errorData, logs)
    throw new ProtocolException("HTTP ${response.statusCode()} response has unknown status")
  }

  private void ensureOpen() { if (closed) throw new IllegalStateException('Convex client is closed') }
  @Override void close() { closed = true }
  static record Result(Object value, List<String> logs) {}
  static class TransportException extends RuntimeException { final String operation; TransportException(String op, Throwable cause) { super(cause.message, cause); operation = op } }
  static class ProtocolException extends RuntimeException { ProtocolException(String message) { super(message) } }
  static class FunctionException extends RuntimeException { final String operation; final Object data; final List<String> logs; FunctionException(String op, String message, Object data, List<String> logs) { super(message); operation = op; this.data = data; this.logs = logs } }
}
