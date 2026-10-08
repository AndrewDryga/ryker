defmodule Ryker.Embeddings.Worker do
  @moduledoc """
  Keeps a vector beside each request's routing digest (`Ryker.Embeddings`),
  so routing can search earlier work by meaning
  (`Ryker.Admission.CandidateSearch`).

  A digest's vector is cleared whenever its text changes: a new message, or
  the title Work gives it (`Ryker.Episodes.RoutingDigests`). This lane embeds
  the digests that have none, newest first, a batch at a time, and writes a
  vector only if the digest has not changed since it was read. It runs while
  `RYKER_EMBEDDINGS_URL` names a server (`Ryker.Runtime.Assembly`). An episode
  changing wakes it at once; a server that does not answer is asked again a
  minute later, and routing searches by words meanwhile.
  """
  use Ryker.PollingWorker, lane: :embeddings, interval: :poll_interval_ms
  alias Ryker.Embeddings
  alias Ryker.Episodes
  alias Ryker.PollingWorker
  alias Ryker.Repo
  require Logger

  @fields [:url, :model, :poll_interval_ms]
  @optional [:embed, :idle_interval_ms, :name]
  @batch 16

  def child_spec(configuration) do
    _options = options!(configuration)
    %{id: __MODULE__, start: {__MODULE__, :start_link, [configuration]}}
  end

  def start_link(configuration) do
    options = options!(configuration)
    GenServer.start_link(__MODULE__, options, name: options.name)
  end

  @doc false
  @spec options!(map() | keyword()) :: map()
  def options!(configuration) when is_map(configuration) or is_list(configuration) do
    configuration = Map.new(configuration)

    unless Enum.all?(@fields, &Map.has_key?(configuration, &1)) and
             Map.keys(configuration) -- (@fields ++ @optional) == [] and
             is_binary(configuration.url) and is_binary(configuration.model) and
             is_integer(configuration.poll_interval_ms) and configuration.poll_interval_ms > 0 do
      raise ArgumentError, "embeddings configuration has missing, unknown or invalid fields"
    end

    configuration
    |> Map.put_new(:idle_interval_ms, PollingWorker.idle_interval_ms())
    |> Map.put_new(:embed, &Embeddings.embed/2)
    |> Map.put_new(:name, __MODULE__)
  end

  @impl PollingWorker
  def setup(options), do: {:ok, options}

  @impl PollingWorker
  def wake_on(_state), do: [&Episodes.subscribe_episodes/0]

  @impl PollingWorker
  def poll(state) do
    case embed_next(state) do
      :idle ->
        state.idle_interval_ms

      {:ok, _embedded} ->
        0

      {:error, reason} ->
        Logger.warning(
          "embeddings: #{inspect(reason)}; routing searches earlier work by words until the server answers"
        )

        state.poll_interval_ms
    end
  end

  @doc """
  Embeds the next batch of digests that have no vector: `:idle` when none
  waits, how many were written, or why the server gave none.
  """
  @spec embed_next(map() | keyword()) :: :idle | {:ok, non_neg_integer()} | {:error, term()}
  def embed_next(options) do
    options = Map.new(options)

    digests =
      Episodes.RoutingDigest.Query.without_embedding()
      |> Episodes.RoutingDigest.Query.ordered_by_recently_updated()
      |> Episodes.RoutingDigest.Query.limit_to(@batch)
      |> Repo.all()

    case digests do
      [] -> :idle
      digests -> embed(digests, options)
    end
  end

  defp embed(digests, options) do
    texts = Enum.map(digests, &text/1)

    case options.embed.(texts, url: options.url, model: options.model, timeout_ms: 30_000) do
      {:ok, vectors} ->
        now = Repo.now!()

        written =
          digests
          |> Enum.zip(vectors)
          |> Enum.map(fn {digest, vector} -> write(digest, vector, options.model, now) end)
          |> Enum.sum()

        {:ok, written}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A digest with no words at all still gets a vector, so it is not asked
  # for again on every poll.
  defp text(digest) do
    case Episodes.RoutingDigests.embedding_text(digest) do
      "" -> "(no text)"
      text -> text
    end
  end

  # Only the digest as it was read: one that changed meanwhile keeps waiting
  # for a vector of its new text.
  defp write(digest, vector, model, now) do
    {count, _rows} =
      digest.episode_id
      |> Episodes.RoutingDigest.Query.by_episode_id()
      |> Episodes.RoutingDigest.Query.unchanged_since(digest)
      |> Episodes.RoutingDigest.Query.without_embedding()
      |> Repo.update_all(set: [embedding: vector, embedding_model: model, embedded_at: now])

    count
  end
end
