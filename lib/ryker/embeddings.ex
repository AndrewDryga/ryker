defmodule Ryker.Embeddings do
  @moduledoc """
  Vectors of what a text is about, for routing's search by meaning.

  Andrew, 2026-09-30: routing's search for earlier work "won't actually work
  in real life". It compared words, so a message that says the same thing in
  other words, or in Ukrainian or Spanish about work discussed in English,
  never found its work. A multilingual embedding model (bge-m3, run beside
  Ryker by `scripts/embedding-service.sh`) reads more than a hundred languages
  into one space: the routing search benchmark's Ukrainian "is the production
  database still down?" lands nearest the English Postgres outage.

  `RYKER_EMBEDDINGS_URL` names any server that answers the OpenAI embeddings
  API (`POST /v1/embeddings`); `RYKER_EMBEDDINGS_MODEL` names the model, bge-m3
  unless set. Without it, or while it does not answer, routing searches by
  words and identifiers alone. Every request is bounded in time and in the
  size of its answer, and every vector comes back normalized to length one,
  so a dot product is the cosine.
  """
  alias Ryker.Delivery

  @default_model "bge-m3"
  @maximum_texts 32
  @maximum_characters 8_000
  @maximum_dimensions 4_096
  @maximum_response_bytes 16 * 1_024 * 1_024

  @type vector :: [float()]

  @doc "The configured server, or nil when search by meaning is off."
  @spec url() :: String.t() | nil
  def url, do: valid_url(System.get_env("RYKER_EMBEDDINGS_URL"))

  @doc "The model the configured server is asked for."
  @spec model() :: String.t()
  def model do
    case System.get_env("RYKER_EMBEDDINGS_MODEL") do
      model when is_binary(model) and model != "" -> model
      _unset -> @default_model
    end
  end

  @doc """
  One normalized vector per text, in order. Options: `:url`, `:model`,
  `:timeout_ms`, and `:request` (a test double for the HTTP call).
  """
  @spec embed([String.t()], keyword()) :: {:ok, [vector()]} | {:error, term()}
  def embed(texts, options \\ [])

  def embed(texts, options)
      when is_list(texts) and texts != [] and length(texts) <= @maximum_texts do
    url = Keyword.get_lazy(options, :url, &url/0)
    model = Keyword.get_lazy(options, :model, &model/0)
    timeout = Keyword.get(options, :timeout_ms, 5_000)
    request = Keyword.get(options, :request, &request/3)

    with true <- is_binary(url) || {:error, :not_configured},
         true <- Enum.all?(texts, &(is_binary(&1) and &1 != "")) || {:error, :invalid_text},
         body =
           Jason.encode!(%{
             "input" => Enum.map(texts, &String.slice(&1, 0, @maximum_characters)),
             "model" => model
           }),
         {:ok, answer} <- request.(endpoint(url), body, timeout) do
      vectors(answer, length(texts))
    end
  end

  def embed(_texts, _options), do: {:error, :invalid_text}

  # One POST, and its JSON answer or why there is none.
  @spec request(String.t(), iodata(), pos_integer()) :: {:ok, map()} | {:error, term()}
  defp request(url, body, timeout_ms) do
    request =
      Delivery.HTTPClient.build(
        :post,
        url,
        [{"content-type", "application/json"}, {"accept", "application/json"}],
        body
      )

    task =
      Task.async(fn ->
        try do
          Delivery.HTTPClient.stream(
            request,
            Ryker.CoopFinch,
            timeout_ms + 1_000,
            @maximum_response_bytes
          )
        rescue
          error -> {:error, {:transport, error.__struct__}}
        catch
          kind, _reason -> {:error, {:transport, kind}}
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, %{status: 200, body: body}}} ->
        case Jason.decode(body) do
          {:ok, %{} = answer} -> {:ok, answer}
          _unreadable -> {:error, :unreadable_answer}
        end

      {:ok, {:ok, %{status: status}}} ->
        {:error, {:status, status}}

      {:ok, {:error, _reason}} ->
        {:error, :unreachable}

      _late ->
        {:error, :timeout}
    end
  end

  defp vectors(%{"data" => data}, count) when is_list(data) and length(data) == count do
    vectors =
      data
      |> Enum.sort_by(&(&1["index"] || 0))
      |> Enum.map(&normalize(&1["embedding"]))

    dimensions = vectors |> Enum.map(&length(&1 || [])) |> Enum.uniq()

    if Enum.all?(vectors, &is_list/1) and
         match?([dimension] when dimension in 1..@maximum_dimensions, dimensions),
       do: {:ok, vectors},
       else: {:error, :unreadable_answer}
  end

  defp vectors(_answer, _count), do: {:error, :unreadable_answer}

  defp normalize(vector) when is_list(vector) and vector != [] do
    if Enum.all?(vector, &is_number/1) do
      norm = vector |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()
      if norm > 0, do: Enum.map(vector, &(&1 / norm)), else: nil
    end
  end

  defp normalize(_vector), do: nil

  defp endpoint(url), do: String.trim_trailing(url, "/") <> "/v1/embeddings"

  defp valid_url(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        value

      _other ->
        nil
    end
  end

  defp valid_url(_value), do: nil
end
