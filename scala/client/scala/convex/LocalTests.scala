package convex

/** Fast language-local serialization checks, run in the Docker test target. */
object LocalTests:
  def main(args: Array[String]): Unit =
    val result = Adapter.resultEvent("query", ConvexClient.Result(ConvexClient.json.createObjectNode().put("count", 1), List("log")))
    require(result.path("value").path("count").asInt() == 1, s"result was $result")
    require(result.path("logs").size() == 1, s"logs were $result")
    val failed = Adapter.failure("", "subscription", new ConvexClient.FunctionError("query", "empty", ConvexClient.json.createObjectNode().put("code", "ROOM_EMPTY"), Nil))
    require(failed.path("type").asText() == "subscription" && !failed.has("id") && failed.path("error").path("data").path("code").asText() == "ROOM_EMPTY")
    println("scala local tests passed")
