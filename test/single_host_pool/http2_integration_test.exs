defmodule After8.SingleHostPool.HTTP2Integration do
  use ExUnit.Case

  alias After8.SingleHostPool.HTTP2

  setup_all do
    Logger.configure(level: :info)
  end

  describe "http2.golang.org" do
    test "GET /" do
      {:ok, pool} = HTTP2.start_link(scheme: :https, host: "http2.golang.org", port: 443)

      assert {:ok, response} = HTTP2.request(pool, "GET", "/", _headers = [])

      assert is_map(response)
      assert response.status == 200
      assert List.keyfind(response.headers, "content-length", 0) != nil
      assert String.starts_with?(response.data, "<html>")
    end

    test "GET /file/gopher.png" do
      {:ok, pool} = HTTP2.start_link(scheme: :https, host: "http2.golang.org", port: 443)

      assert {:ok, response} = HTTP2.request(pool, "GET", "/file/gopher.png", _headers = [])

      assert is_map(response)
      assert response.status == 200
      assert List.keyfind(response.headers, "content-length", 0) != nil
      assert is_binary(response.data) and byte_size(response.data) > 0
    end

    test "PUT /ECHO" do
      {:ok, pool} = HTTP2.start_link(scheme: :https, host: "http2.golang.org", port: 443)

      assert {:ok, response} = HTTP2.request(pool, "PUT", "/ECHO", _headers = [], "hello world")

      assert is_map(response)
      assert response.status == 200
      assert is_list(response.headers)
      assert response.data == "HELLO WORLD"
    end

    test "multiple concurrent requests" do
      {:ok, pool} = HTTP2.start_link(scheme: :https, host: "http2.golang.org", port: 443)

      task1 = Task.async(fn -> HTTP2.request(pool, "PUT", "/ECHO", [], "task1") end)
      task2 = Task.async(fn -> HTTP2.request(pool, "PUT", "/ECHO", [], "task2") end)
      task3 = Task.async(fn -> HTTP2.request(pool, "PUT", "/ECHO", [], "task3") end)

      assert [
               {^task1, {:ok, {:ok, response1}}},
               {^task2, {:ok, {:ok, response2}}},
               {^task3, {:ok, {:ok, response3}}}
             ] = Task.yield_many([task1, task2, task3])

      assert response1.data == "TASK1"
      assert response2.data == "TASK2"
      assert response3.data == "TASK3"
    end
  end

  describe "localhost:99999" do
    @tag :capture_log
    test "any request" do
      {:ok, pool} = HTTP2.start_link(scheme: :https, host: "localhost", port: 99999)

      assert {:error, _} = HTTP2.request(pool, "GET", "/", _headers = [])
    end
  end
end
