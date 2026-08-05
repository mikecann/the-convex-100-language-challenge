package convex

import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.databind.node.ObjectNode
import java.net.URI
import java.net.http.{HttpClient, WebSocket}
import java.time.Duration
import java.util.UUID
import java.util.concurrent.{ArrayBlockingQueue, CompletableFuture, CompletionStage, Executors, TimeUnit, TimeoutException}
import scala.collection.mutable
import scala.jdk.CollectionConverters.*

/** Scala-owned client for the pinned, deliberately narrow Convex sync profile. */
final class LiveClient(rawUrl: String) extends AutoCloseable, WebSocket.Listener:
  import ConvexClient.*
  import LiveClient.*
  private val base = URI.create(rawUrl.replaceAll("/+$", ""))
  private val endpoint = URI.create(s"${if base.getScheme == "https" then "wss" else "ws"}://${base.getAuthority}${base.getPath}/api/sync")
  private val http = HttpClient.newHttpClient()
  // The single worker owns all socket state and serializes controller commands.
  private val owner = Executors.newSingleThreadScheduledExecutor()
  private val subscriptions = mutable.LinkedHashMap.empty[Int, Subscription]
  private var nextId = 0; private var querySetVersion = 0; private var connectionCount = 0
  private var backoff = 100L; private var lastCloseReason = "InitialConnect"; private var maxTimestamp: Option[String] = None
  private var remoteVersion: JsonNode = zeroVersion; private var socket: Option[WebSocket] = None
  private var reconnectScheduled = false; private var closed = false; private val fragments = new StringBuilder

  def subscribe(path: String, args: JsonNode): Subscription = onOwner {
    if path == null || path.isBlank || args == null || !args.isObject then throw new IllegalArgumentException("Live subscriptions require a function path and object args")
    val subscription = new Subscription(this, nextId, path, args.deepCopy())
    nextId += 1; subscriptions(subscription.queryId) = subscription
    try if socket.isEmpty then connect() else modify(List(add(subscription))) catch
      case e: Exception => subscriptions.remove(subscription.queryId); throw e
    subscription
  }

  private[convex] def unsubscribe(subscription: Subscription): Unit = onOwner {
    if subscriptions.remove(subscription.queryId).nonEmpty then
      // Invalidate the relay before acknowledging removal, preventing stale events crossing it.
      subscription.finish()
      if socket.nonEmpty then modify(List(ConvexClient.json.createObjectNode().put("type", "Remove").put("queryId", subscription.queryId)))
  }

  def debugDisconnect(): Unit = onOwner {
    if socket.isEmpty then throw new IllegalStateException("Live WebSocket is not connected")
    socket.foreach(_.abort()); socket = None; connectionCount += 1; lastCloseReason = "DebugDisconnect"; resetState(); scheduleReconnect(backoff)
  }

  private def connect(): Unit =
    if closed then throw new IllegalStateException("Convex Live client is closed")
    val connected = http.newWebSocketBuilder().connectTimeout(Duration.ofSeconds(10)).header("Convex-Client", "scala-0.1.0").buildAsync(endpoint, this).get(10, TimeUnit.SECONDS)
    socket = Some(connected); querySetVersion = 0; remoteVersion = zeroVersion
    val connect = ConvexClient.json.createObjectNode().put("type", "Connect").put("sessionId", UUID.randomUUID().toString).put("connectionCount", connectionCount).put("lastCloseReason", lastCloseReason).put("clientTs", 0)
    maxTimestamp.foreach(connect.put("maxObservedTimestamp", _)); send(connect)
    if subscriptions.nonEmpty then modify(subscriptions.values.map(add).toList)
    backoff = 100; reconnectScheduled = false

  private def add(s: Subscription): ObjectNode =
    val message = ConvexClient.json.createObjectNode().put("type", "Add").put("queryId", s.queryId).put("udfPath", s.path)
    message.putArray("args").add(s.args)
    message
  private def modify(modifications: List[ObjectNode]): Unit =
    val message = ConvexClient.json.createObjectNode().put("type", "ModifyQuerySet").put("baseVersion", querySetVersion).put("newVersion", querySetVersion + 1)
    modifications.foreach(message.putArray("modifications").add); send(message); querySetVersion += 1
  private def send(message: JsonNode): Unit = socket.getOrElse(throw new IllegalStateException("Live WebSocket is not connected")).sendText(ConvexClient.json.writeValueAsString(message), true).get(10, TimeUnit.SECONDS)

  override def onOpen(ws: WebSocket): Unit = ws.request(1)
  override def onText(ws: WebSocket, data: CharSequence, last: Boolean): CompletionStage[?] =
    submit {
      if socket.contains(ws) then
        fragments.append(data)
        if last then
          try handle(ConvexClient.json.readTree(fragments.toString))
          catch
            case e: Exception =>
              subscriptions.values.foreach(_.offer(Update(null, e, Nil)))
              disconnect("ProtocolError", true)
          finally fragments.clear()
        ws.request(1)
    }
    CompletableFuture.completedFuture(null)
  override def onClose(ws: WebSocket, status: Int, reason: String): CompletionStage[?] = { submit { if socket.contains(ws) then disconnect(s"ServerClosed:$status", true) }; CompletableFuture.completedFuture(null) }
  override def onError(ws: WebSocket, error: Throwable): Unit = submit { if socket.contains(ws) then disconnect("TransportError", true) }

  private def handle(message: JsonNode): Unit = message.path("type").asText match
    case "Ping" | "MutationResponse" | "ActionResponse" => ()
    case "TransitionChunk" => throw new ProtocolError("TransitionChunk is not supported by this demonstration")
    case "FatalError" | "AuthError" => throw new ProtocolError(message.path("error").asText())
    case "Transition" =>
      if !message.path("startVersion").equals(remoteVersion) then throw new ProtocolError("Live transition version mismatch")
      val changed = mutable.Map.empty[Int, Update]
      message.path("modifications").elements().asScala.foreach { mod =>
        val logs = if mod.path("logLines").isArray then mod.path("logLines").elements().asScala.map(_.asText()).toList else Nil
        mod.path("type").asText match
          case "QueryUpdated" => changed(mod.path("queryId").asInt()) = Update(mod.get("value"), null, logs)
          case "QueryFailed" => changed(mod.path("queryId").asInt()) = Update(null, new FunctionError("query", mod.path("errorMessage").asText(), mod.get("errorData"), logs), logs)
          case "QueryRemoved" => ()
          case other => throw new ProtocolError(s"unknown Transition modification: $other")
      }
      remoteVersion = message.path("endVersion").deepCopy(); maxTimestamp = Option(remoteVersion.path("ts").asText(null)); changed.foreach { case (id, update) => subscriptions.get(id).foreach(_.offer(update)) }
    case other => throw new ProtocolError(s"unknown Live message: $other")

  private def disconnect(reason: String, reconnect: Boolean): Unit =
    socket.foreach(_.abort()); if socket.nonEmpty then connectionCount += 1; socket = None; lastCloseReason = reason; resetState(); if reconnect then scheduleReconnect(backoff)
  private def resetState(): Unit = { querySetVersion = 0; remoteVersion = zeroVersion }
  private def scheduleReconnect(delay: Long): Unit = if !closed && subscriptions.nonEmpty && !reconnectScheduled then
    reconnectScheduled = true
    owner.schedule(new Runnable:
      def run(): Unit =
        reconnectScheduled = false
        if !closed && subscriptions.nonEmpty && socket.isEmpty then
          try connect()
          catch
            case e: Exception =>
              lastCloseReason = Option(e.getMessage).getOrElse("connect failed")
              val next = backoff
              backoff = math.min(15000L, backoff * 2)
              scheduleReconnect(next)
    , delay, TimeUnit.MILLISECONDS)
  private def submit(action: => Unit): Unit = owner.execute(() => action)
  private def onOwner[T](action: => T): T = owner.submit(() => action).get(15, TimeUnit.SECONDS)
  def close(): Unit = if !closed then onOwner { closed = true; socket.foreach(_.abort()); socket = None; subscriptions.values.foreach(_.finish()); subscriptions.clear(); owner.shutdownNow() }

object LiveClient:
  final case class Update(value: JsonNode, error: Exception, logs: List[String])
  private def zeroVersion: JsonNode = ConvexClient.json.createObjectNode().put("querySet", 0).put("identity", 0).put("ts", "AAAAAAAAAAA=")
  final class Subscription private[convex] (manager: LiveClient, private[convex] val queryId: Int, private[convex] val path: String, private[convex] val args: JsonNode) extends AutoCloseable:
    private val updates = new ArrayBlockingQueue[Update](16); @volatile private var closed = false
    private[convex] def offer(update: Update): Unit = if !closed && !updates.offer(update) then { updates.poll(); updates.offer(update) }
    private[convex] def finish(): Unit = { closed = true; updates.clear(); updates.offer(Update(null, new IllegalStateException("Live subscription is closed"), Nil)) }
    def nextUpdate(timeout: Duration): Update = Option(updates.poll(timeout.toMillis, TimeUnit.MILLISECONDS)).getOrElse(throw new TimeoutException("timed out waiting for Live update"))
    def next(timeout: Duration): JsonNode = { val update = nextUpdate(timeout); if update.error != null then throw update.error; update.value }
    def close(): Unit = if !closed then manager.unsubscribe(this)
