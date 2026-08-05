defmodule Convex.ClientTest do
  use ExUnit.Case, async: true

  alias Convex.{Client, FunctionError}

  test "documented HTTP query sends JSON, bearer auth, and preserves logs" do
    parent = self()

    {url, server} =
      start_http_server(fn request ->
        send(parent, {:request, request})
        {200, ~s({"status":"success","value":{"count":1},"logLines":["hello"]})}
      end)

    {:ok, client} = Client.start_link(url, bearer_token: "test-token")
    assert {:ok, result} = Client.query(client, "demo:state", %{"room" => "room-1"})
    assert result.value == %{"count" => 1}
    assert result.logs == ["hello"]

    assert_receive {:request, request}
    assert request =~ "POST /api/query HTTP/1.1"
    assert String.downcase(request) =~ "authorization: bearer test-token"
    assert request =~ ~s("format":"json")
    assert request =~ ~s("room":"room-1")

    Client.close(client)
    assert_receive {:server_done, ^server}
  end

  test "structured function failures keep their data and logs" do
    {url, server} =
      start_http_server(fn _request ->
        {560,
         ~s({"status":"error","errorMessage":"nope","errorData":{"code":"NOPE"},"logLines":["failed"]})}
      end)

    {:ok, client} = Client.start_link(url)
    assert {:error, %FunctionError{} = error} = Client.mutation(client, "demo:increment", %{})
    assert error.data == %{"code" => "NOPE"}
    assert error.logs == ["failed"]
    Client.close(client)
    assert_receive {:server_done, ^server}
  end

  test "bearer tokens can be replaced and cleared" do
    parent = self()

    {url, server} =
      start_http_server(
        fn request ->
          send(parent, {:auth_request, request})
          {200, ~s({"status":"success","value":null})}
        end,
        3
      )

    {:ok, client} = Client.start_link(url, bearer_token: "first-token")
    assert {:ok, _} = Client.query(client, "demo:state", %{})
    assert :ok = Client.set_auth(client, "replacement-token")
    assert {:ok, _} = Client.query(client, "demo:state", %{})
    assert :ok = Client.set_auth(client, "")
    assert {:ok, _} = Client.query(client, "demo:state", %{})

    assert_receive {:auth_request, first}
    assert_receive {:auth_request, second}
    assert_receive {:auth_request, third}
    assert String.downcase(first) =~ "authorization: bearer first-token"
    assert String.downcase(second) =~ "authorization: bearer replacement-token"
    refute String.downcase(third) =~ "authorization:"

    Client.close(client)
    assert_receive {:server_done, ^server}
  end

  test "arguments must be a named JSON object" do
    {:ok, client} = Client.start_link("https://example.convex.cloud")
    assert {:error, %ArgumentError{}} = Client.action(client, "demo:greet", ["elixir"])
    Client.close(client)
  end

  defp start_http_server(response_fun, request_count \\ 1) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    parent = self()

    server =
      spawn_link(fn ->
        Enum.each(1..request_count, fn _ ->
          {:ok, socket} = :gen_tcp.accept(listener)
          {:ok, request} = receive_http_request(socket)
          {status, body} = response_fun.(request)
          reason = if status == 200, do: "OK", else: "Convex Error"

          :ok =
            :gen_tcp.send(
              socket,
              "HTTP/1.1 #{status} #{reason}\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
            )

          :gen_tcp.close(socket)
        end)

        :gen_tcp.close(listener)
        send(parent, {:server_done, self()})
      end)

    {"http://127.0.0.1:#{port}", server}
  end

  defp receive_http_request(socket, accumulated \\ "") do
    with {:ok, chunk} <- :gen_tcp.recv(socket, 0, 2_000) do
      request = accumulated <> chunk

      case String.split(request, "\r\n\r\n", parts: 2) do
        [headers, body] ->
          content_length =
            Regex.run(~r/content-length:\s*(\d+)/i, headers, capture: :all_but_first)
            |> List.first()
            |> String.to_integer()

          if byte_size(body) >= content_length,
            do: {:ok, request},
            else: receive_http_request(socket, request)

        _ ->
          receive_http_request(socket, request)
      end
    end
  end
end
