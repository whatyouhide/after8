defmodule After8.SingleHostPool.HTTP2 do
  @behaviour :gen_statem

  alias Mint.HTTP2

  require Logger

  defstruct [
    :conn,
    :hostname,
    :port,
    :connect_opts,
    requests: %{}
  ]

  def start_link(opts) do
    :gen_statem.start_link(__MODULE__, opts, [])
  end

  def request(pool, method, path, headers, body \\ nil) do
    :gen_statem.call(pool, {:request, method, path, headers, body})
  end

  ## Callbacks

  @impl true
  def callback_mode() do
    :state_functions
  end

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

  def disconnected(:internal, :connect, data) do
    case HTTP2.connect(:https, data.hostname, data.port, data.connect_opts) do
      {:ok, conn} ->
        data = %{data | conn: conn}
        {:next_state, :connected, data}

      {:error, _error} ->
        # TODO: log the error.
        {:keep_state_and_data, {{:timeout, :reconnect}, 1000, nil}}
    end
  end

  def disconnected({:timeout, :reconnect}, nil, _data) do
    {:keep_state_and_data, {:next_event, :internal, :connect}}
  end

  def disconnected({:call, from}, {:request, _method, _path, _headers, _body}, _data) do
    {:keep_state_and_data, {:reply, from, {:error, :disconnected}}}
  end

  ## Connected

  def connected({:call, from}, {:request, method, path, headers, body}, data) do
    case HTTP2.request(data.conn, method, path, headers, body) do
      {:ok, conn, ref} ->
        data = put_in(data.conn, conn)
        data = put_in(data.requests[ref], %{from: from, response: %{}})
        {:keep_state, data}

      {:error, _conn, _error} ->
        raise "TODO"
    end
  end

  def connected(:info, message, data) do
    case HTTP2.stream(data.conn, message) do
      {:ok, conn, responses} ->
        data = put_in(data.conn, conn)
        data = handle_responses(data, responses)
        {:keep_state, data}

      {:error, _conn, _error, _responses} ->
        raise "TODO"

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

    :ok = GenServer.reply(from, {:ok, response})

    data
  end

  defp handle_response(data, {:error, ref, error}) do
    {%{from: from}, data} = pop_in(data.requests[ref])
    :ok = GenServer.reply(from, {:error, error})
    data
  end
end
