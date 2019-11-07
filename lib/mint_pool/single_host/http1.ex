defmodule MintPool.SingleHost.HTTP1 do
  use GenServer

  alias Mint.HTTP1

  require Logger

  defstruct scheme: nil, host: nil, port: nil, max_connections: nil, conns: [], requests: %{}

  @genserver_start_opts [:debug, :name, :timeout, :spawn_opt, :hibernate_after]

  ## Public API

  def start_link(opts) do
    {genserver_start_opts, opts} = Keyword.split(opts, @genserver_start_opts)
    GenServer.start_link(__MODULE__, opts, genserver_start_opts)
  end

  def stream_request(pool, method, path, headers, body \\ nil, options \\ []) do
    GenServer.call(pool, {:stream_request, method, path, headers, body, options})
  end

  def request(pool, method, path, headers, body \\ nil, options \\ []) do
    # TODO: add support for timeout.

    case stream_request(pool, method, path, headers, body, options) do
      {:ok, ref} ->
        monitor_ref = Process.monitor(pool)
        response_waiting_loop(ref, monitor_ref, _response_acc = %{})

      {:error, error} ->
        {:error, error}
    end
  end

  defp response_waiting_loop(ref, monitor_ref, response) do
    receive do
      {:DOWN, ^monitor_ref, _, _, _} ->
        {:error, wrap_error(:connection_process_went_down)}

      {kind, ^ref, value} when kind in [:status, :headers] ->
        response = Map.put(response, kind, value)
        response_waiting_loop(ref, monitor_ref, response)

      {:data, ^ref, data} ->
        response = Map.update(response, :data, data, &(&1 <> data))
        response_waiting_loop(ref, monitor_ref, response)

      {:done, ^ref} ->
        {:ok, response}

      {:error, ^ref, error} ->
        {:error, error}
    end
  end

  ## Callbacks

  def init(opts) do
    state = %__MODULE__{
      scheme: Keyword.fetch!(opts, :scheme),
      host: Keyword.fetch!(opts, :host),
      port: Keyword.fetch!(opts, :port),
      max_connections: Keyword.get(opts, :max_connections, 5)
    }

    {:ok, state}
  end

  def handle_call({:stream_request, method, path, headers, body, _opts}, {from_pid, _}, state) do
    case pop_idle_conn_or_open(state) do
      {:ok, state, conn} ->
        case HTTP1.request(conn, method, path, headers, body) do
          {:ok, conn, ref} ->
            state = update_in(state.conns, &[conn | &1])
            state = put_in(state.requests[ref], from_pid)
            {:reply, {:ok, ref}, state}

          {:error, conn, reason} ->
            state = update_in(state.conns, &[conn | &1])
            {:reply, {:errorm, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_info(message, state) do
    case handle_message(state, message) do
      {:ok, state} ->
        {:noreply, state}

      :unknown ->
        _ = Logger.warn("Unknown message: #{inspect(message)}")
        {:noreply, state}
    end
  end

  ## Helpers

  defp pop_idle_conn_or_open(%__MODULE__{} = state) do
    case pop_idle_conn(state.conns) do
      {nil, _conns} ->
        if length(state.conns) < state.max_connections do
          open_conn(state)
        else
          # TODO: queue requests.
          {:error, wrap_error(:no_connections_available)}
        end

      {conn, conns} ->
        state = put_in(state.conns, conns)
        {:ok, state, conn}
    end
  end

  defp open_conn(state) do
    with {:ok, conn} <- HTTP1.connect(state.scheme, state.host, state.port) do
      {:ok, state, conn}
    end
  end

  defp pop_idle_conn(conns) do
    pop_idle_conn(conns, _acc = [])
  end

  defp pop_idle_conn([conn | rest], acc) do
    if HTTP1.open_request_count(conn) == 0 do
      {conn, Enum.reverse(acc, rest)}
    else
      pop_idle_conn(rest, [conn | acc])
    end
  end

  defp pop_idle_conn([], acc) do
    {nil, Enum.reverse(acc)}
  end

  defp handle_message(state, message) do
    handle_message(state, state.conns, message, _conns_acc = [])
  end

  defp handle_message(_state, [], _message, _conns_acc) do
    :unknown
  end

  defp handle_message(state, [conn | rest], message, conns_acc) do
    case HTTP1.stream(conn, message) do
      :unknown ->
        handle_message(state, rest, message, [conn | conns_acc])

      {:ok, conn, responses} ->
        state = handle_responses(state, responses)

        if HTTP1.open?(conn) do
          conns = Enum.reverse([conn | conns_acc], rest)
          state = put_in(state.conns, conns)
          {:ok, state}
        else
          state = put_in(state.conns, Enum.reverse(conns_acc, rest))
          {:ok, state}
        end

      {:error, conn, reason, responses} ->
        _ = Logger.error("Received error from server: #{Exception.message(reason)}")
        state = handle_responses(state, responses)

        if HTTP1.open?(conn) do
          conns = Enum.reverse([conn | conns_acc], rest)
          state = put_in(state.conns, conns)
          {:ok, state}
        else
          state = put_in(state.conns, Enum.reverse(conns_acc, rest))
          {:ok, state}
        end
    end
  end

  defp handle_responses(state, responses) do
    Enum.reduce(responses, state, &handle_response(&2, &1))
  end

  defp handle_response(state, {kind, ref, _value} = response)
       when kind in [:status, :headers, :data] do
    send(state.requests[ref], response)
    state
  end

  defp handle_response(state, {:done, ref} = response) do
    {pid, state} = pop_in(state.requests[ref])
    send(pid, response)
    state
  end

  defp handle_response(state, {:error, ref, _reason} = response) do
    {pid, state} = pop_in(state.requests[ref])
    send(pid, response)
    state
  end

  defp wrap_error(reason) do
    %MintPool.Error{reason: reason}
  end
end
