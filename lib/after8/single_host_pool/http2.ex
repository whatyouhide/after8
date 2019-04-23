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

  @spec stream_request(
          t(),
          String.t(),
          String.t(),
          Mint.Types.headers(),
          nil | iodata(),
          keyword()
        ) ::
          {:ok, Mint.Types.request_ref()} | {:error, reason :: term()}
  def stream_request(pool, method, path, headers, body \\ nil, options \\ []) do
    pool = GenServer.whereis(pool)
    options = Keyword.put_new(options, :timeout, :infinity)
    :gen_statem.call(pool, {:stream_request, method, path, headers, body, options})
  end

  @spec stream_request_body(t(), Mint.Types.request_ref(), iodata() | :eof) ::
          :ok | {:error, reason :: term()}
  def stream_request_body(pool, ref, chunk) do
    pool = GenServer.whereis(pool)
    :gen_statem.call(pool, {:stream_request_body, ref, chunk})
  end

  @spec request(t(), String.t(), String.t(), Mint.Types.headers(), nil | iodata(), keyword()) ::
          {:ok, response :: map()} | {:error, reason :: term()}
  def request(pool, method, path, headers, body \\ nil, options \\ []) do
    options = Keyword.put_new(options, :timeout, :infinity)
    timeout = options[:timeout]

    case stream_request(pool, method, path, headers, body, options) do
      {:ok, ref} ->
        monitor_ref = Process.monitor(pool)
        # If the timeout is an integer, we add a fail-safe "after" clause that fires
        # after a timeout that is double the original timeout (min 2000ms). This means
        # that if there are no bugs in our code, then the normal :request_timeout is
        # returned, but otherwise we have a way to escape this code, raise an error, and
        # get the process unstuck.
        fail_safe_timeout = if is_integer(timeout), do: max(2000, timeout * 2), else: :infinity
        response_waiting_loop(ref, monitor_ref, _response_acc = %{}, fail_safe_timeout)

      {:error, error} ->
        {:error, error}
    end
  end

  defp response_waiting_loop(ref, monitor_ref, response, fail_safe_timeout) do
    receive do
      {:DOWN, ^monitor_ref, _, _, _} ->
        {:error, wrap_error(:connection_process_went_down)}

      {kind, ^ref, value} when kind in [:status, :headers] ->
        response = Map.put(response, kind, value)
        response_waiting_loop(ref, monitor_ref, response, fail_safe_timeout)

      {:data, ^ref, data} ->
        response = Map.update(response, :data, data, &(&1 <> data))
        response_waiting_loop(ref, monitor_ref, response, fail_safe_timeout)

      {:done, ^ref} ->
        {:ok, response}

      {:error, ^ref, error} ->
        {:error, error}
    after
      fail_safe_timeout ->
        raise "no response was received even after waiting #{fail_safe_timeout}ms. " <>
                "This is likely a bug in After8, but we're raising so that your system doesn't " <>
                "get stuck in an infinite receive."
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

  # We cancel all request timeouts as soon as we enter the :disconnected state, but
  # some timeouts might fire while changing states, so we need to handle them here.
  # Since we replied to all pending requests when entering the :disconnected state,
  # we can just do nothing here.
  def disconnected({:timeout, {:request_timeout, _ref}}, _content, _data) do
    :keep_state_and_data
  end

  # If we get a request while the connection is closed for writing, we
  # return an error right away.
  def disconnected(
        {:call, from},
        {:stream_request, _method, _path, _headers, _body, _opts},
        _data
      ) do
    {:keep_state_and_data, {:reply, from, {:error, wrap_error(:disconnected)}}}
  end

  def disconnected({:call, from}, {:stream_request_body, _ref, _chunk}, _data) do
    {:keep_state_and_data, {:reply, from, {:error, wrap_error(:disconnected)}}}
  end

  ## Connected

  def connected(:enter, _old_state, _data) do
    :keep_state_and_data
  end

  def connected({:call, from}, {:stream_request, method, path, headers, body, opts}, data) do
    case HTTP2.request(data.conn, method, path, headers, body) do
      {:ok, conn, ref} ->
        {from_pid, _from_ref} = from
        data = put_in(data.conn, conn)
        data = put_in(data.requests[ref], from_pid)

        # :infinity timeouts are not queued at all by gen_statem.
        actions = [
          {:reply, from, {:ok, ref}},
          {{:timeout, {:request_timeout, ref}}, opts[:timeout], _content = nil}
        ]

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
        {data, actions} = handle_responses(data, responses)

        cond do
          HTTP2.open?(conn, :write) ->
            {:keep_state, data, actions}

          HTTP2.open?(conn, :read) ->
            {:next_state, :connected_read_only, data, actions}

          true ->
            {:next_state, :disconnected, data, actions}
        end

      {:error, conn, error, responses} ->
        _ =
          Logger.error([
            "Received error from server #{data.scheme}:#{data.host}:#{data.port}: ",
            Exception.message(error)
          ])

        data = put_in(data.conn, conn)
        {data, actions} = handle_responses(data, responses)

        if HTTP2.open?(conn, :read) do
          {:next_state, :connected_read_only, data, actions}
        else
          {:next_state, :disconnected, data, actions}
        end

      :unknown ->
        _ = Logger.warn(["Received unknown message: ", inspect(message)])
        :keep_state_and_data
    end
  end

  def connected({:call, from}, {:stream_request_body, ref, chunk}, data) do
    case HTTP2.stream_request_body(data.conn, ref, chunk) do
      {:ok, conn} ->
        data = put_in(data.conn, conn)
        {:keep_state, data, [{:reply, from, :ok}]}

      {:error, conn, %HTTPError{reason: :closed_for_writing}} ->
        data = put_in(data.conn, conn)
        actions = [{:reply, from, {:error, wrap_error(:read_only)}}]
        {:next_state, :connected_read_only, data, actions}

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

  def connected({:timeout, {:request_timeout, ref}}, _content, data) do
    with {:pop, {from_pid, data}} when is_pid(from_pid) <- {:pop, pop_in(data.requests[ref])},
         {:ok, conn} <- HTTP2.cancel_request(data.conn, ref) do
      data = put_in(data.conn, conn)
      send(from_pid, {:error, ref, wrap_error(:request_timeout)})
      {:keep_state, data}
    else
      {:error, conn, _error} ->
        data = put_in(data.conn, conn)

        cond do
          HTTP2.open?(conn, :write) ->
            {:keep_state, data}

          HTTP2.open?(conn, :read) ->
            {:next_state, :connected_read_only, data}

          true ->
            {:next_state, :disconnected, data}
        end

      # The timer might have fired while we were receiving :done/:error for this
      # request, so we don't have the request stored anymore but we still get the
      # timer event. In those cases, we do nothing.
      {:pop, {nil, _data}} ->
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
        {:stream_request, _method, _path, _headers, _body, _opts},
        _data
      ) do
    {:keep_state_and_data, {:reply, from, {:error, wrap_error(:read_only)}}}
  end

  def connected_read_only(:info, message, data) do
    case HTTP2.stream(data.conn, message) do
      {:ok, conn, responses} ->
        data = put_in(data.conn, conn)
        {data, actions} = handle_responses(data, responses)

        if HTTP2.open?(conn, :read) do
          {:keep_state, data, actions}
        else
          {:next_state, :disconnected, data, actions}
        end

      {:error, conn, error, responses} ->
        _ =
          Logger.error([
            "Received error from server #{data.scheme}:#{data.host}:#{data.port}: ",
            Exception.message(error)
          ])

        data = put_in(data.conn, conn)
        {data, actions} = handle_responses(data, responses)

        if HTTP2.open?(conn, :read) do
          {:keep_state, data, actions}
        else
          {:next_state, :disconnected, data, actions}
        end

      :unknown ->
        _ = Logger.warn(["Received unknown message: ", inspect(message)])
        :keep_state_and_data
    end
  end

  def connected_read_only({:call, from}, {:stream_request_body, _ref, _chunk}, _data) do
    {:keep_state_and_data, {:reply, from, {:error, wrap_error(:read_only)}}}
  end

  # In this state, we don't need to call HTTP2.cancel_request/2 since the connection
  # is closed for writing, so we can't tell the server to cancel the request anymore.
  def connected_read_only({:timeout, {:request_timeout, ref}}, _content, data) do
    # We might get a request timeout that fired in the moment when we received the
    # whole request, so we don't have the request in the state but we get the
    # timer event anyways. In those cases, we don't do anything.
    case pop_in(data.requests[ref]) do
      {nil, _data} ->
        :keep_state_and_data

      {from_pid, data} ->
        send(from_pid, {:error, ref, wrap_error(:request_timeout)})
        {:keep_state, data}
    end
  end

  ## Helpers

  defp handle_responses(data, responses) do
    Enum.reduce(responses, {data, _actions = []}, fn response, {data, actions} ->
      handle_response(data, response, actions)
    end)
  end

  defp handle_response(data, {kind, ref, _value} = response, actions)
       when kind in [:status, :headers, :data] do
    send(data.requests[ref], response)
    {data, actions}
  end

  defp handle_response(data, {:done, ref} = response, actions) do
    {pid, data} = pop_in(data.requests[ref])
    send(pid, response)
    {data, [cancel_request_timeout_action(ref) | actions]}
  end

  defp handle_response(data, {:error, ref, _error} = response, actions) do
    {pid, data} = pop_in(data.requests[ref])
    send(pid, response)
    {data, [cancel_request_timeout_action(ref) | actions]}
  end

  defp cancel_request_timeout_action(request_ref) do
    # By setting the timeout to :infinity, we cancel this timeout as per
    # gen_statem documentation.
    {{:timeout, {:request_timeout, request_ref}}, :infinity, nil}
  end

  defp wrap_error(reason) do
    %After8.Error{reason: reason}
  end
end
