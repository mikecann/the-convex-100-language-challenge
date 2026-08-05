package convex

import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.databind.node.ObjectNode
import java.io.{BufferedReader, InputStream, InputStreamReader, OutputStream, PrintWriter}
import java.net.{InetAddress, InetSocketAddress, ServerSocket}
import java.nio.charset.StandardCharsets
import java.time.Duration
import java.util.concurrent.ConcurrentHashMap
import scala.jdk.CollectionConverters.*

/** Test-only NDJSON adapter protocol v1. stdout is exclusively protocol events. */
object Adapter:
  def main(args: Array[String]): Unit =
    Option(System.getenv("ADAPTER_LISTEN")).filter(_.nonEmpty) match
      case None => run(System.in, System.out, Option(System.getenv("CONVEX_URL")).getOrElse(""))
      case Some(address) =>
        val server = bind(address)
        try
          val controller = server.accept()
          try run(controller.getInputStream, controller.getOutputStream, Option(System.getenv("CONVEX_URL")).getOrElse(""))
          finally controller.close()
        finally server.close()

  def bind(address: String): ServerSocket =
    val split = address.lastIndexOf(':')
    if split < 1 then throw new IllegalArgumentException("ADAPTER_LISTEN must be host:port")
    val server = new ServerSocket(); server.bind(new InetSocketAddress(InetAddress.getByName(address.substring(0, split)), address.substring(split + 1).toInt)); server

  def run(source: InputStream, sink: OutputStream, deployment: String): Unit =
    val input = new BufferedReader(new InputStreamReader(source, StandardCharsets.UTF_8)); val output = new Output(sink)
    val subscriptions = new ConcurrentHashMap[String, LiveClient.Subscription](); var client: Option[ConvexClient] = None; var live: Option[LiveClient] = None; var closing = false
    def ensureClient(): ConvexClient = client.getOrElse { if deployment.isBlank then throw new IllegalStateException("CONVEX_URL is required"); val c = new ConvexClient(deployment); client = Some(c); c }
    Iterator.continually(input.readLine()).takeWhile(_ != null).foreach { line =>
      try
        val command = ConvexClient.json.readTree(line); val id = command.path("id").asText(""); val op = command.path("op").asText("")
        op match
          case "hello" =>
            if command.path("protocolVersion").asInt() != 1 then throw new IllegalArgumentException("unsupported adapter protocol version")
            output.write(event("ready", id).put("protocolVersion", 1).put("language", "scala").put("implementation", "native-scala-3.3.5").put("runtime", util.Properties.versionNumberString))
          case "close" =>
            closing = true; subscriptions.values().asScala.foreach(_.close()); subscriptions.clear(); live.foreach(_.close()); client.foreach(_.close()); output.write(event("closed", id)); return
          case "setAuth" => ensureClient().setAuth(command.path("token").asText()); output.write(event("ack", id))
          case "query" | "mutation" | "action" =>
            val args = if command.has("args") then command.get("args") else ConvexClient.json.createObjectNode()
            val result = op match
              case "query" => ensureClient().query(command.path("path").asText(), args)
              case "mutation" => ensureClient().mutation(command.path("path").asText(), args)
              case _ => ensureClient().action(command.path("path").asText(), args)
            output.write(resultEvent(id, result))
          case "subscribe" =>
            val sid = command.path("subscriptionId").asText(); if sid.isBlank then throw new IllegalArgumentException("subscriptionId is required")
            subscriptions.remove(sid) match
              case null => ()
              case previous => previous.close()
            val l = live.getOrElse { val created = new LiveClient(deployment); live = Some(created); created }
            val subscription = l.subscribe(command.path("path").asText(), if command.has("args") then command.get("args") else ConvexClient.json.createObjectNode())
            subscriptions.put(sid, subscription); output.write(event("ack", id))
            val worker = new Thread(() => relay(sid, subscription, subscriptions, () => closing, output), s"convex-scala-adapter-$sid"); worker.setDaemon(true); worker.start()
          case "unsubscribe" => Option(subscriptions.remove(command.path("subscriptionId").asText())).foreach(_.close()); output.write(event("ack", id))
          case "debugDisconnect" => live.getOrElse(throw new IllegalStateException("Live WebSocket is not connected")).debugDisconnect(); output.write(event("ack", id))
          case _ => throw new IllegalArgumentException(s"unknown operation: $op")
      catch case e: Exception => output.write(failure("", "", e))
    }
    live.foreach(_.close()); client.foreach(_.close())

  private def relay(sid: String, subscription: LiveClient.Subscription, subscriptions: ConcurrentHashMap[String, LiveClient.Subscription], closing: () => Boolean, output: Output): Unit =
    try while !closing() && subscriptions.get(sid) == subscription do
      val update = subscription.nextUpdate(Duration.ofDays(1))
      if update.error != null then output.write(failure("", sid, update.error))
      else { val response = event("subscription", "").put("subscriptionId", sid).set[JsonNode]("value", update.value).asInstanceOf[ObjectNode]; if update.logs.nonEmpty then response.set("logs", ConvexClient.json.valueToTree(update.logs.asJava)); output.write(response) }
    catch case e: Exception => if !closing() && subscriptions.get(sid) == subscription then output.write(failure("", sid, e))

  def resultEvent(id: String, result: ConvexClient.Result): ObjectNode =
    val response = event("result", id)
    response.set("value", result.value)
    if result.logs.nonEmpty then response.set("logs", ConvexClient.json.valueToTree(result.logs.asJava))
    response
  def failure(id: String, sid: String, error: Exception): ObjectNode =
    val response = event(if sid.isBlank then "error" else "subscription", if sid.isBlank then id else ""); if sid.nonEmpty then response.put("subscriptionId", sid)
    val name = error match
      case _: ConvexClient.FunctionError => "FunctionError"
      case _: ConvexClient.ProtocolError => "ProtocolError"
      case _: ConvexClient.TransportError => "TransportError"
      case _ => error.getClass.getSimpleName
    val detail = response.putObject("error").put("name", name).put("message", Option(error.getMessage).getOrElse(name))
    error match
      case e: ConvexClient.FunctionError =>
        if e.data != null then detail.set("data", e.data)
        if e.logs.nonEmpty then response.set("logs", ConvexClient.json.valueToTree(e.logs.asJava))
      case _ => ()
    response
  private def event(kind: String, id: String): ObjectNode = { val result = ConvexClient.json.createObjectNode().put("type", kind); if id.nonEmpty then result.put("id", id); result }
  private final class Output(sink: OutputStream):
    private val writer = new PrintWriter(sink, true, StandardCharsets.UTF_8)
    def write(value: ObjectNode): Unit = this.synchronized(writer.println(value))
