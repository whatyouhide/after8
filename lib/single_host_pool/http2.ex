defmodule After8.SingleHostPool.HTTP2 do
  @behaviour :gen_statem

  alias Mint.{HTTP2, HTTPError}

  require Logger

  defstruct [
    :conn,
    :hostname,
    :port,
    :connect_opts,
    requests: %{},
    requests_queue: :queue.new()
  ]

  def start_link(opts) do
    :gen_statem.start_link(__MODULE__, opts, [])
  end

  def request(pool, method, path, headers, body \\ nil) do
    :gen_statem.call(pool, {:request, method, path, headers, body})
  end

  ## Callbacks

  @impl true
  def callback_mode(), do: [:state_functions, :state_enter]

  @impl true
  def init(opts) do
    client_settings =
      opts
      |> Keyword.get(:client_settings, [])
      |> Keyword.put(:enable_push, false)

    data = %__MODULE__{
      hostname: Keyword.fetch!(opts, :hostname),
      port: Keyword.fetch!(opts, :port),
      connect_opts: [
        transport_opts: Keyword.get(opts, :transport_opts, []),
        client_settings: client_settings
      ]
    }

    {:ok, :disconnected, data, {:next_event, :internal, :connect}}
  end

  ## States

  ## Disconnected

  def disconnected(:enter, :disconnected, _data) do
    :keep_state_and_data
  end

  def disconnected(:internal, :connect, data) do
    case HTTP2.connect(:https, data.hostname, data.port, data.connect_opts) do
      {:ok, conn} ->
        data = %{data | conn: conn}
        {:next_state, :connected, data}

      {:error, _error} ->
        # TODO: log the error.
        # TODO: exponential backoff.
        {:keep_state_and_data, {{:timeout, :reconnect}, 1000, nil}}
    end
  end

  def disconnected({:timeout, :reconnect}, nil, _data) do
    {:keep_state_and_data, {:next_event, :internal, :connect}}
  end

  def disconnected(:enter, _old_state, data) do
    # TODO: reply to all pending requests.
    {:keep_state, data, {{:timeout, :reconnect}, 1000, nil}}
  end

  def disconnected({:call, from}, {:request, _method, _path, _headers, _body}, _data) do
    # TODO: use a better error.
    {:keep_state_and_data, {:reply, from, {:error, :disconnected}}}
  end

  ## Connected

  def connected(:enter, _old_state, _data) do
    :keep_state_and_data
  end

  def connected({:call, from}, {:request, method, path, headers, body} = request, data) do
    case HTTP2.request(data.conn, method, path, headers, body) do
      {:ok, conn, ref} ->
        data = put_in(data.conn, conn)
        data = put_in(data.requests[ref], %{from: from, response: %{}})
        {:keep_state, data}

      {:error, conn, %HTTPError{reason: :closed_for_writing}} ->
        data = put_in(data.conn, conn)
        # TODO: use a better error.
        actions = [{:reply, from, {:error, :read_only}}]
        {:next_state, :connected_read_only, data, actions}

      {:error, conn, %HTTPError{reason: :too_many_concurrent_requests}} ->
        data = put_in(data.conn, conn)
        data = update_in(data.requests_queue, &:queue.in(request, &1))
        {:keep_state, data}

      {:error, conn, error} ->
        data = put_in(data.conn, conn)
        actions = [{:reply, from, {:error, error}}]

        if HTTP2.open?(conn) do
          {:keep_state, data, actions}
        else
          {:next_state, :disconnected, data, actions}
        end
    end
  end

  def connected(:info, message, data) do
    case HTTP2.stream(data.conn, message) do
      {:ok, conn, responses} ->
        data = put_in(data.conn, conn)
        data = handle_responses(data, responses)

        # TODO: unqueue requests.

        cond do
          HTTP2.open?(conn, :write) ->
            {:keep_state, data}

          HTTP2.open?(conn, :read) ->
            {:next_state, :connected_read_only, data}

          true ->
            {:next_state, :disconnected, data}
        end

      {:error, conn, _error, responses} ->
        # TODO: log error.

        data = put_in(data.conn, conn)
        data = handle_responses(data, responses)

        if HTTP2.open?(conn, :read) do
          {:next_state, :connected_read_only, data}
        else
          {:next_state, :disconnected, data}
        end

      :unknown ->
        _ = Logger.warn(fn -> "Received unknown message: #{inspect(message)}" end)
        :keep_state_and_data
    end
  end

  ## Connected (read-only)

  def connected_read_only(:enter, _old_state, _data) do
    :keep_state_and_data
  end

  def connected_read_only({:call, from}, {:request, _method, _path, _headers, _body}, _data) do
    # TODO: better error.
    {:keep_state_and_data, {:reply, from, {:error, :read_only}}}
  end

  def connected_read_only(:info, message, data) do
    case HTTP2.stream(data.conn, message) do
      {:ok, conn, responses} ->
        data = put_in(data.conn, conn)
        data = handle_responses(data, responses)

        if HTTP2.open?(conn, :read) do
          {:keep_state, data}
        else
          {:next_state, :disconnected, data}
        end

      {:error, conn, _error, responses} ->
        # TODO: log error?
        data = put_in(data.conn, conn)
        data = handle_responses(data, responses)

        if HTTP2.open?(conn, :read) do
          {:keep_state, data}
        else
          {:next_state, :disconnected, data}
        end

      :unknown ->
        _ = Logger.warn(fn -> "Received unknown message: #{inspect(message)}" end)
        :keep_state_and_data
    end
  end

  ## Helpers

  defp handle_responses(data, responses) do
    Enum.reduce(responses, data, &handle_response(&2, &1))
  end

  defp handle_response(data, {:status, ref, status}) do
    put_in(data.requests[ref].response[:status], status)
  end

  defp handle_response(data, {:headers, ref, headers}) do
    put_in(data.requests[ref].response[:headers], headers)
  end

  defp handle_response(data, {:data, ref, chunk}) do
    update_in(data.requests[ref].response[:data], fn buff -> (buff || "") <> chunk end)
  end

  defp handle_response(data, {:done, ref}) do
    {%{from: from, response: response}, data} = pop_in(data.requests[ref])

    :ok = :gen_statem.reply(from, {:ok, response})

    data
  end

  defp handle_response(data, {:error, ref, error}) do
    {%{from: from}, data} = pop_in(data.requests[ref])
    :ok = :gen_statem.reply(from, {:error, error})
    data
  end
end
