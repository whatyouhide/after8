defmodule MintPool.SingleHost.HTTP2Test do
  use ExUnit.Case

  import Mint.HTTP2.Frame

  alias MintPool.SingleHost.HTTP2
  alias MintPool.Error

  alias MintPool.HTTP2.TestServer

  defmacrop assert_recv_frames(frames) when is_list(frames) do
    quote do: unquote(frames) = recv_next_frames(unquote(length(frames)))
  end

  test "request/response" do
    {:ok, pool} =
      start_server_and_connect_with(fn port ->
        HTTP2.start_link(
          scheme: :https,
          host: "localhost",
          port: port,
          transport_opts: [verify: :verify_none]
        )
      end)

    assert {:ok, ref} = HTTP2.stream_request(pool, "GET", "/", [])

    assert_recv_frames [headers(stream_id: stream_id)]

    hbf = server_encode_headers([{":status", "200"}])

    server_send_frames([
      headers(stream_id: stream_id, hbf: hbf, flags: set_flags(:headers, [:end_headers])),
      data(stream_id: stream_id, data: "hello to you", flags: set_flags(:data, [:end_stream]))
    ])

    assert receive_responses_until_done_or_error(ref) == [
             {:status, ref, 200},
             {:headers, ref, []},
             {:data, ref, "hello to you"},
             {:done, ref}
           ]
  end

  test "errors such as :max_header_list_size_reached are returned to the caller" do
    server_settings = [max_header_list_size: 5]

    {:ok, pool} =
      start_server_and_connect_with([server_settings: server_settings], fn port ->
        HTTP2.start_link(
          scheme: :https,
          host: "localhost",
          port: port,
          transport_opts: [verify: :verify_none]
        )
      end)

    assert {:error, error} = HTTP2.stream_request(pool, "GET", "/", [{"foo", "bar"}])
    assert %Mint.HTTPError{reason: {:max_header_list_size_exceeded, _, _}} = error
  end

  @tag :capture_log
  test "if server sends GOAWAY and then replies, we get the replies but are closed for writing" do
    {:ok, pool} =
      start_server_and_connect_with(fn port ->
        HTTP2.start_link(
          scheme: :https,
          host: "localhost",
          port: port,
          transport_opts: [verify: :verify_none]
        )
      end)

    assert {:ok, ref} = HTTP2.stream_request(pool, "GET", "/", [])

    assert_recv_frames [headers(stream_id: stream_id)]

    hbf = server_encode_headers([{":status", "200"}])

    server_send_frames([
      goaway(last_stream_id: stream_id, error_code: :no_error, debug_data: "all good"),
      headers(stream_id: stream_id, hbf: hbf, flags: set_flags(:headers, [:end_headers])),
      data(stream_id: stream_id, data: "hello", flags: set_flags(:data, [:end_stream]))
    ])

    assert receive_responses_until_done_or_error(ref) == [
             {:status, ref, 200},
             {:headers, ref, []},
             {:data, ref, "hello"},
             {:done, ref}
           ]

    # We can't send any more requests since the connection is closed for writing.
    assert {:error, %Error{reason: :read_only}} = HTTP2.stream_request(pool, "GET", "/", [])

    # If the server now closes the socket, we actually shut down.
    :ok = :ssl.close(server_socket())

    Process.sleep(50)

    # If we try to make a request now that the server shut down, we get an error.
    assert {:error, %Error{reason: :disconnected}} = HTTP2.stream_request(pool, "GET", "/", [])
  end

  @tag :capture_log
  test "if server disconnects while there are waiting clients, we notify those clients" do
    {:ok, pool} =
      start_server_and_connect_with(fn port ->
        HTTP2.start_link(
          scheme: :https,
          host: "localhost",
          port: port,
          transport_opts: [verify: :verify_none]
        )
      end)

    assert {:ok, ref} = HTTP2.stream_request(pool, "GET", "/", [])

    assert_recv_frames [headers(stream_id: stream_id)]

    hbf = server_encode_headers([{":status", "200"}])

    server_send_frames([
      headers(stream_id: stream_id, hbf: hbf, flags: set_flags(:headers, [:end_headers]))
    ])

    :ok = :ssl.close(server_socket())

    assert receive_responses_until_done_or_error(ref) == [
             {:status, ref, 200},
             {:headers, ref, []},
             {:error, ref, %Error{reason: :connection_closed}}
           ]
  end

  # In the future, we will queue requests here.
  test "if connections reaches max concurrent streams, we return an error" do
    server_settings = [max_concurrent_streams: 1]

    {:ok, pool} =
      start_server_and_connect_with([server_settings: server_settings], fn port ->
        HTTP2.start_link(
          scheme: :https,
          host: "localhost",
          port: port,
          transport_opts: [verify: :verify_none]
        )
      end)

    assert {:ok, ref} = HTTP2.stream_request(pool, "GET", "/", [])

    assert {:error, %{reason: :too_many_concurrent_requests}} =
             HTTP2.stream_request(pool, "GET", "/", [])
  end

  test "request timeout with timeout of 0" do
    {:ok, pool} =
      start_server_and_connect_with(fn port ->
        HTTP2.start_link(
          scheme: :https,
          host: "localhost",
          port: port,
          transport_opts: [verify: :verify_none]
        )
      end)

    assert {:ok, ref} = HTTP2.stream_request(pool, "GET", "/", [], nil, timeout: 0)

    assert_recv_frames [headers(stream_id: stream_id), rst_stream(stream_id: stream_id)]

    assert receive_responses_until_done_or_error(ref) == [
             {:error, ref, %Error{reason: :request_timeout}}
           ]
  end

  test "request timeout with timeout > 0" do
    {:ok, pool} =
      start_server_and_connect_with(fn port ->
        HTTP2.start_link(
          scheme: :https,
          host: "localhost",
          port: port,
          transport_opts: [verify: :verify_none]
        )
      end)

    assert {:ok, ref} = HTTP2.stream_request(pool, "GET", "/", [], nil, timeout: 50)

    assert_recv_frames [headers(stream_id: stream_id)]

    hbf = server_encode_headers([{":status", "200"}])

    server_send_frames([
      headers(stream_id: stream_id, hbf: hbf, flags: set_flags(:headers, [:end_headers]))
    ])

    assert receive_responses_until_done_or_error(ref) == [
             {:status, ref, 200},
             {:headers, ref, []},
             {:error, ref, %Error{reason: :request_timeout}}
           ]
  end

  test "request timeout with timeout > 0 that fires after request is done" do
    {:ok, pool} =
      start_server_and_connect_with(fn port ->
        HTTP2.start_link(
          scheme: :https,
          host: "localhost",
          port: port,
          transport_opts: [verify: :verify_none]
        )
      end)

    assert {:ok, ref} = HTTP2.stream_request(pool, "GET", "/", [], nil, timeout: 50)

    assert_recv_frames [headers(stream_id: stream_id)]

    server_send_frames([
      headers(
        stream_id: stream_id,
        hbf: server_encode_headers([{":status", "200"}]),
        flags: set_flags(:headers, [:end_headers, :end_stream])
      )
    ])

    assert receive_responses_until_done_or_error(ref) == [
             {:status, ref, 200},
             {:headers, ref, []},
             {:done, ref}
           ]

    assert_recv_frames [rst_stream(stream_id: ^stream_id, error_code: :no_error)]

    refute_receive _any, 200
  end

  test "request timeout with timeout > 0 where :done arrives after timeout" do
    {:ok, pool} =
      start_server_and_connect_with(fn port ->
        HTTP2.start_link(
          scheme: :https,
          host: "localhost",
          port: port,
          transport_opts: [verify: :verify_none]
        )
      end)

    assert {:ok, ref} = HTTP2.stream_request(pool, "GET", "/", [], nil, timeout: 10)

    assert_recv_frames [headers(stream_id: stream_id)]

    # We sleep enough so that the timeout fires, then we send a response.
    Process.sleep(30)

    server_send_frames([
      headers(
        stream_id: stream_id,
        hbf: server_encode_headers([{":status", "200"}]),
        flags: set_flags(:headers, [:end_headers, :end_stream])
      )
    ])

    # When there's a timeout, we cancel the request.
    assert_recv_frames [rst_stream(stream_id: ^stream_id, error_code: :cancel)]

    assert receive_responses_until_done_or_error(ref) == [
             {:error, ref, %Error{reason: :request_timeout}}
           ]
  end

  @tag :capture_log
  test "stream_request_body/3 returns an error right away when disconnected" do
    {:ok, pool} =
      start_server_and_connect_with(fn port ->
        HTTP2.start_link(
          scheme: :https,
          host: "localhost",
          port: port,
          transport_opts: [verify: :verify_none]
        )
      end)

    assert {:ok, ref} = HTTP2.stream_request(pool, "GET", "/", [], :stream)

    assert_recv_frames [headers()]

    :ssl.close(server_socket())
    Process.sleep(50)

    assert {:error, %Error{reason: :disconnected}} = HTTP2.stream_request_body(pool, ref, "chunk")
  end

  test "stream_request_body/3 returns an error when the connection is read-only" do
    {:ok, pool} =
      start_server_and_connect_with(fn port ->
        HTTP2.start_link(
          scheme: :https,
          host: "localhost",
          port: port,
          transport_opts: [verify: :verify_none]
        )
      end)

    assert {:ok, ref} = HTTP2.stream_request(pool, "GET", "/", [], :stream)

    assert_recv_frames [headers(stream_id: stream_id)]

    server_send_frames([
      goaway(last_stream_id: stream_id, error_code: :no_error, debug_data: "all good")
    ])

    Process.sleep(50)

    assert {:error, %Error{reason: :read_only}} = HTTP2.stream_request_body(pool, ref, "chunk")
  end

  test "stream_request_body/3 streams a chunk of body" do
    {:ok, pool} =
      start_server_and_connect_with(fn port ->
        HTTP2.start_link(
          scheme: :https,
          host: "localhost",
          port: port,
          transport_opts: [verify: :verify_none]
        )
      end)

    assert {:ok, ref} = HTTP2.stream_request(pool, "GET", "/", [], :stream)

    assert_recv_frames [headers(stream_id: stream_id)]

    assert :ok = HTTP2.stream_request_body(pool, ref, "{")
    assert_recv_frames [data(stream_id: ^stream_id, data: "{")]

    assert :ok = HTTP2.stream_request_body(pool, ref, "}")
    assert_recv_frames [data(stream_id: ^stream_id, data: "}")]

    assert :ok = HTTP2.stream_request_body(pool, ref, :eof)
  end

  test "pool supports registering with a name" do
    {:ok, _pool} =
      start_server_and_connect_with(fn port ->
        HTTP2.start_link(
          scheme: :https,
          host: "localhost",
          port: port,
          transport_opts: [verify: :verify_none],
          name: __MODULE__.TestPool
        )
      end)

    assert {:ok, ref} = HTTP2.stream_request(__MODULE__.TestPool, "GET", "/", [])

    assert_recv_frames [headers()]
  end

  @pdict_key {__MODULE__, :http2_test_server}

  defp start_server_and_connect_with(opts \\ [], fun) do
    {result, server} = TestServer.start_and_connect_with(opts, fun)

    Process.put(@pdict_key, server)

    result
  end

  defp recv_next_frames(n) do
    server = Process.get(@pdict_key)
    TestServer.recv_next_frames(server, n)
  end

  defp server_encode_headers(headers) do
    server = Process.get(@pdict_key)
    {server, hbf} = TestServer.encode_headers(server, headers)
    Process.put(@pdict_key, server)
    hbf
  end

  defp server_send_frames(frames) do
    server = Process.get(@pdict_key)
    :ok = TestServer.send_frames(server, frames)
  end

  defp server_socket() do
    server = Process.get(@pdict_key)
    TestServer.get_socket(server)
  end

  defp receive_responses_until_done_or_error(ref) do
    receive_responses_until_done_or_error(ref, [])
  end

  defp receive_responses_until_done_or_error(ref, responses) do
    receive do
      {kind, ^ref, _value} = response when kind in [:status, :headers, :data] ->
        receive_responses_until_done_or_error(ref, [response | responses])

      {:done, ^ref} = response ->
        Enum.reverse([response | responses])

      {:error, ^ref, _error} = response ->
        Enum.reverse([response | responses])
    after
      2000 ->
        flunk("Did not receive a :done or :error response for the given request")
    end
  end
end
