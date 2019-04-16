defmodule After8.SingleHostPool.HTTP2Test do
  use ExUnit.Case

  import Mint.HTTP2.Frame

  alias After8.SingleHostPool.HTTP2
  alias After8.HTTP2.TestServer

  test "request/response" do
    server = TestServer.start()

    {:ok, pool} =
      HTTP2.start_link(
        scheme: :https,
        host: "localhost",
        port: TestServer.port(server),
        transport_opts: [verify: :verify_none]
      )

    server = TestServer.flush(server)

    server =
      TestServer.expect(server, fn server ->
        import TestServer

        assert_receive_frames server, [headers(stream_id: stream_id)]

        {server, hbf} = encode_headers(server, [{":status", "200"}])

        send_frames(server, [
          headers(stream_id: stream_id, hbf: hbf, flags: set_flags(:headers, [:end_headers])),
          data(stream_id: stream_id, data: "hello to you", flags: set_flags(:data, [:end_stream]))
        ])

        server
      end)

    assert {:ok, response} = HTTP2.request(pool, "GET", "/", [])
    assert response.status == 200
    assert response.data == "hello to you"

    _server = TestServer.flush(server)
  end

  test "errors such as :max_header_list_size_reached are returned to the caller" do
    server = TestServer.start(max_header_list_size: 5)

    {:ok, pool} =
      HTTP2.start_link(
        scheme: :https,
        host: "localhost",
        port: TestServer.port(server),
        transport_opts: [verify: :verify_none]
      )

    _server = TestServer.flush(server)

    assert {:error, error} = HTTP2.request(pool, "GET", "/", [{"foo", "bar"}])
    assert %Mint.HTTPError{reason: {:max_header_list_size_exceeded, _, _}} = error
  end

  test "if server sends GOAWAY and then replies, we get the replies but are closed for writing" do
    server = TestServer.start()

    {:ok, pool} =
      HTTP2.start_link(
        scheme: :https,
        host: "localhost",
        port: TestServer.port(server),
        transport_opts: [verify: :verify_none]
      )

    server = TestServer.flush(server)

    server =
      TestServer.expect(server, fn server ->
        import TestServer

        assert_receive_frames server, [headers(stream_id: stream_id)]

        {server, hbf} = encode_headers(server, [{":status", "200"}])

        send_frames(server, [
          goaway(last_stream_id: stream_id, error_code: :no_error, debug_data: "all good"),
          headers(stream_id: stream_id, hbf: hbf, flags: set_flags(:headers, [:end_headers])),
          data(stream_id: stream_id, data: "hello", flags: set_flags(:data, [:end_stream]))
        ])

        server
      end)

    assert {:ok, response} = HTTP2.request(pool, "GET", "/", [])
    assert response.status == 200
    assert response.headers == []
    assert response.data == "hello"

    # We can't send any more requests since the connection is closed for writing.
    assert {:error, :read_only} = HTTP2.request(pool, "GET", "/", [])

    # If the server now closes the socket, we actually shut down.
    server =
      TestServer.expect(server, fn server ->
        :ssl.close(server.socket)
        server
      end)

    server = TestServer.flush(server)

    Process.sleep(50)

    # If we try to make a request now that the server shut down, we get an error.
    assert {:error, :disconnected} = HTTP2.request(pool, "GET", "/", [])

    _server = TestServer.flush(server)
  end
end
