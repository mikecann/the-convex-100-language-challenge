package convex

import com.fasterxml.jackson.databind.JsonNode
import com.fasterxml.jackson.databind.node.ObjectNode
import com.sun.net.httpserver.HttpServer
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.net.http.WebSocket
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.time.Duration
import java.util.Base64
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import scala.collection.mutable
import scala.jdk.CollectionConverters.*

/** Deterministic coverage for the failure modes required of a Live implementation. */
object LiveAcceptanceTests:
  private val Timeout = Duration.ofSeconds(5)

  def main(args: Array[String]): Unit =
    testAdapterSerialization()
    testHttpStructuredErrors()
    testBoundedNewestSixteen()
    testRelayBarriers()
    testLiveFlowUtf8ControlAndQueryRecovery()
    testFiveReconnectFailuresMetadataDedupAndBackoffReset()
    testSubscribeDuringReconnectBackoff()
    testFailedSubscribeDoesNotLeaveGhost()
    testHandshakeTimeoutDoesNotLeaveGhost()
    testProtocolAndTransportRecovery()
    testPartialFrameCloseIsBounded()
    testLateHandshakeSuccessIsAborted()
    testHandshakeCloseIsBounded()
    println("scala deterministic acceptance tests passed")

  private def testAdapterSerialization(): Unit =
    val result = Adapter.resultEvent(
      "query",
      ConvexClient.Result(
        ConvexClient.json.createObjectNode().put("count", 1),
        List("query log")
      )
    )
    check(result.path("value").path("count").asInt() == 1, "result lost its value")
    check(result.path("logs").path(0).asText() == "query log", "result lost logs")

    val noLogs = Adapter.resultEvent(
      "empty",
      ConvexClient.Result(ConvexClient.json.nullNode(), Nil)
    )
    check(noLogs.has("value") && noLogs.path("value").isNull, "JSON null was omitted")
    check(!noLogs.has("logs"), "empty logs were serialized")

    val function = Adapter.failure(
      "request",
      "",
      new ConvexClient.FunctionError(
        "query",
        "empty",
        ConvexClient.json.createObjectNode().put("code", "ROOM_EMPTY"),
        List("checked")
      )
    )
    check(
      function.path("error").path("name").asText() == "FunctionError",
      "function error lost its type"
    )
    check(
      function.path("error").path("data").path("code").asText() == "ROOM_EMPTY",
      "function error lost structured data"
    )
    check(!function.has("subscriptionId"), "absent subscriptionId became null")

    val protocol = Adapter.failure(
      "",
      "live",
      new ConvexClient.ProtocolError("bad transition")
    )
    check(!protocol.has("id"), "subscription error serialized an absent id")
    check(
      protocol.path("error").path("name").asText() == "ProtocolError",
      "protocol error lost its type"
    )
    val transport = Adapter.failure(
      "",
      "live",
      new ConvexClient.TransportError("live", new IllegalStateException("closed"))
    )
    check(
      transport.path("error").path("name").asText() == "TransportError",
      "transport error lost its type"
    )

    val input =
      """{"protocolVersion":1,"id":"hello","op":"hello"}
        |{"id":"close","op":"close"}
        |""".stripMargin
    val output = new ByteArrayOutputStream()
    Adapter.run(
      new java.io.ByteArrayInputStream(input.getBytes(StandardCharsets.UTF_8)),
      output,
      ""
    )
    val events = output.toString(StandardCharsets.UTF_8).linesIterator.toList
    check(events.size == 2, "adapter did not emit ready and closed")
    check(
      ConvexClient.json.readTree(events.head).path("language").asText() == "scala",
      "adapter hello reported the wrong language"
    )
    check(
      ConvexClient.json.readTree(events.last).path("type").asText() == "closed",
      "adapter close shape was wrong"
    )

  private def testHttpStructuredErrors(): Unit =
    val server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0)
    server.createContext(
      "/api/query",
      exchange =>
        val response =
          """{"status":"error","errorMessage":"empty","errorData":{"code":"ROOM_EMPTY"},"logLines":["checked"]}"""
        val bytes = response.getBytes(StandardCharsets.UTF_8)
        exchange.sendResponseHeaders(560, bytes.length)
        exchange.getResponseBody.write(bytes)
        exchange.close()
    )
    server.start()
    try
      val client = new ConvexClient(s"http://127.0.0.1:${server.getAddress.getPort}")
      try
        client.query("demo:requiresNonzero", ConvexClient.json.createObjectNode())
        fail("HTTP function error became success")
      catch
        case error: ConvexClient.FunctionError =>
          check(error.data.path("code").asText() == "ROOM_EMPTY", "HTTP error lost data")
          check(error.logs == List("checked"), "HTTP error lost logs")
      finally client.close()
    finally server.stop(0)

  private def testBoundedNewestSixteen(): Unit =
    val subscription = new LiveClient.Subscription(
      null,
      7,
      "demo:state",
      ConvexClient.json.createObjectNode()
    )
    (0 until 20).foreach(count =>
      subscription.offer(
        LiveClient.Update(
          ConvexClient.json.createObjectNode().put("count", count),
          null,
          Nil
        )
      )
    )
    (4 until 20).foreach(expected =>
      check(
        subscription.next(Duration.ofMillis(20)).path("count").asInt() == expected,
        s"bounded queue did not retain newest value $expected"
      )
    )
    expectTimeout(subscription.nextUpdate(Duration.ofMillis(20)))

  private def testRelayBarriers(): Unit =
    testRelayBarrier(replace = false)
    testRelayBarrier(replace = true)

  private def testRelayBarrier(replace: Boolean): Unit =
    val registry = new Adapter.RelayRegistry
    val old = new LiveClient.Subscription(
      null,
      1,
      "demo:state",
      ConvexClient.json.createObjectNode()
    )
    val replacement = new LiveClient.Subscription(
      null,
      2,
      "demo:state",
      ConvexClient.json.createObjectNode()
    )
    val outputBytes = new ByteArrayOutputStream()
    val output = new Adapter.Output(outputBytes)
    registry.registerAndWrite("same", old, output, event("old-ack"))
    outputBytes.reset()
    val relayPaused = new CountDownLatch(1)
    val releaseRelay = new CountDownLatch(1)
    val relayDone = new CountDownLatch(1)
    val stale = Adapter.subscriptionEvent(
      "same",
      LiveClient.Update(
        ConvexClient.json.createObjectNode().put("count", 99),
        null,
        Nil
      )
    )
    val relay = new Thread(() =>
      relayPaused.countDown()
      releaseRelay.await()
      registry.publishIfActive("same", old, output, stale)
      relayDone.countDown()
    )
    relay.start()
    check(relayPaused.await(1, TimeUnit.SECONDS), "relay did not pause after dequeue")
    check(registry.remove("same").contains(old), "old relay was not invalidated")
    if replace then registry.registerAndWrite("same", replacement, output, event("replacement-ack"))
    else registry.writeBarrier(output, event("unsubscribe-ack"))
    releaseRelay.countDown()
    check(relayDone.await(1, TimeUnit.SECONDS), "paused relay did not finish")
    val rendered = outputBytes.toString(StandardCharsets.UTF_8)
    check(!rendered.contains("99"), "stale relay crossed its acknowledgement")
    check(
      rendered.contains(if replace then "replacement-ack" else "unsubscribe-ack"),
      "barrier acknowledgement was not emitted"
    )

  private def testLiveFlowUtf8ControlAndQueryRecovery(): Unit =
    val listener = new ServerSocket(0)
    val serverFailure = new AtomicReference[Throwable]()
    val ownerThreads = new ConcurrentLinkedQueue[String]()
    LiveClient.testOwnerEvent = (_, thread) => ownerThreads.add(thread)
    val server = startServer("scala-live-flow", serverFailure) {
      val socket = listener.accept()
      try
        handshake(socket)
        val connect = readClientJson(socket)
        check(connect.path("type").asText() == "Connect", "missing Connect")
        val add = readClientJson(socket)
        check(
          add.path("modifications").path(0).path("type").asText() == "Add",
          "missing Add"
        )
        val queryId = add.path("modifications").path(0).path("queryId").asInt()
        val first = transition(
          zeroVersion,
          version(1, 1),
          updated(queryId, objectValue("count", 0).put("text", "雪"))
        ).toString
        writeFragmentedUtf8WithPing(socket, first, "雪")
        writeText(
          socket,
          transition(
            version(1, 1),
            version(1, 2),
            updated(queryId, ConvexClient.json.nullNode())
          ).toString
        )
        writeText(
          socket,
          transition(
            version(1, 2),
            version(1, 3),
            updated(queryId, objectValue("count", 1))
          ).toString
        )
        writeText(
          socket,
          transition(
            version(1, 3),
            version(1, 4),
            failed(queryId, "temporary", "TEMP")
          ).toString
        )
        writeText(
          socket,
          transition(
            version(1, 4),
            version(1, 5),
            updated(queryId, objectValue("count", 2))
          ).toString
        )
        val remove = readClientJson(socket)
        check(
          remove.path("modifications").path(0).path("type").asText() == "Remove",
          "unsubscribe did not send Remove"
        )
      finally socket.close()
    }

    try
      val live = new LiveClient(url(listener))
      try
        val subscription = live.subscribe("demo:state", ConvexClient.json.createObjectNode())
        check(subscription.next(Timeout).path("text").asText() == "雪", "fragmented UTF-8 failed")
        check(subscription.next(Timeout).isNull, "JSON null Live value was lost")
        check(subscription.next(Timeout).path("count").asInt() == 1, "external update failed")
        val queryFailure = subscription.nextUpdate(Timeout)
        check(
          queryFailure.error.isInstanceOf[ConvexClient.FunctionError],
          "QueryFailed was not structured"
        )
        val function = queryFailure.error.asInstanceOf[ConvexClient.FunctionError]
        check(function.data.path("code").asText() == "TEMP", "QueryFailed lost data")
        check(
          subscription.next(Timeout).path("count").asInt() == 2,
          "QueryFailed stranded the subscription"
        )
        subscription.close()
      finally live.close()
      join(server, serverFailure)
      check(ownerThreads.asScala.nonEmpty, "owner instrumentation saw no state changes")
      check(
        ownerThreads.asScala.toSet == Set("convex-scala-live-owner"),
        s"socket state escaped the owner: ${ownerThreads.asScala.toSet}"
      )
    finally
      LiveClient.testOwnerEvent = (_, _) => ()
      listener.close()

  private def testFiveReconnectFailuresMetadataDedupAndBackoffReset(): Unit =
    val listener = new ServerSocket(0)
    val serverFailure = new AtomicReference[Throwable]()
    val delays = new ConcurrentLinkedQueue[Long]()
    LiveClient.testInitialBackoffMillis = 5
    LiveClient.testMaxBackoffMillis = 80
    LiveClient.testReconnectScheduled = delay => delays.add(delay)
    val server = startServer("scala-reconnect", serverFailure) {
      val initial = listener.accept()
      try
        handshake(initial)
        val connect = readClientJson(initial)
        check(connect.path("connectionCount").asInt() == 0, "initial connectionCount")
        check(connect.path("lastCloseReason").asText() == "InitialConnect", "initial reason")
        val add = readClientJson(initial)
        val queryId = add.path("modifications").path(0).path("queryId").asInt()
        writeText(
          initial,
          transition(zeroVersion, version(1, 1), updated(queryId, objectValue("count", 0))).toString
        )
        waitForEof(initial)
      finally initial.close()

      (1 to 5).foreach { _ =>
        val rejected = listener.accept()
        try
          readHeaders(rejected.getInputStream)
          rejected.getOutputStream.write(
            "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n"
              .getBytes(StandardCharsets.US_ASCII)
          )
          rejected.getOutputStream.flush()
        finally rejected.close()
      }

      val restored = listener.accept()
      try
        handshake(restored)
        val connect = readClientJson(restored)
        check(
          connect.path("connectionCount").asInt() == 6,
          "failed reconnect handshakes were not counted"
        )
        check(
          connect.path("lastCloseReason").asText().nonEmpty,
          "reconnect omitted lastCloseReason"
        )
        check(
          connect.path("maxObservedTimestamp").asText() == timestamp(1),
          "reconnect omitted maxObservedTimestamp"
        )
        val add = readClientJson(restored)
        check(
          add.path("modifications").path(0).path("type").asText() == "Add",
          "successful reconnect did not restore Add"
        )
        val queryId = add.path("modifications").path(0).path("queryId").asInt()
        writeText(
          restored,
          transition(zeroVersion, version(1, 2), updated(queryId, objectValue("count", 0))).toString
        )
        Thread.sleep(80)
        writeText(
          restored,
          transition(
            version(1, 2),
            version(1, 3),
            updated(queryId, objectValue("count", 1))
          ).toString
        )
        writeClose(restored, 1001, "fixture close")
        waitForEof(restored)
      finally restored.close()

      val afterHealthy = listener.accept()
      try
        handshake(afterHealthy)
        val connect = readClientJson(afterHealthy)
        check(connect.path("connectionCount").asInt() == 7, "healthy close count was wrong")
        check(
          connect.path("lastCloseReason").asText() == "ServerClosed:1001",
          "healthy close reason was wrong"
        )
        check(
          connect.path("maxObservedTimestamp").asText() == timestamp(3),
          "healthy reconnect timestamp was wrong"
        )
        val add = readClientJson(afterHealthy)
        val queryId = add.path("modifications").path(0).path("queryId").asInt()
        writeText(
          afterHealthy,
          transition(zeroVersion, version(1, 4), updated(queryId, objectValue("count", 1))).toString
        )
        waitForEof(afterHealthy)
      finally afterHealthy.close()
    }

    try
      val live = new LiveClient(url(listener))
      try
        val subscription = live.subscribe("demo:state", ConvexClient.json.createObjectNode())
        check(subscription.next(Timeout).path("count").asInt() == 0, "initial reconnect value")
        live.debugDisconnect()
        check(
          subscription.next(Timeout).path("count").asInt() == 1,
          "unchanged rehydration was not suppressed before external update"
        )
        val transport = subscription.nextUpdate(Timeout)
        check(
          transport.error.isInstanceOf[ConvexClient.TransportError],
          "healthy server close did not emit TransportError"
        )
        eventually(Timeout) {
          delays.asScala.toList.size >= 7
        }
        val observed = delays.asScala.toList.take(7)
        check(
          observed == List(5L, 10L, 20L, 40L, 80L, 80L, 5L),
          s"reconnect backoff/reset was $observed"
        )
        expectTimeout(subscription.nextUpdate(Duration.ofMillis(120)))
        subscription.close()
      finally live.close()
      join(server, serverFailure)
    finally
      LiveClient.testInitialBackoffMillis = 100
      LiveClient.testMaxBackoffMillis = 15_000
      LiveClient.testReconnectScheduled = _ => ()
      listener.close()

  private def testSubscribeDuringReconnectBackoff(): Unit =
    val listener = new ServerSocket(0)
    val serverFailure = new AtomicReference[Throwable]()
    val reconnectScheduled = new CountDownLatch(1)
    LiveClient.testInitialBackoffMillis = 40
    LiveClient.testMaxBackoffMillis = 80
    LiveClient.testReconnectScheduled = _ => reconnectScheduled.countDown()
    val server = startServer("scala-subscribe-during-backoff", serverFailure) {
      val initial = listener.accept()
      val originalQueryId =
        try
          handshake(initial)
          readClientJson(initial)
          val add = readClientJson(initial)
          val queryId = add.path("modifications").path(0).path("queryId").asInt()
          writeText(
            initial,
            transition(
              zeroVersion,
              version(1, 1),
              updated(queryId, objectValue("count", 0))
            ).toString
          )
          writeClose(initial, 1001, "reconnect for pending subscribe")
          waitForEof(initial)
          queryId
        finally initial.close()

      val rejected = listener.accept()
      try
        readHeaders(rejected.getInputStream)
        rejected.getOutputStream.write(
          "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n"
            .getBytes(StandardCharsets.US_ASCII)
        )
        rejected.getOutputStream.flush()
      finally rejected.close()

      val recovered = listener.accept()
      try
        handshake(recovered)
        val connect = readClientJson(recovered)
        check(
          connect.path("connectionCount").asInt() == 2,
          "failed reconnect was not included in connectionCount"
        )
        val add = readClientJson(recovered)
        val modifications = add.path("modifications")
        check(modifications.size() == 2, "pending subscribe did not join reconnect Add")
        val queryIds = modifications.elements().asScala.map(_.path("queryId").asInt()).toList
        check(queryIds.contains(originalQueryId), "existing subscription vanished during reconnect")
        writeText(
          recovered,
          transition(
            zeroVersion,
            version(1, 2),
            updated(queryIds.head, objectValue("count", 1)),
            updated(queryIds.last, objectValue("count", 2))
          ).toString
        )
        waitForEof(recovered)
      finally recovered.close()
    }

    try
      val live = new LiveClient(url(listener))
      try
        val existing = live.subscribe("demo:state", ConvexClient.json.createObjectNode())
        check(existing.next(Timeout).path("count").asInt() == 0, "initial value missing")
        check(
          existing.nextUpdate(Timeout).error.isInstanceOf[ConvexClient.TransportError],
          "server close did not reach existing subscription"
        )
        check(reconnectScheduled.await(1, TimeUnit.SECONDS), "reconnect was not scheduled")
        val replacement = new AtomicReference[LiveClient.Subscription]()
        val subscribeFailure = new AtomicReference[Throwable]()
        val subscribe = new Thread(() =>
          try
            replacement.set(
              live.subscribe("demo:other", ConvexClient.json.createObjectNode())
            )
          catch case error: Throwable => subscribeFailure.set(error)
        )
        subscribe.start()
        subscribe.join(Timeout.toMillis)
        check(!subscribe.isAlive, "subscribe during reconnect never completed")
        check(subscribeFailure.get() == null, "subscribe during reconnect failed")
        val added = replacement.get()
        check(added != null, "subscribe during reconnect returned no subscription")
        check(existing.next(Timeout).path("count").asInt() == 1, "existing query was stranded")
        check(added.next(Timeout).path("count").asInt() == 2, "pending query was stranded")
        added.close()
        existing.close()
      finally live.close()
      join(server, serverFailure)
    finally
      LiveClient.testInitialBackoffMillis = 100
      LiveClient.testMaxBackoffMillis = 15_000
      LiveClient.testReconnectScheduled = _ => ()
      listener.close()

  private def testFailedSubscribeDoesNotLeaveGhost(): Unit =
    testFailedSubscribeDoesNotLeaveGhost(writeTimeout = false)
    testFailedSubscribeDoesNotLeaveGhost(writeTimeout = true)

  private def testFailedSubscribeDoesNotLeaveGhost(writeTimeout: Boolean): Unit =
    val listener = new ServerSocket(0)
    val serverFailure = new AtomicReference[Throwable]()
    val retired = new CountDownLatch(1)
    val server = startServer(
      if writeTimeout then "scala-write-timeout" else "scala-write-failure",
      serverFailure
    ) {
      val initial = listener.accept()
      val originalQueryId =
        try
          handshake(initial)
          readClientJson(initial)
          val add = readClientJson(initial)
          val queryId = add.path("modifications").path(0).path("queryId").asInt()
          writeText(
            initial,
            transition(
              zeroVersion,
              version(1, 1),
              updated(queryId, objectValue("count", 0))
            ).toString
          )
          waitForEof(initial)
          retired.countDown()
          queryId
        finally initial.close()

      val recovered = listener.accept()
      try
        handshake(recovered)
        val connect = readClientJson(recovered)
        check(connect.path("connectionCount").asInt() == 1, "write failure was not counted")
        val add = readClientJson(recovered)
        val modifications = add.path("modifications")
        check(modifications.size() == 1, "failed subscribe left a ghost Add")
        val queryId = modifications.path(0).path("queryId").asInt()
        check(queryId == originalQueryId, "reconnect retained the failed subscription")
        writeText(
          recovered,
          transition(zeroVersion, version(1, 2), updated(queryId, objectValue("count", 1))).toString
        )
        waitForEof(recovered)
      finally recovered.close()
    }

    val live = new LiveClient(url(listener))
    try
      val existing = live.subscribe("demo:state", ConvexClient.json.createObjectNode())
      check(existing.next(Timeout).path("count").asInt() == 0, "initial value missing")
      val failNextWrite = new AtomicBoolean(true)
      if writeTimeout then LiveClient.testWriteTimeoutMillis = 30
      LiveClient.testSendText = (socket, text) =>
        if failNextWrite.compareAndSet(true, false) then
          if writeTimeout then new CompletableFuture[WebSocket]()
          else
            CompletableFuture.failedFuture[WebSocket](
              new IllegalStateException("injected sendText failure")
            )
        else socket.sendText(text, true)
      try
        live.subscribe("demo:ghost", ConvexClient.json.createObjectNode())
        fail("failed sendText became a successful subscription")
      catch
        case error: ConvexClient.TransportError =>
          check(error.operation == "live write", "write failure lost transport operation")
      finally
        LiveClient.testSendText = (socket, text) => socket.sendText(text, true)
        LiveClient.testWriteTimeoutMillis = 3_000
      check(retired.await(1, TimeUnit.SECONDS), "uncertain write socket was not retired")
      check(
        existing.nextUpdate(Timeout).error.isInstanceOf[ConvexClient.TransportError],
        "write failure was not delivered to the existing subscription"
      )
      check(existing.next(Timeout).path("count").asInt() == 1, "existing query was stranded")
      existing.close()
    finally
      LiveClient.testSendText = (socket, text) => socket.sendText(text, true)
      LiveClient.testWriteTimeoutMillis = 3_000
      live.close()
    join(server, serverFailure)
    listener.close()

  private def testHandshakeTimeoutDoesNotLeaveGhost(): Unit =
    val listener = new ServerSocket(0)
    val serverFailure = new AtomicReference[Throwable]()
    val requestSeen = new CountDownLatch(1)
    val releaseHandshake = new CountDownLatch(1)
    val server = startServer("scala-subscribe-handshake-timeout", serverFailure) {
      val socket = listener.accept()
      try
        val headers = readHeaders(socket.getInputStream)
        requestSeen.countDown()
        releaseHandshake.await(Timeout.toMillis, TimeUnit.MILLISECONDS)
        completeHandshake(socket, headers)
        val connect = readClientJson(socket)
        check(connect.path("type").asText() == "Connect", "late handshake omitted Connect")
        socket.setSoTimeout(200)
        try
          val unexpected = readClientJson(socket)
          fail(s"timed-out subscribe left a ghost frame: $unexpected")
        catch case _: SocketTimeoutException => ()
      finally socket.close()
    }

    val live = new LiveClient(url(listener))
    LiveClient.testSubscribeTimeoutMillis = 40
    try
      check(!requestSeen.await(20, TimeUnit.MILLISECONDS), "handshake started before subscribe")
      try
        live.subscribe("demo:ghost", ConvexClient.json.createObjectNode())
        fail("stalled handshake became a successful subscription")
      catch case _: java.util.concurrent.TimeoutException => ()
      check(requestSeen.await(1, TimeUnit.SECONDS), "handshake request was not observed")
      releaseHandshake.countDown()
      join(server, serverFailure)
    finally
      releaseHandshake.countDown()
      LiveClient.testSubscribeTimeoutMillis = 5_000
      live.close()
      listener.close()

  private def testProtocolAndTransportRecovery(): Unit =
    val listener = new ServerSocket(0)
    val serverFailure = new AtomicReference[Throwable]()
    val server = startServer("scala-error-recovery", serverFailure) {
      val protocolSocket = listener.accept()
      try
        handshake(protocolSocket)
        readClientJson(protocolSocket)
        val add = readClientJson(protocolSocket)
        val queryId = add.path("modifications").path(0).path("queryId").asInt()
        val unknown = ConvexClient.json
          .createObjectNode()
          .put("type", "UnknownModification")
          .put("queryId", queryId)
        writeText(
          protocolSocket,
          transition(zeroVersion, version(1, 1), unknown).toString
        )
        waitForEof(protocolSocket)
      finally protocolSocket.close()

      val transportSocket = listener.accept()
      try
        handshake(transportSocket)
        readClientJson(transportSocket)
        val add = readClientJson(transportSocket)
        val queryId = add.path("modifications").path(0).path("queryId").asInt()
        writeText(
          transportSocket,
          transition(zeroVersion, version(1, 2), updated(queryId, objectValue("count", 7))).toString
        )
        // Let the valid transition commit before forcing the transport reset.
        Thread.sleep(75)
        transportSocket.setSoLinger(true, 0)
      finally transportSocket.close()

      val recovered = listener.accept()
      try
        handshake(recovered)
        readClientJson(recovered)
        val add = readClientJson(recovered)
        val queryId = add.path("modifications").path(0).path("queryId").asInt()
        writeText(
          recovered,
          transition(zeroVersion, version(1, 3), updated(queryId, objectValue("count", 8))).toString
        )
        readClientJson(recovered)
      finally recovered.close()
    }
    val live = new LiveClient(url(listener))
    try
      val subscription = live.subscribe("demo:state", ConvexClient.json.createObjectNode())
      check(
        subscription.nextUpdate(Timeout).error.isInstanceOf[ConvexClient.ProtocolError],
        "protocol error vanished"
      )
      check(subscription.next(Timeout).path("count").asInt() == 7, "protocol recovery failed")
      check(
        subscription.nextUpdate(Timeout).error.isInstanceOf[ConvexClient.TransportError],
        "transport error vanished"
      )
      check(subscription.next(Timeout).path("count").asInt() == 8, "transport recovery failed")
      subscription.close()
    finally live.close()
    join(server, serverFailure)
    listener.close()

  private def testPartialFrameCloseIsBounded(): Unit =
    val listener = new ServerSocket(0)
    val serverFailure = new AtomicReference[Throwable]()
    val partialSent = new CountDownLatch(1)
    val server = startServer("scala-partial-close", serverFailure) {
      val socket = listener.accept()
      try
        handshake(socket)
        readClientJson(socket)
        readClientJson(socket)
        val output = socket.getOutputStream
        output.write(Array[Byte](0x81.toByte, 100.toByte, '{'.toByte, '"'.toByte, 't'.toByte))
        output.flush()
        partialSent.countDown()
        waitForEof(socket)
      finally socket.close()
    }
    val live = new LiveClient(url(listener))
    try
      live.subscribe("demo:state", ConvexClient.json.createObjectNode())
      check(partialSent.await(1, TimeUnit.SECONDS), "partial frame was not sent")
      val started = System.nanoTime()
      live.close()
      val elapsed = Duration.ofNanos(System.nanoTime() - started)
      check(elapsed.compareTo(Duration.ofSeconds(1)) < 0, s"partial-frame close took $elapsed")
    finally live.close()
    join(server, serverFailure)
    listener.close()

  private def testHandshakeCloseIsBounded(): Unit =
    val listener = new ServerSocket(0)
    val serverFailure = new AtomicReference[Throwable]()
    val requestSeen = new CountDownLatch(1)
    val releaseServer = new CountDownLatch(1)
    val cleanupAccepted = new CountDownLatch(1)
    val cleanupStarted = new CountDownLatch(1)
    val releaseCleanup = new CountDownLatch(1)
    LiveClient.testCleanupSubmitted = accepted => if accepted then cleanupAccepted.countDown()
    LiveClient.testBeforeOwnerCloseReturns = () =>
      cleanupAccepted.await(Timeout.toMillis, TimeUnit.MILLISECONDS)
    LiveClient.testBeforeDiscardSubscription = () =>
      cleanupStarted.countDown()
      releaseCleanup.await(Timeout.toMillis, TimeUnit.MILLISECONDS)
    val server = startServer("scala-handshake-close", serverFailure) {
      val socket = listener.accept()
      try
        readHeaders(socket.getInputStream)
        requestSeen.countDown()
        releaseServer.await(Timeout.toMillis, TimeUnit.MILLISECONDS)
      finally socket.close()
    }
    val live = new LiveClient(url(listener))
    val subscribeFailure = new AtomicReference[Throwable]()
    val subscribe = new Thread(() =>
      try
        live.subscribe("demo:state", ConvexClient.json.createObjectNode())
        ()
      catch case error: Throwable => subscribeFailure.set(error)
    )
    subscribe.start()
    try
      check(requestSeen.await(1, TimeUnit.SECONDS), "handshake request did not arrive")
      val closeFailure = new AtomicReference[Throwable]()
      val close = new Thread(() =>
        try live.close()
        catch case error: Throwable => closeFailure.set(error)
      )
      val started = System.nanoTime()
      close.start()
      check(cleanupStarted.await(1, TimeUnit.SECONDS), "accepted cleanup did not start")
      check(close.isAlive, "close discarded its accepted cleanup task")
      releaseCleanup.countDown()
      close.join(1_000)
      check(!close.isAlive, "close did not pass its owner drain barrier")
      check(closeFailure.get() == null, "close failed while draining accepted cleanup")
      subscribe.join(1_000)
      check(!subscribe.isAlive, "pending subscribe survived close")
      check(subscribeFailure.get() != null, "pending subscribe did not fail")
      val elapsed = Duration.ofNanos(System.nanoTime() - started)
      check(elapsed.compareTo(Duration.ofSeconds(1)) < 0, s"handshake close took $elapsed")
    finally
      releaseCleanup.countDown()
      releaseServer.countDown()
      live.close()
      LiveClient.testBeforeDiscardSubscription = () => ()
      LiveClient.testCleanupSubmitted = _ => ()
      LiveClient.testBeforeOwnerCloseReturns = () => ()
    join(server, serverFailure)
    listener.close()

  private def testLateHandshakeSuccessIsAborted(): Unit =
    val future = new NonCancellingFuture[WebSocket]()
    val connectStarted = new CountDownLatch(1)
    val socket = new TrackingWebSocket()
    LiveClient.testConnectWebSocket = (_, _, _) =>
      connectStarted.countDown()
      future
    val live = new LiveClient("http://127.0.0.1:1")
    val subscribeFailure = new AtomicReference[Throwable]()
    val subscribe = new Thread(() =>
      try
        live.subscribe("demo:state", ConvexClient.json.createObjectNode())
        ()
      catch case error: Throwable => subscribeFailure.set(error)
    )
    subscribe.start()
    try
      check(connectStarted.await(1, TimeUnit.SECONDS), "controlled handshake did not start")
      live.close()
      subscribe.join(1_000)
      check(!subscribe.isAlive, "controlled subscribe survived close")
      check(subscribeFailure.get() != null, "controlled subscribe did not fail")
      check(future.complete(socket), "controlled handshake did not complete successfully")
      check(socket.aborted.await(1, TimeUnit.SECONDS), "late successful socket leaked after close")
    finally
      LiveClient.testConnectWebSocket = (http, endpoint, listener) =>
        http
          .newWebSocketBuilder()
          .connectTimeout(Duration.ofSeconds(3))
          .header("Convex-Client", "scala-0.1.0")
          .buildAsync(endpoint, listener)
      live.close()

  private final class NonCancellingFuture[T] extends CompletableFuture[T]:
    override def cancel(mayInterruptIfRunning: Boolean): Boolean = false

  private final class TrackingWebSocket extends WebSocket:
    val aborted = new CountDownLatch(1)

    override def sendText(data: CharSequence, last: Boolean): CompletableFuture[WebSocket] =
      CompletableFuture.completedFuture(this)

    override def sendBinary(data: ByteBuffer, last: Boolean): CompletableFuture[WebSocket] =
      CompletableFuture.completedFuture(this)

    override def sendPing(message: ByteBuffer): CompletableFuture[WebSocket] =
      CompletableFuture.completedFuture(this)

    override def sendPong(message: ByteBuffer): CompletableFuture[WebSocket] =
      CompletableFuture.completedFuture(this)

    override def sendClose(statusCode: Int, reason: String): CompletableFuture[WebSocket] =
      CompletableFuture.completedFuture(this)

    override def request(n: Long): Unit = ()
    override def getSubprotocol(): String = ""
    override def isOutputClosed(): Boolean = aborted.getCount == 0
    override def isInputClosed(): Boolean = aborted.getCount == 0
    override def abort(): Unit = aborted.countDown()

  private def startServer(
      name: String,
      failure: AtomicReference[Throwable]
  )(body: => Unit): Thread =
    val runnable = new Runnable:
      override def run(): Unit =
        try body
        catch case error: Throwable => failure.set(error)
    val thread = new Thread(runnable, name)
    thread.start()
    thread

  private def join(thread: Thread, failure: AtomicReference[Throwable]): Unit =
    thread.join(Timeout.toMillis)
    check(!thread.isAlive, s"${thread.getName} did not finish")
    if failure.get() != null then
      throw new AssertionError(s"${thread.getName} failed", failure.get())

  private def url(listener: ServerSocket): String =
    s"http://127.0.0.1:${listener.getLocalPort}"

  private def handshake(socket: Socket): Unit =
    val headers = readHeaders(socket.getInputStream)
    completeHandshake(socket, headers)

  private def completeHandshake(socket: Socket, headers: String): Unit =
    val key = headers
      .split("\r\n")
      .find(_.toLowerCase.startsWith("sec-websocket-key:"))
      .map(_.split(":", 2)(1).trim)
      .getOrElse(throw new IllegalStateException("handshake omitted WebSocket key"))
    val accept = Base64.getEncoder.encodeToString(
      MessageDigest
        .getInstance("SHA-1")
        .digest(
          (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
            .getBytes(StandardCharsets.US_ASCII)
        )
    )
    val response =
      s"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: $accept\r\n\r\n"
    socket.getOutputStream.write(response.getBytes(StandardCharsets.US_ASCII))
    socket.getOutputStream.flush()

  private def readHeaders(input: InputStream): String =
    val bytes = new ByteArrayOutputStream()
    var matched = 0
    while matched < 4 do
      val value = input.read()
      if value < 0 then throw new IllegalStateException("EOF during HTTP handshake")
      bytes.write(value)
      matched = matched match
        case 0 => if value == '\r' then 1 else 0
        case 1 => if value == '\n' then 2 else 0
        case 2 => if value == '\r' then 3 else 0
        case _ => if value == '\n' then 4 else 0
    bytes.toString(StandardCharsets.US_ASCII)

  private final case class Frame(opcode: Int, payload: Array[Byte])

  private def readClientJson(socket: Socket): JsonNode =
    var frame = readClientFrame(socket.getInputStream)
    while frame.opcode != 1 do frame = readClientFrame(socket.getInputStream)
    ConvexClient.json.readTree(new String(frame.payload, StandardCharsets.UTF_8))

  private def readClientFrame(input: InputStream): Frame =
    val first = input.read()
    val second = input.read()
    if first < 0 || second < 0 then throw new IllegalStateException("EOF in WebSocket frame")
    var length = second & 0x7f
    if length == 126 then length = (input.read() << 8) | input.read()
    else if length == 127 then
      var large = 0L
      (0 until 8).foreach(_ => large = (large << 8) | input.read())
      length = Math.toIntExact(large)
    check((second & 0x80) != 0, "client WebSocket frame was not masked")
    val mask = input.readNBytes(4)
    val payload = input.readNBytes(length)
    check(payload.length == length, "short client WebSocket frame")
    payload.indices.foreach(index => payload(index) = (payload(index) ^ mask(index % 4)).toByte)
    Frame(first & 0x0f, payload)

  private def writeText(socket: Socket, text: String): Unit =
    writeFrame(socket.getOutputStream, 0x81, text.getBytes(StandardCharsets.UTF_8))

  private def writeClose(socket: Socket, status: Int, reason: String): Unit =
    val reasonBytes = reason.getBytes(StandardCharsets.UTF_8)
    val payload = Array((status >>> 8).toByte, status.toByte) ++ reasonBytes
    writeFrame(socket.getOutputStream, 0x88, payload)

  private def writeFragmentedUtf8WithPing(
      socket: Socket,
      text: String,
      splitAt: String
  ): Unit =
    val bytes = text.getBytes(StandardCharsets.UTF_8)
    val needle = splitAt.getBytes(StandardCharsets.UTF_8)
    val offset = bytes.indices
      .find(index =>
        index + needle.length <= bytes.length &&
          bytes.slice(index, index + needle.length).sameElements(needle)
      )
      .getOrElse(throw new IllegalArgumentException("split marker missing"))
    val split = offset + 1
    writeFrame(socket.getOutputStream, 0x01, bytes.take(split))
    writeFrame(socket.getOutputStream, 0x89, "ping".getBytes(StandardCharsets.UTF_8))
    writeFrame(socket.getOutputStream, 0x80, bytes.drop(split))

  private def writeFrame(output: OutputStream, first: Int, payload: Array[Byte]): Unit =
    output.write(first)
    if payload.length < 126 then output.write(payload.length)
    else
      output.write(126)
      output.write(payload.length >>> 8)
      output.write(payload.length)
    output.write(payload)
    output.flush()

  private def waitForEof(socket: Socket): Unit =
    socket.setSoTimeout(Timeout.toMillis.toInt)
    while socket.getInputStream.read() != -1 do ()

  private def zeroVersion: ObjectNode = version(0, 0)

  private def timestamp(stamp: Int): String = s"scala-ts-$stamp"

  private def version(querySet: Int, stamp: Int): ObjectNode =
    ConvexClient.json
      .createObjectNode()
      .put("querySet", querySet)
      .put("identity", 0)
      .put("ts", if stamp == 0 then "AAAAAAAAAAA=" else timestamp(stamp))

  private def transition(
      start: JsonNode,
      end: JsonNode,
      modifications: JsonNode*
  ): ObjectNode =
    val message = ConvexClient.json.createObjectNode().put("type", "Transition")
    message.set("startVersion", start)
    message.set("endVersion", end)
    val array = message.putArray("modifications")
    modifications.foreach(array.add)
    message

  private def updated(queryId: Int, value: JsonNode): ObjectNode =
    val update = ConvexClient.json
      .createObjectNode()
      .put("type", "QueryUpdated")
      .put("queryId", queryId)
    update.set("value", value)
    update.putArray("logLines")
    update

  private def failed(queryId: Int, message: String, code: String): ObjectNode =
    val failure = ConvexClient.json
      .createObjectNode()
      .put("type", "QueryFailed")
      .put("queryId", queryId)
      .put("errorMessage", message)
    failure.set("errorData", ConvexClient.json.createObjectNode().put("code", code))
    failure.putArray("logLines").add("failed")
    failure

  private def objectValue(field: String, value: Int): ObjectNode =
    ConvexClient.json.createObjectNode().put(field, value)

  private def event(id: String): ObjectNode =
    ConvexClient.json.createObjectNode().put("type", "ack").put("id", id)

  private def eventually(timeout: Duration)(condition: => Boolean): Unit =
    val deadline = System.nanoTime() + timeout.toNanos
    while !condition && System.nanoTime() < deadline do Thread.sleep(5)
    check(condition, "condition did not become true before deadline")

  private def expectTimeout(action: => Any): Unit =
    try
      action
      fail("operation did not time out")
    catch case _: java.util.concurrent.TimeoutException => ()

  private def check(condition: Boolean, message: String): Unit =
    if !condition then throw new AssertionError(message)

  private def fail(message: String): Nothing = throw new AssertionError(message)
