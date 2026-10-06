defmodule Ryker.LocalRouting.Client do
  @moduledoc """
  One question to the local routing model over the OpenAI chat completions
  API, as Ollama, llama.cpp, vLLM and LM Studio serve it.

  The prompt is sent exactly as routing sent it to the provider, as the one
  user message, with routing's contract as structured output
  (`response_format` `json_schema`, `Ryker.LocalRouting.Schema`), at
  temperature 0 so the same prompt draws the same answer. The whole exchange
  is bounded by a firm timeout: a server that accepts the connection and
  never answers, or drips its answer, is cut off when the time is up, and
  nothing it sends after that is read. Its body is read under a byte limit
  (`Ryker.Delivery.HTTPClient`).

  A failure says whether asking again could help: `{:retry, why}` for a
  server that could not be reached, timed out or failed (408, 429, 5xx), and
  `{:refused, why}` for one that turned the request down (a model that was
  never pulled answers 404) or does not speak chat completions. `why` is
  plain words with at most a short excerpt of what the server said; the
  prompt is never part of it.
  """

  alias Ryker.Delivery.HTTPClient
  alias Ryker.LocalRouting.{Endpoint, Schema}

  @maximum_response_bytes 2 * 1_024 * 1_024
  # A routing decision is a few hundred tokens; this bounds a model that
  # keeps writing.
  @maximum_tokens 4_096
  @excerpt_bytes 300

  @type answer :: %{
          content: String.t() | nil,
          finish_reason: String.t() | nil,
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          ms: non_neg_integer()
        }

  @spec ask(map(), String.t(), map()) ::
          {:ok, answer()} | {:error, {:retry | :refused, String.t()}}
  def ask(%{endpoint: endpoint, model: model, timeout_ms: timeout_ms} = options, prompt, schema) do
    body =
      Jason.encode!(%{
        "max_tokens" => @maximum_tokens,
        "messages" => [%{"content" => prompt, "role" => "user"}],
        "model" => model,
        "response_format" => %{
          "json_schema" => %{
            "name" => "ryker_routing_decision",
            "schema" => Schema.local(schema),
            "strict" => true
          },
          "type" => "json_schema"
        },
        "stream" => false,
        "temperature" => 0
      })

    request =
      HTTPClient.build(
        :post,
        Endpoint.completions(endpoint),
        [{"accept", "application/json"}, {"content-type", "application/json"}],
        body
      )

    finch = Map.get(options, :finch, Ryker.CoopFinch)
    started = System.monotonic_time(:millisecond)
    # The connection's own receive timeout is a backstop just past the firm
    # one, so the firm timeout is the one that fires and says so.
    task = Task.async(fn -> exchange(request, finch, timeout_ms + 1_000) end)

    result =
      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _late_or_stopped -> {:error, {:timeout, timeout_ms}}
      end

    elapsed = System.monotonic_time(:millisecond) - started
    classify(result, elapsed)
  end

  defp exchange(request, finch, receive_timeout) do
    HTTPClient.stream(request, finch, receive_timeout, @maximum_response_bytes)
  rescue
    error -> {:error, {:delivery_transport_unavailable, error}}
  catch
    kind, reason -> {:error, {:delivery_transport_unavailable, {kind, reason}}}
  end

  defp classify({:ok, %{status: 200, body: body}}, elapsed), do: completion(body, elapsed)

  defp classify({:ok, %{status: status, body: body}}, _elapsed)
       when status in [408, 429] or status >= 500,
       do: {:error, {:retry, "the local model's server answered #{status}#{excerpt(body)}"}}

  defp classify({:ok, %{status: status, body: body}}, _elapsed),
    do:
      {:error,
       {:refused, "the local model's server refused the request with #{status}#{excerpt(body)}"}}

  defp classify({:error, {:timeout, timeout_ms}}, _elapsed),
    do: {:error, {:retry, "the local model did not answer within #{seconds(timeout_ms)} s"}}

  defp classify({:error, {:delivery_protocol_error, :response_too_large}}, _elapsed),
    do: {:error, {:refused, "the local model's answer was larger than 2 MB"}}

  defp classify({:error, {:delivery_transport_unavailable, reason}}, _elapsed),
    do: {:error, {:retry, "could not reach the local model: #{describe(reason)}"}}

  defp classify({:error, _reason}, _elapsed),
    do: {:error, {:retry, "the local model's answer could not be read"}}

  # The first choice's text is the answer; the usage, when the server counts
  # tokens, says how much of the prompt it read and how much it wrote.
  defp completion(body, elapsed) do
    case Jason.decode(body) do
      {:ok, %{"choices" => [%{"message" => %{} = message} = choice | _rest]} = document} ->
        usage = if is_map(document["usage"]), do: document["usage"], else: %{}

        {:ok,
         %{
           content: if(is_binary(message["content"]), do: message["content"]),
           finish_reason: if(is_binary(choice["finish_reason"]), do: choice["finish_reason"]),
           input_tokens: count(usage["prompt_tokens"]),
           output_tokens: count(usage["completion_tokens"]),
           ms: elapsed
         }}

      _other ->
        {:error,
         {:refused,
          "the endpoint's answer is not an OpenAI chat completion; save the address that ends in /v1"}}
    end
  end

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_value), do: nil

  defp describe(%{__exception__: true} = error), do: Exception.message(error)
  defp describe(reason), do: inspect(reason, limit: 5, printable_limit: 100)

  defp excerpt(body) when is_binary(body) and body != "" do
    text =
      body
      |> String.replace_invalid("?")
      |> String.replace(<<0>>, "")
      |> String.slice(0, @excerpt_bytes)
      |> String.trim()

    if text == "", do: "", else: ": " <> text
  end

  defp excerpt(_body), do: ""

  defp seconds(ms) when rem(ms, 1_000) == 0, do: Integer.to_string(div(ms, 1_000))
  defp seconds(ms), do: :erlang.float_to_binary(ms / 1_000, [:compact, decimals: 3])
end
