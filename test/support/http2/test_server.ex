defmodule After8.HTTP2.TestServer do
  import ExUnit.Assertions

  alias Mint.{HTTP2.Frame, HTTP2.HPACK}

  defstruct [:listen_socket, :socket, :encode_table, :decode_table, :port, :task]

  @ssl_opts [
    mode: :binary,
    packet: :raw,
    active: false,
    reuseaddr: true,
    next_protocols_advertised: ["h2"],
    alpn_preferred_protocols: ["h2"],
    certfile: Path.absname("certificate.pem", __DIR__),
    keyfile: Path.absname("key.pem", __DIR__)
  ]

  def start(server_settings \\ []) do
    parent = self()

    {:ok, listen_socket} = :ssl.listen(0, @ssl_opts)
    {:ok, {_address, port}} = :ssl.sockname(listen_socket)

    task =
      Task.async(fn ->
        {:ok, socket} = :ssl.transport_accept(listen_socket)
        :ok = :ssl.ssl_accept(socket)

        :ok = perform_http2_handshake(socket, server_settings)

        :ok = :ssl.controlling_process(socket, parent)

        {:socket, socket}
      end)

    %__MODULE__{
      listen_socket: listen_socket,
      task: task,
      port: port,
      encode_table: HPACK.new(4096),
      decode_table: HPACK.new(4096)
    }
  end

  def port(%__MODULE__{port: port}), do: port

  def flush(%__MODULE__{} = server) do
    case Task.await(server.task) do
      {:socket, socket} ->
        %{server | socket: socket, task: nil}

      {:expect, server} ->
        server
    end
  end

  def expect(%__MODULE__{} = server, fun) when is_function(fun, 1) do
    task = Task.async(fn -> {:expect, fun.(server)} end)
    %{server | task: task}
  end

  defmacro assert_receive_frames(server, frames) when is_list(frames) do
    quote do
      server = unquote(server)
      expected_frame_count = unquote(length(frames))

      # Let's just make sure that we passed a server in.
      assert server.__struct__ == unquote(__MODULE__)

      assert unquote(frames) = unquote(__MODULE__).recv_next_frames(server, expected_frame_count)
    end
  end

  def send_frames(server, frames) do
    # TODO: split this and random and use a few SSL calls to introduce some fuzziness
    # in the SSL packet size.
    encoded_frames = Enum.map(frames, &Frame.encode/1)
    :ok = :ssl.send(server.socket, encoded_frames)
  end

  @spec recv_next_frames(%__MODULE__{}, pos_integer()) :: [frame :: term(), ...]
  def recv_next_frames(%__MODULE__{} = server, frame_count) when frame_count > 0 do
    recv_next_frames(server, frame_count, [], "")
  end

  defp recv_next_frames(_server, 0, frames, buffer) do
    if buffer == "" do
      Enum.reverse(frames)
    else
      flunk("Expected no more data, got: #{inspect(buffer)}")
    end
  end

  defp recv_next_frames(%{socket: socket} = server, n, frames, buffer) do
    case :ssl.recv(socket, 0, _timeout = 500) do
      {:ok, data} ->
        decode_next_frames(server, n, frames, buffer <> data)

      {:error, :timeout} ->
        flunk("Expected data because there are #{n} expected frames left")
    end
  end

  defp decode_next_frames(_server, 0, frames, buffer) do
    if buffer == "" do
      Enum.reverse(frames)
    else
      flunk("Expected no more data, got: #{inspect(buffer)}")
    end
  end

  defp decode_next_frames(server, n, frames, data) do
    case Frame.decode_next(data) do
      {:ok, frame, rest} ->
        decode_next_frames(server, n - 1, [frame | frames], rest)

      :more ->
        recv_next_frames(server, n, frames, data)

      other ->
        flunk("Error decoding frame: #{inspect(other)}")
    end
  end

  @spec encode_headers(%__MODULE__{}, Mint.Types.headers()) :: {%__MODULE__{}, hbf :: binary()}
  def encode_headers(%__MODULE__{} = server, headers) when is_list(headers) do
    headers = for {name, value} <- headers, do: {:store_name, name, value}
    {hbf, encode_table} = HPACK.encode(headers, server.encode_table)
    server = put_in(server.encode_table, encode_table)
    {server, IO.iodata_to_binary(hbf)}
  end

  @spec decode_headers(%__MODULE__{}, binary()) :: {%__MODULE__{}, Mint.Types.headers()}
  def decode_headers(%__MODULE__{} = server, hbf) when is_binary(hbf) do
    assert {:ok, headers, decode_table} = HPACK.decode(hbf, server.decode_table)
    server = put_in(server.decode_table, decode_table)
    {server, headers}
  end

  @spec get_socket(%__MODULE__{}) :: :ssl.sslsocket()
  def get_socket(server) do
    server.socket
  end

  connection_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

  defp perform_http2_handshake(socket, server_settings) do
    import Mint.HTTP2.Frame, only: [settings: 1]

    no_flags = Frame.set_flags(:settings, [])
    ack_flags = Frame.set_flags(:settings, [:ack])

    # First we get the connection preface.
    {:ok, unquote(connection_preface) <> rest} = :ssl.recv(socket, 0, 100)

    # Then we get a SETTINGS frame.
    assert {:ok, frame, ""} = Frame.decode_next(rest)
    assert settings(flags: ^no_flags, params: _params) = frame

    # We reply with our SETTINGS.
    :ok = :ssl.send(socket, Frame.encode(settings(params: server_settings)))

    # We get the SETTINGS ack.
    {:ok, data} = :ssl.recv(socket, 0, 100)
    assert {:ok, frame, ""} = Frame.decode_next(data)
    assert settings(flags: ^ack_flags, params: []) = frame

    # We send the SETTINGS ack back.
    :ok = :ssl.send(socket, Frame.encode(settings(flags: ack_flags, params: [])))

    :ok
  end
end
