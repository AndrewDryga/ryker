defmodule Ryker.Operator.SlackReplay do
  @moduledoc """
  Creates private, no-delivery replays from retained Slack ingress custody.

  Replays preserve the normalized source input and frozen Work profile, but use
  a fresh idempotent event identity and the host-owned shadow execution mode.
  """

  import Ecto.Query

  alias Ryker.CanonicalJSON
  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Ingress.{Inbox, Input, WorkProfile}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Operator.{Actions, Reference}
  alias Ryker.Repo
  alias Ryker.Work.Turn

  @event_prefix "operator-slack-replay:"

  @spec enqueue(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def enqueue(source_input_ref, request_ref, options) do
    with :ok <- reference(source_input_ref, :source_input_ref),
         :ok <- reference(request_ref, :request_ref),
         {:ok, settings} <- settings(options) do
      Actions.run(
        %{
          action: :replay,
          action_ref: settings.action_ref,
          actor_ref: settings.actor_ref,
          kind: "slack",
          request: %{"request_ref" => request_ref},
          resource_ref: source_input_ref
        },
        fn -> enqueue_replay(source_input_ref, request_ref) end
      )
    end
  end

  defp enqueue_replay(source_input_ref, request_ref) do
    with {:ok, source} <- source(source_input_ref),
         {:ok, profile} <- restore_profile(source),
         {:ok, input} <- replay_input(source, request_ref),
         {:ok, receipt} <- Inbox.record(input, execution_mode: :shadow, work_profile: profile) do
      {:ok,
       %{
         previous: %{
           "source_input_ref" => Inbox.ref(source),
           "source_status" => Atom.to_string(source.status),
           "work_profile_sha256" => CanonicalJSON.digest(source.work_profile)
         },
         outcome: %{
           "replay_input_ref" => Inbox.ref(receipt.entry),
           "source_input_ref" => Inbox.ref(source),
           "status" => Atom.to_string(receipt.status)
         }
       }}
    end
  end

  @spec fetch(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch(replay_input_ref) do
    with {:ok, %Entry{execution_mode: :shadow} = entry} <- fetch_replay(replay_input_ref),
         {:ok, source_id} <- source_id(entry.event_ref) do
      episode = if entry.episode_id, do: Repo.get(Episode, entry.episode_id), else: nil
      turn = latest_turn(entry.episode_id)

      {:ok,
       %{
         admission_status: entry.status,
         episode_ref: episode && episode.key,
         execution_mode: entry.execution_mode,
         outcome: replay_outcome(entry.episode_id),
         replay_input_ref: Inbox.ref(entry),
         source_input_ref: "ingress-input:#{source_id}",
         work_status: turn && turn.status
       }}
    else
      _unavailable -> {:error, :slack_replay_not_found}
    end
  end

  defp source(source_input_ref) do
    case Inbox.fetch(source_input_ref) do
      {:ok, %Entry{operational_pruned_at: at}} when not is_nil(at) ->
        {:error, :slack_replay_source_pruned}

      {:ok, %Entry{source_kind: "slack", event_kind: :message, execution_mode: :live} = entry} ->
        {:ok, entry}

      {:ok, %Entry{}} ->
        {:error, :slack_replay_source_invalid}

      :error ->
        {:error, :slack_replay_source_not_found}
    end
  end

  defp restore_profile(%Entry{work_profile: %{} = document}), do: WorkProfile.restore(document)
  defp restore_profile(%Entry{}), do: {:error, :slack_replay_work_profile_missing}

  defp replay_input(source, request_ref) do
    Input.new(%{
      actor: %{kind: source.actor_kind, ref: source.actor_ref},
      content: source.content,
      destination: %{
        conversation_ref: source.destination_conversation_ref,
        thread_ref: source.destination_thread_ref,
        transport: source.destination_transport
      },
      event_kind: source.event_kind,
      event_ref: replay_event_ref(source.id, request_ref),
      native_input_id: source.native_input_id,
      occurred_at: source.occurred_at,
      occurred_at_source: source.occurred_at_source,
      revision: source.revision,
      source: %{kind: source.source_kind, ref: source.source_ref},
      source_capabilities: source.source_capabilities,
      source_item_ref: source.source_item_ref
    })
  end

  defp replay_event_ref(source_id, request_ref) do
    @event_prefix <> source_id <> ":" <> CanonicalJSON.digest(request_ref)
  end

  defp fetch_replay(replay_input_ref) do
    case Inbox.fetch(replay_input_ref) do
      {:ok, %Entry{event_ref: @event_prefix <> _rest} = entry} -> {:ok, entry}
      _unavailable -> :error
    end
  end

  defp source_id(@event_prefix <> rest) do
    case String.split(rest, ":", parts: 2) do
      [id, digest] when byte_size(digest) == 64 ->
        case Ecto.UUID.cast(id) do
          {:ok, normalized} when normalized == id -> {:ok, id}
          _invalid -> :error
        end

      _invalid ->
        :error
    end
  end

  defp source_id(_event_ref), do: :error

  defp latest_turn(nil), do: nil

  defp latest_turn(episode_id) do
    Repo.one(
      from(turn in Turn,
        where: turn.episode_id == ^episode_id,
        order_by: [desc: turn.inserted_at, desc: turn.id],
        limit: 1
      )
    )
  end

  defp replay_outcome(nil), do: nil

  defp replay_outcome(episode_id) do
    event =
      Repo.one(
        from(event in Event,
          where: event.episode_id == ^episode_id and event.kind == :result_accepted,
          order_by: [desc: event.sequence],
          limit: 1
        )
      )

    case event do
      %Event{payload: %{"decision_reason" => reason, "delivery" => "none"}}
      when is_binary(reason) and byte_size(reason) in 1..960 ->
        %{decision_reason: reason, delivery: :none, status: :accepted}

      %Event{} ->
        %{status: :invalid}

      nil ->
        nil
    end
  end

  defp settings(options) when is_list(options) do
    with true <- Keyword.keyword?(options),
         keys <- Keyword.keys(options),
         true <- Enum.uniq(keys) == keys,
         true <- Enum.sort(keys) == [:action_ref, :actor_ref],
         {:ok, action_ref} <- Keyword.fetch(options, :action_ref),
         {:ok, actor_ref} <- Keyword.fetch(options, :actor_ref),
         :ok <- reference(action_ref, :action_ref),
         :ok <- reference(actor_ref, :actor_ref) do
      {:ok, %{action_ref: action_ref, actor_ref: actor_ref}}
    else
      _invalid -> {:error, {:invalid_slack_replay, :options}}
    end
  end

  defp settings(_options), do: {:error, {:invalid_slack_replay, :options}}

  defp reference(value, field), do: Reference.check(value, field, :invalid_slack_replay)
end
