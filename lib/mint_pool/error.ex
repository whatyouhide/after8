defmodule MintPool.Error do
  defexception [:reason]

  def message(%__MODULE__{reason: reason}) do
    format_reason(reason)
  end

  defp format_reason(:connection_closed) do
    "the connection was closed"
  end

  defp format_reason(:disconnected) do
    "the connection is closed"
  end

  defp format_reason(:read_only) do
    "the connection is in read-only mode. This means that the server closed the writing " <>
      "side and no more requests can be sent, but responses might still arrive"
  end

  defp format_reason(:connection_process_went_down) do
    "the connection process went down mid-request"
  end

  defp format_reason(:request_timeout) do
    "the request timed out"
  end

  defp format_reason(:no_connections_available) do
    "there are no connections available"
  end
end
