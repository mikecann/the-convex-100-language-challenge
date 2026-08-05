package convex

import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.databind.node.ObjectNode
import java.net.URI
import java.net.http.{HttpClient, WebSocket}
import java.time.Duration
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CompletionException
import java.util.concurrent.CompletionStage
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import scala.collection.mutable
import scala.jdk.CollectionConverters.*

/** Scala-owned client for the pinned, deliberately narrow Convex sync profile. */
final class LiveClient(rawUrl: String) extends AutoCloseable, WebSocket.Listener:
  import ConvexClient.*
  import LiveClient.*

  private val base = URI.create(rawUrl.replaceAll("/+$", ""))
  private val endpoint = URI.create(
    s"${if base.getScheme == "https" then "wss" else "ws"}://${base.getAuthority}${base.getPath}/api/sync"
  )
  private val http = HttpClient.newHttpClient()
  private val owner: ScheduledExecutorService =
    Executors.newSingleThreadScheduledExecutor(runnable =>
      val thread = new Thread(runnable, "convex-scala-live-owner")
      thread.setDaemon(true)
      thread
    )
  private val subscriptions = mutable.LinkedHashMap.empty[Int, Subscription]
  private val initialWaiters = mutable.LinkedHashMap.empty[Int, CompletableFuture[Subscription]]
  private var nextId = 0
  private var querySetVersion = 0
  private var connectionCount = 0
  private var reconnectBackoffMillis = initialBackoffMillis
  private var lastCloseReason = "InitialConnect"
  private var maxObservedTimestamp: Option[String] = None
  private var remoteVersion: JsonNode = zeroVersion
  private var socket: Option[WebSocket] = None
  private var connecting: Option[CompletableFuture[WebSocket]] = None
  private var reconnectScheduled = false
  private var intentionalRecovery = false
  private var suppressNextHydration = false
  @volatile private var closed = false
  private val fragments = new StringBuilder

  def subscribe(path: String, args: JsonNode): Subscription =
    if path == null || path.isBlank || args == null || !args.isObject then
      throw new IllegalArgumentException(
        "Live subscriptions require a function path and object args"
      )
    val answer = new CompletableFuture[Subscription]()
    val abandoned = new AtomicBoolean(false)
    val created = new AtomicReference[Subscription]()
    submit {
      try
        ensureOpen()
        if abandoned.get() then
          answer.completeExceptionally(new TimeoutException("timed out waiting for Live handshake"))
        else
          val subscription = new Subscription(this, nextId, path, args.deepCopy())
          created.set(subscription)
          nextId += 1
          subscriptions(subscription.queryId) = subscription
          socket match
            case Some(_) =>
              modify(List(add(subscription)))
              answer.complete(subscription)
            case None =>
              initialWaiters(subscription.queryId) = answer
              // A scheduled reconnect owns disconnected state. Starting a competing
              // initial handshake here could consume its timer and strand every query.
              if connecting.isEmpty && !reconnectScheduled then
                beginConnect(reconnecting = connectionCount > 0)
      catch
        case error: Exception =>
          Option(created.get()).foreach(discardSubscription(_, answer))
          answer.completeExceptionally(error)
    }
    try awaitMillis(answer, subscribeTimeoutMillis, "timed out waiting for Live handshake")
    catch
      case error: Throwable =>
        abandoned.set(true)
        val cleanup = new CompletableFuture[Unit]()
        val cleanupScheduled = submit {
          try
            Option(created.get()).foreach(discardSubscription(_, answer))
            cleanup.complete(())
          catch case cleanupError: Throwable => cleanup.completeExceptionally(cleanupError)
        }
        if cleanupScheduled then
          try await(cleanup, 3, "timed out cancelling failed Live subscription")
          catch case cleanupError: Throwable => error.addSuppressed(cleanupError)
        throw error

  private[convex] def unsubscribe(subscription: Subscription): Unit =
    onOwner {
      if subscriptions.remove(subscription.queryId).nonEmpty then
        subscription.finish()
        if socket.nonEmpty then
          modify(
            List(
              ConvexClient.json
                .createObjectNode()
                .put("type", "Remove")
                .put("queryId", subscription.queryId)
            )
          )
    }

  /** Test-only adapter hook. It is deliberately absent from the public facade. */
  private[convex] def debugDisconnect(): Unit =
    onOwner {
      ensureOpen()
      val previous = socket.getOrElse(
        throw new IllegalStateException("Live WebSocket is not connected")
      )
      socket = None
      previous.abort()
      connectionCount += 1
      lastCloseReason = "DebugDisconnect"
      intentionalRecovery = true
      suppressNextHydration = true
      resetRemoteState()
      scheduleReconnect(reconnectBackoffMillis)
      ownerEvent("debugDisconnectScheduled")
    }

  private def beginConnect(reconnecting: Boolean): Unit =
    ensureOpen()
    ownerEvent(if reconnecting then "reconnectBegin" else "initialConnectBegin")
    val future = http
      .newWebSocketBuilder()
      .connectTimeout(Duration.ofSeconds(3))
      .header("Convex-Client", "scala-0.1.0")
      .buildAsync(endpoint, this)
    connecting = Some(future)
    future.whenComplete((connected, failure) =>
      submit {
        if connecting.contains(future) then
          connecting = None
          if closed then
            if connected != null then connected.abort()
            failInitialWaiters(new IllegalStateException("Convex Live client is closed"))
          else if failure != null then
            val error = unwrap(failure)
            if reconnecting then
              connectionCount += 1
              lastCloseReason = "HandshakeError"
              scheduleNextReconnect(error)
            else failInitialWaiters(new TransportError("live", error))
          else finishConnect(connected, reconnecting)
      }
    )

  private def finishConnect(connected: WebSocket, reconnecting: Boolean): Unit =
    try
      socket = Some(connected)
      querySetVersion = 0
      remoteVersion = zeroVersion
      val connect = ConvexClient.json
        .createObjectNode()
        .put("type", "Connect")
        .put("sessionId", UUID.randomUUID().toString)
        .put("connectionCount", connectionCount)
        .put("lastCloseReason", lastCloseReason)
        .put("clientTs", 0)
      maxObservedTimestamp.foreach(connect.put("maxObservedTimestamp", _))
      send(connect)
      if subscriptions.nonEmpty then modify(subscriptions.values.map(add).toList)
      reconnectBackoffMillis = initialBackoffMillis
      reconnectScheduled = false
      ownerEvent(if reconnecting then "reconnectHandshake" else "initialHandshake")
      initialWaiters.foreach { case (queryId, waiter) =>
        subscriptions.get(queryId).foreach(waiter.complete)
      }
      initialWaiters.clear()
    catch
      case error: Exception =>
        disconnect(connected, "TransportError", reconnecting = true, Some(error))
        if !reconnecting then failInitialWaiters(error)

  private def add(subscription: Subscription): ObjectNode =
    val message = ConvexClient.json
      .createObjectNode()
      .put("type", "Add")
      .put("queryId", subscription.queryId)
      .put("udfPath", subscription.path)
    message.putArray("args").add(subscription.args)
    message

  private def modify(modifications: List[ObjectNode]): Unit =
    val message = ConvexClient.json
      .createObjectNode()
      .put("type", "ModifyQuerySet")
      .put("baseVersion", querySetVersion)
      .put("newVersion", querySetVersion + 1)
    val array = message.putArray("modifications")
    modifications.foreach(array.add)
    send(message)
    querySetVersion += 1
    ownerEvent("querySetModified")

  private def send(message: JsonNode): Unit =
    val active = socket.getOrElse(
      throw new IllegalStateException("Live WebSocket is not connected")
    )
    try
      awaitMillis(
        sendText(active, ConvexClient.json.writeValueAsString(message)),
        writeTimeoutMillis,
        "timed out writing Live message"
      )
    catch
      case error: Throwable =>
        val transport = new TransportError("live write", error)
        // Once a write future fails or times out, the peer may have consumed any
        // prefix. Retire that socket instead of guessing at its query-set version.
        disconnect(active, "TransportError", reconnecting = true, Some(transport))
        throw transport

  override def onOpen(webSocket: WebSocket): Unit = submit {
    webSocket.request(1)
  }

  override def onText(
      webSocket: WebSocket,
      data: CharSequence,
      last: Boolean
  ): CompletionStage[?] =
    submit {
      if socket.contains(webSocket) then
        fragments.append(data)
        if last then
          try handle(webSocket, ConvexClient.json.readTree(fragments.toString))
          catch
            case error: ProtocolError =>
              disconnect(webSocket, "ProtocolError", reconnecting = true, Some(error))
            case error: Exception =>
              disconnect(
                webSocket,
                "ProtocolError",
                reconnecting = true,
                Some(new ProtocolError(Option(error.getMessage).getOrElse("invalid Live message")))
              )
          finally fragments.clear()
        if socket.contains(webSocket) then webSocket.request(1)
    }
    CompletableFuture.completedFuture(null)

  override def onClose(
      webSocket: WebSocket,
      statusCode: Int,
      reason: String
  ): CompletionStage[?] =
    submit {
      if socket.contains(webSocket) then
        disconnect(
          webSocket,
          s"ServerClosed:$statusCode",
          reconnecting = true,
          Some(
            new TransportError(
              "live",
              new IllegalStateException(s"Live WebSocket closed: $statusCode $reason")
            )
          )
        )
    }
    CompletableFuture.completedFuture(null)

  override def onError(webSocket: WebSocket, error: Throwable): Unit = submit {
    if socket.contains(webSocket) then
      disconnect(
        webSocket,
        "TransportError",
        reconnecting = true,
        Some(new TransportError("live", unwrap(error)))
      )
  }

  private def handle(webSocket: WebSocket, message: JsonNode): Unit =
    message.path("type").asText match
      case "Ping" | "MutationResponse" | "ActionResponse" => ()
      case "TransitionChunk" =>
        throw new ProtocolError("TransitionChunk is not supported by this demonstration")
      case "FatalError" | "AuthError" =>
        throw new ProtocolError(message.path("error").asText("Live server error"))
      case "Transition" => handleTransition(webSocket, message)
      case other        => throw new ProtocolError(s"unknown Live message: $other")

  private def handleTransition(webSocket: WebSocket, message: JsonNode): Unit =
    if !socket.contains(webSocket) then return
    if !message.path("startVersion").equals(remoteVersion) then
      throw new ProtocolError("Live transition version mismatch")
    if !message.path("endVersion").isObject then
      throw new ProtocolError("Live transition omitted endVersion")
    if !message.path("modifications").isArray then
      throw new ProtocolError("Live transition omitted modifications")

    val changed = mutable.ArrayBuffer.empty[(Int, Update)]
    message.path("modifications").elements().asScala.foreach { modification =>
      if !modification.path("queryId").canConvertToInt then
        throw new ProtocolError("Live modification omitted queryId")
      val queryId = modification.path("queryId").asInt()
      val logs = strings(modification.path("logLines"))
      modification.path("type").asText match
        case "QueryUpdated" =>
          if !modification.has("value") then throw new ProtocolError("QueryUpdated omitted value")
          changed += queryId -> Update(modification.get("value"), null, logs)
        case "QueryFailed" =>
          changed += queryId -> Update(
            null,
            new FunctionError(
              "query",
              modification.path("errorMessage").asText("query failed"),
              modification.get("errorData"),
              logs
            ),
            logs
          )
        case "QueryRemoved" => ()
        case other =>
          throw new ProtocolError(s"unknown Transition modification: $other")
    }

    remoteVersion = message.path("endVersion").deepCopy()
    maxObservedTimestamp = Option(remoteVersion.path("ts").asText(null))
    reconnectBackoffMillis = initialBackoffMillis
    var restoredActiveQuery = false
    changed.foreach { case (queryId, update) =>
      subscriptions.get(queryId).foreach { subscription =>
        val unchangedHydration =
          suppressNextHydration && update.error == null && subscription.sameAsLast(update.value)
        if !unchangedHydration then subscription.offer(update)
        restoredActiveQuery = true
      }
    }
    if restoredActiveQuery then
      intentionalRecovery = false
      suppressNextHydration = false
    ownerEvent("transitionCommitted")

  private def strings(node: JsonNode): List[String] =
    if node.isArray then node.elements().asScala.map(_.asText()).toList else Nil

  private def disconnect(
      expected: WebSocket,
      reason: String,
      reconnecting: Boolean,
      failure: Option[Exception]
  ): Unit =
    if !socket.contains(expected) then return
    socket = None
    expected.abort()
    connectionCount += 1
    lastCloseReason = reason
    suppressNextHydration = true
    resetRemoteState()
    if !intentionalRecovery then
      failure.foreach(error => subscriptions.values.foreach(_.offer(Update(null, error, Nil))))
    if reconnecting then scheduleReconnect(reconnectBackoffMillis)
    ownerEvent("disconnected")

  private def resetRemoteState(): Unit =
    querySetVersion = 0
    remoteVersion = zeroVersion
    fragments.clear()

  private def scheduleReconnect(delayMillis: Long): Unit =
    if !closed && subscriptions.nonEmpty && !reconnectScheduled && connecting.isEmpty then
      reconnectScheduled = true
      reconnectAttemptScheduled(delayMillis)
      owner.schedule(
        new Runnable:
          override def run(): Unit =
            reconnectScheduled = false
            if !closed && subscriptions.nonEmpty && socket.isEmpty && connecting.isEmpty then
              beginConnect(reconnecting = true)
        ,
        delayMillis,
        TimeUnit.MILLISECONDS
      )

  private def scheduleNextReconnect(error: Throwable): Unit =
    ownerEvent("reconnectHandshakeFailed")
    reconnectBackoffMillis = math.min(maxBackoffMillis, reconnectBackoffMillis * 2)
    val delay = reconnectBackoffMillis
    lastCloseReason = Option(error.getMessage).getOrElse("HandshakeError")
    scheduleReconnect(delay)

  private def failInitialWaiters(error: Throwable): Unit =
    initialWaiters.foreach { case (queryId, waiter) =>
      subscriptions.remove(queryId).foreach(_.finish())
      waiter.completeExceptionally(error)
    }
    initialWaiters.clear()

  private def discardSubscription(
      subscription: Subscription,
      waiter: CompletableFuture[Subscription]
  ): Unit =
    initialWaiters.get(subscription.queryId).filter(_ eq waiter).foreach { _ =>
      initialWaiters.remove(subscription.queryId)
    }
    if subscriptions.remove(subscription.queryId).nonEmpty then
      subscription.finish()
      if socket.nonEmpty then
        try
          modify(
            List(
              ConvexClient.json
                .createObjectNode()
                .put("type", "Remove")
                .put("queryId", subscription.queryId)
            )
          )
        catch
          // send() already retired the uncertain socket and scheduled recovery.
          case _: Exception => ()

  private def ensureOpen(): Unit =
    if closed then throw new IllegalStateException("Convex Live client is closed")

  private def submit(action: => Unit): Boolean =
    try
      owner.execute(() => action)
      true
    catch case _: java.util.concurrent.RejectedExecutionException => false

  private def onOwner[T](action: => T): T =
    val answer = new CompletableFuture[T]()
    submit {
      try answer.complete(action)
      catch case error: Throwable => answer.completeExceptionally(error)
    }
    await(answer, 3, "timed out waiting for Live owner")

  override def close(): Unit =
    if closed then return
    onOwner {
      closed = true
      reconnectScheduled = false
      connecting.foreach(_.cancel(true))
      connecting = None
      socket.foreach(_.abort())
      socket = None
      failInitialWaiters(new IllegalStateException("Convex Live client is closed"))
      subscriptions.values.foreach(_.finish())
      subscriptions.clear()
      ownerEvent("closed")
    }
    owner.shutdownNow()

