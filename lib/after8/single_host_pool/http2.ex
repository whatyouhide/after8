defmodule After8.SingleHostPool.HTTP2 do
  @behaviour :gen_statem

  alias Mint.{HTTP2, HTTPError}

  require Logger

  # Backoffs in milliseconds.
  @default_backoff_initial 500
  @default_backoff_max 30_000

  # Backoff exponent as an integer.
  @backoff_exponent 2

  defstruct conn: nil,
            host: nil,
            port: nil,
            scheme: nil,
            connect_opts: nil,
            backoff_initial: nil,
            backoff_max: nil,
            requests: %{}

  ## Types

  @type t() :: :gen_statem.server_ref()

  ## Public API

  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) when is_list(opts) do
    {gen_statem_opts, opts} =
      Keyword.split(opts, [:debug, :timeout, :spawn_opt, :hibernate_after])

    case Keyword.pop(opts, :name) do
      {nil, opts} ->
        :gen_statem.start_link(__MODULE__, opts, gen_statem_opts)

      {atom, opts} when is_atom(atom) ->
        :gen_statem.start_link({:local, atom}, __MODULE__, opts, gen_statem_opts)

      {{:global, term}, opts} ->
        :gen_statem.start_link({:global, term}, __MODULE__, opts, gen_statem_opts)

      {{:via, via_module, term}, opts} when is_atom(via_module) ->
        :gen_statem.start_link({:via, via_module, term}, __MODULE__, opts, gen_statem_opts)

      {other, _opts} ->
        raise ArgumentError, """
        expected :name option to be one of the following:

          * nil
          * atom
          * {:global, term}
          * {:via, module, term}

        Got: #{inspect(other)}
        """
    end
  end

  @spec stream_request(t(), String.t(), String.t(), Mint.Types.headers(), nil | iodata()) ::
          {:ok, Mint.Types.request_ref()} | {:error, reason :: term()}
  def stream_request(pool, method, path, headers, body \\ nil) do
    pool = GenServer.whereis(pool)
    :gen_statem.call(pool, {:stream_request, method, path, headers, body})
  end

  @spec request(t(), String.t(), String.t(), Mint.Types.headers(), nil | iodata()) ::
          {:ok, response :: map()} | {:error, reason :: term()}
  def request(pool, method, path, headers, body \\ nil) do
    # TODO: implement timeout.
    pool = GenServer.whereis(pool)

    case stream_request(pool, method, path, headers, body) do
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

  @impl true
  def callback_mode(), do: [:state_functions, :state_enter]

  @impl true
  def init(opts) do
    client_settings =
      opts
      |> Keyword.get(:client_settings, [])
      |> Keyword.put(:enable_push, false)

    data = %__MODULE__{
      scheme: Keyword.fetch!(opts, :scheme),
      host: Keyword.fetch!(opts, :host),
      port: Keyword.fetch!(opts, :port),
      backoff_initial: Keyword.get(opts, :backoff_initial, @default_backoff_initial),
      backoff_max: Keyword.get(opts, :backoff_max, @default_backoff_max),
      connect_opts: [
        transport_opts: Keyword.get(opts, :transport_opts, []),
        client_settings: client_settings
      ]
    }

    {:ok, :disconnected, data, {:next_event, :internal, {:connect, data.backoff_initial}}}
  end

  ## States

  ## Disconnected

  # This only happens the first time we enter the first state, which is :disconnected.
  def disconnected(:enter, :disconnected, _data) do
    :keep_state_and_data
  end

  # When we enter the disconnected state, we send an :error response to all
  # pending requests and then set a timer for reconnecting.
  def disconnected(:enter, _old_state, data) do
    :ok =
      Enum.each(data.requests, fn {ref, pid} ->
        send(pid, {:error, ref, wrap_error(:connection_closed)})
      end)

    data = put_in(data.requests, %{})
    data = put_in(data.conn, nil)

    actions = [{{:timeout, :reconnect}, data.backoff_initial, data.backoff_initial}]
    {:keep_state, data, actions}
  end

  def disconnected(:internal, {:connect, next_backoff}, data) do
    case HTTP2.connect(data.scheme, data.host, data.port, data.connect_opts) do
      {:ok, conn} ->
        data = %{data | conn: conn}
        {:next_state, :connected, data}

      {:error, error} ->
        _ =
          Logger.error([
            "Failed to connect to #{data.scheme}:#{data.host}:#{data.port}: ",
            Exception.message(error)
          ])

        {:keep_state_and_data, {{:timeout, :reconnect}, next_backoff, next_backoff}}
    end
  end

  def disconnected({:timeout, :reconnect}, backoff, data) do
    next_backoff = min(data.backoff_max, backoff * @backoff_exponent)
    {:keep_state_and_data, {:next_event, :internal, {:connect, next_backoff}}}
  end

  # If we get a request while the connection is closed for writing, we
  # return an error right away.
  def disconnected({:call, from}, {:stream_request, _method, _path, _headers, _body}, _data) do
    {:keep_state_and_data, {:reply, from, {:error, wrap_error(:disconnected)}}}
  end

  ## Connected

  def connected(:enter, _old_state, _data) do
    :keep_state_and_data
  end

  def connected({:call, from}, {:stream_request, method, path, headers, body}, data) do
    # TODO: monitor caller.

    case HTTP2.request(data.conn, method, path, headers, body) do
      {:ok, conn, ref} ->
        {from_pid, _from_ref} = from
        data = put_in(data.conn, conn)
        data = put_in(data.requests[ref], from_pid)
        actions = [{:reply, from, {:ok, ref}}]
        {:keep_state, data, actions}

      {:error, conn, %HTTPError{reason: :closed_for_writing}} ->
        data = put_in(data.conn, conn)
        actions = [{:reply, from, {:error, wrap_error(:read_only)}}]
        {:next_state, :connected_read_only, data, actions}

      # TODO: queue this request on :too_many_concurrent_requests.
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
        data = Enum.reduce(responses, data, &handle_response(&2, &1))

        cond do
          HTTP2.open?(conn, :write) ->
            {:keep_state, data}

          HTTP2.open?(conn, :read) ->
            {:next_state, :connected_read_only, data}

          true ->
            {:next_state, :disconnected, data}
        end

      {:error, conn, error, responses} ->
        _ =
          Logger.error([
            "Received error from server #{data.scheme}:#{data.host}:#{data.port}: ",
            Exception.message(error)
          ])

        data = put_in(data.conn, conn)
        data = Enum.reduce(responses, data, &handle_response(&2, &1))

        if HTTP2.open?(conn, :read) do
          {:next_state, :connected_read_only, data}
        else
          {:next_state, :disconnected, data}
        end

      :unknown ->
        _ = Logger.warn(["Received unknown message: ", inspect(message)])
        :keep_state_and_data
    end
  end

  ## Connected (read-only)

  def connected_read_only(:enter, _old_state, _data) do
    :keep_state_and_data
  end

  # If the connection is closed for writing, we return an error right away
  # when the user tries to make a request.
  def connected_read_only(
        {:call, from},
        {:stream_request, _method, _path, _headers, _body},
        _data
      ) do
    {:keep_state_and_data, {:reply, from, {:error, wrap_error(:read_only)}}}
  end

  def connected_read_only(:info, message, data) do
    case HTTP2.stream(data.conn, message) do
      {:ok, conn, responses} ->
        data = put_in(data.conn, conn)
        data = Enum.reduce(responses, data, &handle_response(&2, &1))

        if HTTP2.open?(conn, :read) do
          {:keep_state, data}
        else
          {:next_state, :disconnected, data}
        end

      {:error, conn, error, responses} ->
        _ =
          Logger.error([
            "Received error from server #{data.scheme}:#{data.host}:#{data.port}: ",
            Exception.message(error)
          ])

        data = put_in(data.conn, conn)
        data = Enum.reduce(responses, data, &handle_response(&2, &1))

        if HTTP2.open?(conn, :read) do
          {:keep_state, data}
        else
          {:next_state, :disconnected, data}
        end

      :unknown ->
        _ = Logger.warn(["Received unknown message: ", inspect(message)])
        :keep_state_and_data
    end
  end

  ## Helpers

  defp handle_response(data, {kind, ref, _value} = response)
       when kind in [:status, :headers, :data] do
    send(data.requests[ref], response)
    data
  end

  defp handle_response(data, {:done, ref} = response) do
    {pid, data} = pop_in(data.requests[ref])
    send(pid, response)
    data
  end

  defp handle_response(data, {:error, ref, _error} = response) do
    {pid, data} = pop_in(data.requests[ref])
    send(pid, response)
    data
  end

  defp wrap_error(reason) do
    %After8.Error{reason: reason}
  end
end
