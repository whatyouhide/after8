# After8

## SingleHostPool.HTTP2

Assuming:

```elixir
alias After8.SingleHostPool.HTTP2
```

Starting a pool:

```elixir
{:ok, _pool} = HTTP2.start_link(hostname: "http2.golang.org", port: 443, name: :golang_pool)
```

Making a simple request:

```elixir
{:ok, response} = HTTP2.request(:golang_pool, "GET", "/", [])
response
#=> %{status: 200, headers: [...], data: "..."}
```

Making a streaming request:

```elixir
{:ok, ref} = HTTP2.stream_request(:golang_pool, "GET", "/", [])
flush()
#=> {:status, ^ref, 200}
#=> {:headers, ^ref, [...]}
#=> {:data, ^ref, "..."}
#=> {:done, ^ref}
```

Streaming the body of a request:

```elixir
{:ok, ref} = HTTP2.request(:golang_pool, "POST", "/", [], :stream)
:ok = HTTP2.stream_request_body(:golang_pool, ref, "{")
:ok = HTTP2.stream_request_body(:golang_pool, ref, "}")
:ok = HTTP2.stream_request_body(:golang_pool, ref, :eof)
{:ok, response} = HTTP2.get_response(:golang_pool, ref)
```