object LiveClient:
  final case class Update(value: JsonNode, error: Exception, logs: List[String])

  private val Closed = Update(null, new IllegalStateException("Live subscription is closed"), Nil)
  @volatile private[convex] var testInitialBackoffMillis = 100L
  @volatile private[convex] var testMaxBackoffMillis = 15_000L
  @volatile private[convex] var testSubscribeTimeoutMillis = 5_000L
  @volatile private[convex] var testWriteTimeoutMillis = 3_000L
  @volatile private[convex] var testReconnectScheduled: Long => Unit = _ => ()
  @volatile private[convex] var testOwnerEvent: (String, String) => Unit = (_, _) => ()
  @volatile private[convex] var testSendText: (WebSocket, String) => CompletableFuture[WebSocket] =
    (socket, text) => socket.sendText(text, true)

  private def initialBackoffMillis: Long = testInitialBackoffMillis
  private def maxBackoffMillis: Long = testMaxBackoffMillis
  private def subscribeTimeoutMillis: Long = testSubscribeTimeoutMillis
  private def writeTimeoutMillis: Long = testWriteTimeoutMillis
  private def reconnectAttemptScheduled(delay: Long): Unit = testReconnectScheduled(delay)
  private def sendText(socket: WebSocket, text: String): CompletableFuture[WebSocket] =
    testSendText(socket, text)
  private def ownerEvent(event: String): Unit =
    testOwnerEvent(event, Thread.currentThread().getName)

  private def zeroVersion: JsonNode = ConvexClient.json
    .createObjectNode()
    .put("querySet", 0)
    .put("identity", 0)
    .put("ts", "AAAAAAAAAAA=")

  private def unwrap(error: Throwable): Throwable = error match
    case completion: CompletionException if completion.getCause != null => completion.getCause
    case execution: ExecutionException if execution.getCause != null    => execution.getCause
    case other                                                          => other

  private def await[T](
      future: java.util.concurrent.Future[T],
      seconds: Long,
      timeoutMessage: String
  ): T =
    try future.get(seconds, TimeUnit.SECONDS)
    catch
      case timeout: TimeoutException =>
        throw new TimeoutException(timeoutMessage)
      case execution: ExecutionException => throw unwrap(execution)

  private def awaitMillis[T](
      future: java.util.concurrent.Future[T],
      milliseconds: Long,
      timeoutMessage: String
  ): T =
    try future.get(milliseconds, TimeUnit.MILLISECONDS)
    catch
      case timeout: TimeoutException =>
        throw new TimeoutException(timeoutMessage)
      case execution: ExecutionException => throw unwrap(execution)

  final class Subscription private[convex] (
      manager: LiveClient,
      private[convex] val queryId: Int,
      private[convex] val path: String,
      private[convex] val args: JsonNode
  ) extends AutoCloseable:
    private val updates = new ArrayBlockingQueue[Update](17)
    private var closed = false
    private var lastValue: JsonNode = null

    private[convex] def sameAsLast(value: JsonNode): Boolean = synchronized {
      lastValue != null && lastValue.equals(value)
    }

    private[convex] def offer(update: Update): Unit = synchronized {
      if closed then return
      if update.error == null then lastValue = update.value.deepCopy()
      while updates.size() >= 16 do updates.poll()
      updates.offer(update)
    }

    private[convex] def finish(): Unit = synchronized {
      if closed then return
      closed = true
      updates.offer(Closed)
    }

    def nextUpdate(timeout: Duration): Update =
      val update = updates.poll(timeout.toMillis, TimeUnit.MILLISECONDS)
      if update == null then throw new TimeoutException("timed out waiting for Live update")
      if update eq Closed then throw new IllegalStateException("Live subscription is closed")
      update

    def next(timeout: Duration): JsonNode =
      val update = nextUpdate(timeout)
      if update.error != null then throw update.error
      update.value

    override def close(): Unit =
      val shouldUnsubscribe = synchronized(!closed)
      if shouldUnsubscribe then manager.unsubscribe(this)
