defmodule Responder.Slack.Inbox do
  @moduledoc """
  Transactional, idempotent custody for normalized Slack inputs.

  Recording does not classify the message and does not create an episode. It
  only proves which exact Slack event a later model decision is about.
  """

  import Ecto.Query

  alias Responder.Repo
  alias Responder.Slack.Inbox.{Entry, EntryChangeset}
  alias Responder.Slack.Input

  @ref_prefix "slack-input:"

  @type receipt :: %{entry: Entry.t(), status: :recorded | :duplicate}

  @spec record(Input.t()) :: {:ok, receipt()} | {:error, term()}
  def record(input) do
    with {:ok, input} <- Input.prepare(input) do
      input
      |> record_transaction()
      |> transaction_result()
    end
  end

  @spec fetch(String.t()) :: {:ok, Entry.t()} | :error
  def fetch(@ref_prefix <> id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Entry{} = entry <- Repo.get(Entry, id) do
      {:ok, entry}
    else
      _other -> :error
    end
  end

  def fetch(_ref), do: :error

  @spec ref(Entry.t()) :: String.t()
  def ref(%Entry{id: id}) when is_binary(id), do: @ref_prefix <> id

  defp record_transaction(input) do
    Repo.transaction(fn ->
      dedupe_key = Input.dedupe_key(input)

      with :ok <- lock(dedupe_key),
           {:ok, receipt} <- reconcile(input, load(dedupe_key)) do
        receipt
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp lock(dedupe_key) do
    case Repo.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [dedupe_key]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, {:store_failed, :source_lock, reason}}
    end
  end

  defp load(dedupe_key) do
    Repo.one(from(entry in Entry, where: entry.dedupe_key == ^dedupe_key, lock: "FOR UPDATE"))
  end

  defp reconcile(input, nil) do
    input
    |> EntryChangeset.insert(Ecto.UUID.generate())
    |> Repo.insert()
    |> case do
      {:ok, entry} -> {:ok, %{entry: entry, status: :recorded}}
      {:error, changeset} -> {:error, {:persistence_failed, :slack_input, changeset.errors}}
    end
  end

  defp reconcile(input, %Entry{} = entry) do
    submitted = Input.fingerprint(input)

    if entry.event_fingerprint == submitted do
      {:ok, %{entry: entry, status: :duplicate}}
    else
      {:error,
       {:input_conflict,
        dedupe_key: entry.dedupe_key,
        stored_fingerprint: entry.event_fingerprint,
        submitted_fingerprint: submitted}}
    end
  end

  defp transaction_result({:ok, receipt}), do: {:ok, receipt}
  defp transaction_result({:error, reason}), do: {:error, reason}
end
