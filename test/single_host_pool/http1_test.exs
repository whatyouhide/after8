defmodule After8.SingleHostPool.HTTP1Test do
  use ExUnit.Case

  alias After8.Error
  alias After8.SingleHostPool.HTTP1

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass}
  end

  test "supports opening multiple requests concurrently", %{bypass: bypass} do
    {:ok, pool} = HTTP1.start_link(scheme: :http, host: "localhost", port: bypass.port)

    Bypass.expect(bypass, "GET", "/", fn conn ->
      Plug.Conn.send_resp(conn, 200, "hello")
    end)

    tasks =
      for _ <- 1..5 do
        Task.async(fn ->
          HTTP1.request(pool, "GET", "/", [])
        end)
      end

    Enum.each(tasks, fn task ->
      assert {:ok, response} = Task.await(task)
      assert response.status == 200
      assert response.data == "hello"
    end)

    # Let's check that we can still send a request after all the responses
    # have been returned.
    Bypass.expect_once(bypass, "GET", "/after", fn conn ->
      Plug.Conn.send_resp(conn, 200, "after")
    end)

    assert {:ok, response} = HTTP1.request(pool, "GET", "/after", [])
    assert response.status == 200
    assert response.data == "after"
  end

  # TODO: we might want to remove this test once we introduce request queueing.
  test "if there are no available connections, an error is returned", %{bypass: bypass} do
    {:ok, pool} =
      HTTP1.start_link(scheme: :http, host: "localhost", port: bypass.port, max_connections: 1)

    Bypass.stub(bypass, "GET", "/", fn conn ->
      Plug.Conn.send_resp(conn, 200, "hello")
    end)

    assert {:ok, _ref} = HTTP1.stream_request(pool, "GET", "/", [])

    assert {:error, %Error{reason: :no_connections_available}} =
             HTTP1.stream_request(pool, "GET", "/", [])
  end
end
