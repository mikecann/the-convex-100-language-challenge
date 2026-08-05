package convex

import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.databind.node.ObjectNode
import java.io.BufferedReader
import java.io.InputStream
import java.io.InputStreamReader
import java.io.OutputStream
import java.io.PrintWriter
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.nio.charset.StandardCharsets
import java.time.Duration
import scala.collection.mutable
import scala.jdk.CollectionConverters.*

/** Test-only NDJSON adapter protocol v1. stdout is exclusively protocol events. */
object Adapter:
  @volatile private[convex] var testRelayBeforePublish
      : (String, LiveClient.Subscription, LiveClient.Update) => Unit = (_, _, _) => ()
  @volatile private[convex] var testRelayAfterPublishAttempt
      : (String, LiveClient.Subscription) => Unit = (_, _) => ()

  def main(args: Array[String]): Unit =
    Option(System.getenv("ADAPTER_LISTEN")).filter(_.nonEmpty) match
      case None =>
        run(
          System.in,
          System.out,
          Option(System.getenv("CONVEX_URL")).getOrElse("")
        )
      case Some(address) =>
        val server = bind(address)
        try
          val controller = server.accept()
          try
            run(
              controller.getInputStream,
              controller.getOutputStream,
              Option(System.getenv("CONVEX_URL")).getOrElse("")
            )
          finally controller.close()
        finally server.close()

  private[convex] def bind(address: String): ServerSocket =
    val split = address.lastIndexOf(':')
    if split < 1 then throw new IllegalArgumentException("ADAPTER_LISTEN must be host:port")
    val server = new ServerSocket()
    server.bind(
      new InetSocketAddress(
        InetAddress.getByName(address.substring(0, split)),
        address.substring(split + 1).toInt
      )
    )
    server

  private[convex] def run(
      source: InputStream,
      sink: OutputStream,
      deployment: String
  ): Unit =
    val input = new BufferedReader(new InputStreamReader(source, StandardCharsets.UTF_8))
    val output = new Output(sink)
    val relays = new RelayRegistry
    var client: Option[ConvexClient] = None
    var live: Option[LiveClient] = None
    var stopped = false

    def ensureClient(): ConvexClient = client.getOrElse {
      if deployment.isBlank then throw new IllegalStateException("CONVEX_URL is required")
      val created = new ConvexClient(deployment)
      client = Some(created)
      created
    }

    while !stopped do
      val line = input.readLine()
      if line == null then stopped = true
      else
        var id = ""
        try
          val command = ConvexClient.json.readTree(line)
          id = command.path("id").asText("")
          command.path("op").asText("") match
            case "hello" =>
              if command.path("protocolVersion").asInt() != 1 then
                throw new IllegalArgumentException("unsupported adapter protocol version")
              output.write(
                event("ready", id)
                  .put("protocolVersion", 1)
                  .put("language", "scala")
                  .put("implementation", "native-scala-3.3.5")
                  .put("runtime", util.Properties.versionNumberString)
              )
            case "close" =>
              relays.closeAndClear()
              live.foreach(_.close())
              client.foreach(_.close())
              output.write(event("closed", id))
              stopped = true
            case "setAuth" =>
              ensureClient().setAuth(command.path("token").asText())
              output.write(event("ack", id))
            case operation @ ("query" | "mutation" | "action") =>
              val arguments =
                if command.has("args") then command.get("args")
                else ConvexClient.json.createObjectNode()
              val result = operation match
                case "query" =>
                  ensureClient().query(command.path("path").asText(), arguments)
                case "mutation" =>
                  ensureClient().mutation(command.path("path").asText(), arguments)
                case _ =>
                  ensureClient().action(command.path("path").asText(), arguments)
              output.write(resultEvent(id, result))
            case "subscribe" =>
              val subscriptionId = command.path("subscriptionId").asText()
              if subscriptionId.isBlank then
                throw new IllegalArgumentException("subscriptionId is required")
              relays.remove(subscriptionId).foreach(_.close())
              val manager = live.getOrElse {
                if deployment.isBlank then throw new IllegalStateException("CONVEX_URL is required")
                val created = new LiveClient(deployment)
                live = Some(created)
                created
              }
              val subscription = manager.subscribe(
                command.path("path").asText(),
                if command.has("args") then command.get("args")
                else ConvexClient.json.createObjectNode()
              )
              relays.registerAndWrite(subscriptionId, subscription, output, event("ack", id))
              val worker = new Thread(
                () => relay(subscriptionId, subscription, relays, output),
                s"convex-scala-adapter-$subscriptionId"
              )
              worker.setDaemon(true)
              worker.start()
            case "unsubscribe" =>
              val subscriptionId = command.path("subscriptionId").asText("")
              relays.remove(subscriptionId).foreach(_.close())
              relays.writeBarrier(output, event("ack", id))
            case "debugDisconnect" =>
              live
                .getOrElse(
                  throw new IllegalStateException("Live WebSocket is not connected")
                )
                .debugDisconnect()
              output.write(event("ack", id))
            case operation =>
              throw new IllegalArgumentException(s"unknown operation: $operation")
        catch case error: Exception => output.write(failure(id, "", error))

    relays.closeAndClear()
    live.foreach(_.close())
    client.foreach(_.close())

  private def relay(
      subscriptionId: String,
      subscription: LiveClient.Subscription,
      relays: RelayRegistry,
      output: Output
  ): Unit =
    var running = true
    while running && relays.isActive(subscriptionId, subscription) do
      try
        val update = subscription.nextUpdate(Duration.ofDays(1))
        testRelayBeforePublish(subscriptionId, subscription, update)
        relays.publishIfActive(
          subscriptionId,
          subscription,
          output,
          if update.error != null then failure("", subscriptionId, update.error)
          else subscriptionEvent(subscriptionId, update)
        )
        testRelayAfterPublishAttempt(subscriptionId, subscription)
      catch
        case error: Exception =>
          relays.publishIfActive(
            subscriptionId,
            subscription,
            output,
            failure("", subscriptionId, error)
          )
          running = false

  private[convex] def subscriptionEvent(
      subscriptionId: String,
      update: LiveClient.Update
  ): ObjectNode =
    val response = event("subscription", "").put("subscriptionId", subscriptionId)
    response.set("value", update.value)
    if update.logs.nonEmpty then
      response.set("logs", ConvexClient.json.valueToTree(update.logs.asJava))
    response

  private[convex] def resultEvent(
      id: String,
      result: ConvexClient.Result
  ): ObjectNode =
    val response = event("result", id)
    response.set("value", result.value)
    if result.logs.nonEmpty then
      response.set("logs", ConvexClient.json.valueToTree(result.logs.asJava))
    response

  private[convex] def failure(
      id: String,
      subscriptionId: String,
      error: Exception
  ): ObjectNode =
    val response = event(
      if subscriptionId.isBlank then "error" else "subscription",
      if subscriptionId.isBlank then id else ""
    )
    if subscriptionId.nonEmpty then response.put("subscriptionId", subscriptionId)
    val name = error match
      case _: ConvexClient.FunctionError  => "FunctionError"
      case _: ConvexClient.ProtocolError  => "ProtocolError"
      case _: ConvexClient.TransportError => "TransportError"
      case _                              => error.getClass.getSimpleName
    val detail = response
      .putObject("error")
      .put("name", name)
      .put("message", Option(error.getMessage).getOrElse(name))
    error match
      case function: ConvexClient.FunctionError =>
        if function.data != null then detail.set("data", function.data)
        if function.logs.nonEmpty then
          response.set("logs", ConvexClient.json.valueToTree(function.logs.asJava))
      case _ => ()
    response

  private def event(kind: String, id: String): ObjectNode =
    val result = ConvexClient.json.createObjectNode().put("type", kind)
    if id.nonEmpty then result.put("id", id)
    result

  private[convex] final class Output(sink: OutputStream):
    private val writer = new PrintWriter(sink, true, StandardCharsets.UTF_8)
    def write(value: ObjectNode): Unit = synchronized(writer.println(value))

  private[convex] final class RelayRegistry:
    private val monitor = new Object
    private val active = mutable.HashMap.empty[String, LiveClient.Subscription]
    private var closing = false

    def isActive(id: String, subscription: LiveClient.Subscription): Boolean =
      monitor.synchronized(!closing && active.get(id).contains(subscription))

    def remove(id: String): Option[LiveClient.Subscription] =
      monitor.synchronized(active.remove(id))

    def registerAndWrite(
        id: String,
        subscription: LiveClient.Subscription,
        output: Output,
        acknowledgement: ObjectNode
    ): Unit = monitor.synchronized {
      if closing then throw new IllegalStateException("adapter is closing")
      active(id) = subscription
      output.write(acknowledgement)
    }

    def writeBarrier(output: Output, acknowledgement: ObjectNode): Unit =
      monitor.synchronized(output.write(acknowledgement))

    def publishIfActive(
        id: String,
        subscription: LiveClient.Subscription,
        output: Output,
        response: ObjectNode
    ): Unit = monitor.synchronized {
      if !closing && active.get(id).contains(subscription) then output.write(response)
    }

    def closeAndClear(): List[LiveClient.Subscription] = monitor.synchronized {
      closing = true
      val subscriptions = active.values.toList
      active.clear()
      subscriptions
    }
