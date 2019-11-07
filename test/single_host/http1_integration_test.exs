defmodule MintPool.SingleHost.HTTP1IntegrationTest do
  use ExUnit.Case

  alias MintPool.SingleHost.HTTP1

  describe "httpbin.org" do
    test "GET /get" do
      {:ok, pool} = HTTP1.start_link(scheme: :http, host: "httpbin.org", port: 80)

      assert {:ok, response} = HTTP1.request(pool, "GET", "/get", [])
      assert response.status == 200
      assert List.keyfind(response.headers, "connection", 0) == {"connection", "keep-alive"}
      assert String.starts_with?(response.data, "{")
    end
  end
end
