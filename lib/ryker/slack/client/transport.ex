defmodule Ryker.Slack.Client.Transport do
  @moduledoc """
  One Slack Web API call: the request through the configured requester and
  the response read into `{:ok, body}` or a typed error.

  Rate limits carry Slack's Retry-After so the delivery worker can wait exactly
  as long as asked; every other failure names the status and the error Slack
  returned, and a body that is not a Slack envelope is a protocol error.
  """

  alias Ryker.Slack.Client

  @spec request(Client.t(), :get | :post, String.t(), map() | nil) ::
          {:ok, map()} | {:error, term()}
  def request(%Client{http: http, requester: requester}, method, path, document),
    do: requester.request(http, method, path, document, [])

  @spec response(term()) :: {:ok, map()} | {:error, term()}
  def response(%{body: %{"ok" => true} = body, status: 200}), do: {:ok, body}

  def response(%{
        body: %{"error" => "ratelimited"},
        headers: headers,
        status: status
      })
      when status in [200, 429] and is_list(headers) do
    error =
      if status == 200,
        do: {:slack_api_error, "ratelimited"},
        else: {:slack_http_error, status, "ratelimited"}

    {:error, {:delivery_rate_limited, retry_after(headers), error}}
  end

  def response(%{body: body, headers: headers, status: 429}) when is_list(headers) do
    {:error, {:delivery_rate_limited, retry_after(headers), {:slack_http_error, 429, body}}}
  end

  def response(%{body: %{"error" => error, "ok" => false}, status: 200})
      when is_binary(error),
      do: {:error, {:slack_api_error, error}}

  def response(%{body: %{"error" => error}, status: status})
      when is_integer(status) and is_binary(error),
      do: {:error, {:slack_http_error, status, error}}

  def response(%{status: status}) when is_integer(status),
    do: {:error, {:slack_http_error, status, :invalid_response}}

  def response(_response), do: {:error, {:slack_protocol_error, :response}}

  @doc "A call whose body carries nothing the caller needs: `:ok` or the error."
  @spec success({:ok, term()} | {:error, term()}) :: :ok | {:error, term()}
  def success({:ok, _body}), do: :ok
  def success({:error, _reason} = error), do: error

  defp retry_after(headers) do
    value =
      Enum.find_value(headers, fn
        {name, value} when is_binary(name) and is_binary(value) ->
          if String.downcase(name) == "retry-after", do: value

        _invalid ->
          nil
      end)

    case Integer.parse(value || "") do
      {seconds, ""} when seconds > 0 -> seconds
      _invalid -> nil
    end
  end
end
