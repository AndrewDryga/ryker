defmodule Ryker.GitHub.Client.Transport do
  @moduledoc """
  One GitHub REST call: the request through the configured requester with
  GitHub's versioned JSON headers, and the reading of a reply that is not the
  success its caller expected.

  A rate limit carries GitHub's own timing (Retry-After, or the reset of an
  exhausted quota) so the delivery worker waits exactly as long as asked; an
  ordinary 403 stays a permanent refusal, and a reply that is not an HTTP
  response at all is a protocol error.
  """
  alias Ryker.GitHub.Client

  @headers [
    {"accept", "application/vnd.github+json"},
    {"user-agent", "ryker"},
    {"x-github-api-version", "2022-11-28"}
  ]
  @default_rate_limit_delay_seconds 60

  @spec request(Client.t(), :get | :post | :put | :patch, String.t(), map() | nil) ::
          {:ok, map()} | {:error, term()}
  def request(%Client{http: http, requester: requester}, method, path, document),
    do: requester.request(http, method, path, document, @headers)

  @doc "The error a reply names when it is not the success its caller expected."
  @spec error(term()) :: {:error, term()}
  def error(%{body: body, headers: headers, status: status} = response)
      when status in [403, 429] and is_list(headers) do
    error = {:github_api_error, status, body}

    if rate_limited?(response),
      do: {:error, {:delivery_rate_limited, rate_limit_delay(headers), error}},
      else: {:error, error}
  end

  def error(%{body: body, status: status}) when is_integer(status),
    do: {:error, {:github_api_error, status, body}}

  def error(_response), do: {:error, {:github_protocol_error, :response}}

  @doc """
  Whether a reply is GitHub turning the request away for its rate limit: a
  429, or a 403 that says so, asks for a wait, or leaves no requests.
  """
  @spec rate_limited?(term()) :: boolean()
  def rate_limited?(%{status: 429}), do: true

  def rate_limited?(%{body: body, headers: headers, status: 403}) when is_list(headers) do
    not is_nil(header(headers, "retry-after")) or header(headers, "x-ratelimit-remaining") == "0" or
      rate_limit_message?(body)
  end

  def rate_limited?(_response), do: false

  defp rate_limit_message?(%{"message" => message}) when is_binary(message),
    do: message |> String.downcase() |> String.contains?("rate limit")

  defp rate_limit_message?(_body), do: false

  defp rate_limit_delay(headers) do
    retry_after(header(headers, "retry-after")) ||
      reset_after(header(headers, "x-ratelimit-reset"), System.system_time(:second)) ||
      @default_rate_limit_delay_seconds
  end

  defp retry_after(value) do
    case Integer.parse(value || "") do
      {seconds, ""} when seconds > 0 -> seconds
      _invalid -> nil
    end
  end

  defp reset_after(value, now) do
    case Integer.parse(value || "") do
      {reset_at, ""} when reset_at > now -> reset_at - now
      _invalid -> nil
    end
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn
      {header_name, value} when is_binary(header_name) and is_binary(value) ->
        if String.downcase(header_name) == name, do: value

      _invalid ->
        nil
    end)
  end
end
