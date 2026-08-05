package convex

import com.fasterxml.jackson.databind.{JsonNode, ObjectMapper}
import com.fasterxml.jackson.databind.node.ObjectNode
import java.net.URI
import java.net.http.{HttpClient, HttpRequest, HttpResponse}
import java.time.Duration
import scala.jdk.CollectionConverters.*

/** Native Scala access to Convex's documented JSON HTTP functions API. */
object ConvexClient:
  val json = new ObjectMapper()
  final case class Result(value: JsonNode, logs: List[String])
  class TransportError(val operation: String, cause: Throwable)
      extends Exception(cause.getMessage, cause)
  class ProtocolError(message: String) extends Exception(message)
  class FunctionError(
      val operation: String,
      message: String,
      val data: JsonNode,
      val logs: List[String]
  ) extends Exception(message)

final class ConvexClient(rawUrl: String) extends AutoCloseable:
  import ConvexClient.*
  private val deployment =
    val uri = URI.create(rawUrl.replaceAll("/+$", ""))
    if !Set("http", "https").contains(
        uri.getScheme
      ) || uri.getHost == null || uri.getUserInfo != null
    then
      throw new IllegalArgumentException(
        "Convex deployment URL must be http(s), have a host, and omit user info"
      )
    uri
  private val http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(10)).build()
  @volatile private var token = ""
  @volatile private var closed = false

  def setAuth(bearerToken: String): Unit =
    ensureOpen()
    token = Option(bearerToken).getOrElse("")
  def query(path: String, args: JsonNode): Result = call("query", path, args)
  def mutation(path: String, args: JsonNode): Result = call("mutation", path, args)
  def action(path: String, args: JsonNode): Result = call("action", path, args)

  private def call(operation: String, path: String, args: JsonNode): Result =
    ensureOpen()
    if path == null || path.isBlank then
      throw new IllegalArgumentException("Convex function path is required")
    if args == null || !args.isObject then
      throw new IllegalArgumentException("Convex arguments must be a named JSON object")
    val body = json.createObjectNode().put("path", path)
    body.set[JsonNode]("args", args)
    body.put("format", "json")
    var request = HttpRequest
      .newBuilder(deployment.resolve(s"/api/$operation"))
      .timeout(Duration.ofSeconds(30))
      .header("Content-Type", "application/json")
      .header("Accept", "application/json")
      .header("Convex-Client", "scala-0.1.0")
    if token.nonEmpty then request = request.header("Authorization", s"Bearer $token")
    val response =
      try
        http.send(
          request.POST(HttpRequest.BodyPublishers.ofString(json.writeValueAsString(body))).build(),
          HttpResponse.BodyHandlers.ofString()
        )
      catch case e: Exception => throw new TransportError(operation, e)
    val decoded =
      try json.readTree(response.body())
      catch
        case e: Exception =>
          throw new TransportError(
            operation,
            new IllegalStateException("non-Convex HTTP response", e)
          )
    if decoded.path("status").asText() == "success" then
      if !decoded.has("value") then throw new ProtocolError("success response omitted value")
      Result(decoded.get("value"), logs(decoded))
    else if decoded.path("status").asText() == "error" then
      throw new FunctionError(
        operation,
        decoded.path("errorMessage").asText("Convex function failed"),
        decoded.get("errorData"),
        logs(decoded)
      )
    else throw new ProtocolError(s"HTTP ${response.statusCode()} response has unknown status")

  private def logs(node: JsonNode): List[String] = if node.path("logLines").isArray then
    node.path("logLines").elements().asScala.map(_.asText()).toList
  else Nil
  private def ensureOpen(): Unit =
    if closed then throw new IllegalStateException("Convex client is closed")
  def close(): Unit = closed = true
