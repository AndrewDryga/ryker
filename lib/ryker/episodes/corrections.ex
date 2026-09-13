defmodule Ryker.Episodes.Corrections do
  @moduledoc """
  Operator-confirmed repair of a routing mistake, without rewriting history.

  Correlation is a judgement, so it can be wrong in both directions: two
  channels can report one outage before either knows about the other, and an
  unrelated message can join work it was never part of. The repair moves the
  effective membership projection and records the original membership as an
  immutable correction; the event ledger and the model submissions built from
  it are never touched, and no completed action, approval or accepted answer
  is replayed.

  A correction is refused rather than guessed. Both episodes are locked in a
  stable order and every custody that could act on the moved evidence — a
  running turn, an undelivered answer, an open wait, a pending platform
  action, an unfinished publication, an active schedule — blocks it by name.
  Removing evidence also retires the Coop session that saw it: the next turn
  starts from a session whose transcript never contained the removed text.
  """

  import Ecto.Query

  alias Ryker.Delivery.PlatformAction
  alias Ryker.Episodes

  alias Ryker.Episodes.{
    AssociationCorrection,
    Command,
    CorrelationClaim,
    CorrelationClaims,
    Episode,
    Origin
  }

  alias Ryker.Operator.Actions
  alias Ryker.Publication.Publication
  alias Ryker.Repo
  alias Ryker.State.{EventSubscription, Schedule}
  alias Ryker.Work.{Session, Turn}

  @maximum_input_refs 200
  @open_publication_statuses [
    :review_pending,
    :review_ready,
    :reviewed,
    :publish_pending,
    :published_ready,
    :blocked
  ]

  @type request :: %{
          required(:action_ref) => String.t(),
          required(:actor_ref) => String.t(),
          required(:confirmation_ref) => String.t(),
          required(:reason) => String.t(),
          required(:source_episode_id) => Ecto.UUID.t(),
          optional(:target_episode_id) => Ecto.UUID.t(),
          optional(:input_refs) => [String.t()]
        }

  @doc """
  Moves every effective input of one episode into another and retires it.

  The retired episode keeps its whole history and stops being an active
  routing or work owner; its trusted occurrence claims move with the evidence
  so the surviving work still fences the occurrence.
  """
  @spec merge(request()) :: {:ok, map()} | {:error, term()}
  def merge(request), do: run(:merge, request)

  @doc "Detaches named inputs from an episode; they belong to no work until one admits them again."
  @spec split(request()) :: {:ok, map()} | {:error, term()}
  def split(request), do: run(:split, request)

  @doc "Moves named inputs from one episode to another existing episode."
  @spec reassign(request()) :: {:ok, map()} | {:error, term()}
  def reassign(request), do: run(:reassign, request)

  defp run(kind, request) do
    with {:ok, request} <- validate(kind, request) do
      Actions.run(
        %{
          action: :update,
          action_ref: request.action_ref,
          actor_ref: request.actor_ref,
          kind: "episode_association",
          resource_ref: request.source_episode_id,
          request: %{
            "confirmation_ref" => request.confirmation_ref,
            "input_refs" => request.input_refs,
            "kind" => Atom.to_string(kind),
            "reason" => request.reason,
            "target_episode_id" => request.target_episode_id
          }
        },
        fn -> apply_in_transaction(kind, request) end
      )
    end
  end

  defp apply_in_transaction(kind, request) do
    with {:ok, episodes} <- lock_episodes(kind, request),
         :ok <- reconcilable(episodes),
         {:ok, origins} <- movable_origins(kind, request, episodes.source) do
      correction = record_correction(kind, request, origins)

      previous = %{
        "input_refs" => Enum.map(origins, & &1.input_ref),
        "source_episode_id" => request.source_episode_id,
        "target_episode_id" => request.target_episode_id
      }

      outcome = apply_correction(kind, request, episodes, origins, correction)
      {:ok, %{outcome: outcome, previous: previous}}
    end
  end

  # Locking in identifier order keeps two operators correcting the same pair
  # from deadlocking on each other.
  defp lock_episodes(kind, request) do
    ids =
      Enum.uniq(Enum.reject([request.source_episode_id, request.target_episode_id], &is_nil/1))

    locked =
      Repo.all(
        from(episode in Episode,
          where: episode.id in ^ids,
          order_by: [asc: episode.id],
          lock: "FOR UPDATE"
        )
      )
      |> Map.new(&{&1.id, &1})

    source = Map.get(locked, request.source_episode_id)
    target = Map.get(locked, request.target_episode_id)

    cond do
      is_nil(source) ->
        {:error,
         {:episode_correction_denied, :episode_not_found, episode_id: request.source_episode_id}}

      kind != :split and is_nil(target) ->
        {:error,
         {:episode_correction_denied, :episode_not_found, episode_id: request.target_episode_id}}

      true ->
        {:ok, %{source: source, target: target}}
    end
  end

  defp reconcilable(%{source: source, target: target}) do
    [source, target]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce_while(:ok, fn episode, :ok ->
      case blocker(episode) do
        nil -> {:cont, :ok}
        reason -> {:halt, {:error, {:episode_correction_denied, reason, episode_id: episode.id}}}
      end
    end)
  end

  # Each blocker names one custody that would have to act on the moved
  # evidence. Reporting the first one by name is how an operator learns what
  # to settle, instead of reading "correction failed".
  defp blocker(%Episode{} = episode) do
    Enum.find_value(custody_checks(), fn {reason, open?} -> if open?.(episode), do: reason end)
  end

  defp custody_checks do
    [
      {:pending_delivery, &(&1.owner_kind == :delivery or turn?(&1.id, [:delivery_pending]))},
      {:active_turn, &(&1.owner_kind == :turn or turn?(&1.id, [:pending, :cancel_pending]))},
      {:open_wait, &(&1.owner_kind == :event or open_wait?(&1.id))},
      {:pending_action, &pending_action?(&1.id)},
      {:open_publication, &open_publication?(&1.id)},
      {:active_schedule, &active_schedule?(&1.id)}
    ]
  end

  defp turn?(episode_id, statuses) do
    Repo.exists?(
      from(turn in Turn, where: turn.episode_id == ^episode_id and turn.status in ^statuses)
    )
  end

  defp open_wait?(episode_id) do
    Repo.exists?(
      from(subscription in EventSubscription,
        where: subscription.episode_id == ^episode_id and subscription.status == :active
      )
    )
  end

  defp pending_action?(episode_id) do
    Repo.exists?(
      from(action in PlatformAction,
        where: action.episode_id == ^episode_id and action.status == :pending
      )
    )
  end

  defp open_publication?(episode_id) do
    Repo.exists?(
      from(publication in Publication,
        where:
          publication.episode_id == ^episode_id and
            publication.status in ^@open_publication_statuses
      )
    )
  end

  defp active_schedule?(episode_id) do
    Repo.exists?(
      from(schedule in Schedule,
        where: schedule.source_episode_id == ^episode_id and schedule.status == :active
      )
    )
  end

  defp movable_origins(:merge, _request, source) do
    {:ok, effective_origins(source.id)}
  end

  defp movable_origins(_kind, request, source) do
    origins =
      source.id |> effective_origins() |> Enum.filter(&(&1.input_ref in request.input_refs))

    found = MapSet.new(origins, & &1.input_ref)
    missing = Enum.reject(request.input_refs, &MapSet.member?(found, &1))

    if missing == [],
      do: {:ok, origins},
      else: {:error, {:episode_correction_denied, :input_not_owned, input_refs: missing}}
  end

  defp effective_origins(episode_id) do
    Repo.all(
      from(origin in Origin,
        where: origin.episode_id == ^episode_id and origin.effective,
        order_by: [asc: origin.occurred_at, asc: origin.sequence]
      )
    )
  end

  defp record_correction(kind, request, origins) do
    Repo.insert!(%AssociationCorrection{
      actor_ref: request.actor_ref,
      applied_at: DateTime.utc_now(),
      confirmation_ref: request.confirmation_ref,
      input_refs: Enum.map(origins, & &1.input_ref),
      kind: kind,
      reason: request.reason,
      source_episode_id: request.source_episode_id,
      target_episode_id: request.target_episode_id
    })
  end

  defp apply_correction(kind, request, episodes, origins, correction) do
    Enum.each(origins, &retire_origin(&1, correction))
    if kind != :split, do: Enum.each(origins, &attach_origin(&1, episodes.target, correction))
    if kind == :merge, do: move_claims(episodes)
    if kind == :merge, do: retire_source(episodes.source, request, correction)
    if kind != :merge, do: replace_contaminated_session(episodes.source)

    %{
      "correction_ref" => correction.id,
      "kind" => Atom.to_string(kind),
      "moved_input_count" => length(origins)
    }
  end

  # The original membership stays visible on the episode that held it: the row
  # remains, marked ineffective and pointing at the correction that moved it.
  defp retire_origin(%Origin{} = origin, correction) do
    origin
    |> Ecto.Changeset.change(effective: false, correction_ref: correction.id)
    |> Repo.update!()
  end

  defp attach_origin(%Origin{} = origin, %Episode{} = target, correction) do
    origin
    |> Map.take([
      :input_ref,
      :sequence,
      :native_input_id,
      :revision,
      :source_kind,
      :source_ref,
      :source_item_ref,
      :actor_ref,
      :transport,
      :conversation_ref,
      :thread_ref,
      :origin_kind,
      :root_ref,
      :occurred_at
    ])
    |> Map.merge(%{
      correction_ref: correction.id,
      effective: true,
      episode_id: target.id,
      inserted_at: DateTime.utc_now()
    })
    |> then(&struct!(Origin, &1))
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:episode_id, :input_ref])
  end

  # A claim the surviving work should now hold moves with the evidence. If the
  # target already claimed the same occurrence, the duplicate is retired.
  defp move_claims(%{source: source, target: target}) do
    owned =
      target.id
      |> then(&CorrelationClaims.active_by_episode([&1]))
      |> Map.get(target.id, [])
      |> MapSet.new(&{&1.scope_ref, &1.namespace, &1.occurrence_ref})

    source.id
    |> then(&CorrelationClaims.active_by_episode([&1]))
    |> Map.get(source.id, [])
    |> Enum.each(fn claim ->
      if MapSet.member?(owned, {claim.scope_ref, claim.namespace, claim.occurrence_ref}) do
        Repo.update_all(
          from(row in CorrelationClaim, where: row.id == ^claim.id),
          set: [status: :retired, updated_at: DateTime.utc_now()]
        )
      else
        Repo.update_all(
          from(row in CorrelationClaim, where: row.id == ^claim.id),
          set: [episode_id: target.id, updated_at: DateTime.utc_now()]
        )
      end
    end)
  end

  # A source that already finished is not an active owner, so there is nothing
  # to stop. One that is still waiting is stopped through the kernel's own
  # owner-fenced cancellation, which retires its queued work and waits; the
  # operator's full reason stays on the correction row.
  defp retire_source(%Episode{state: state}, _request, _correction)
       when state in [:complete, :cancelled],
       do: :ok

  defp retire_source(%Episode{} = source, _request, correction) do
    {:ok, _transition} =
      Episodes.apply(%Command.CancelEpisode{
        cancel_ref: "episode-correction:#{correction.id}",
        episode_key: source.key,
        expected_owner: %{kind: source.owner_kind, ref: source.owner_ref},
        occurred_at: DateTime.utc_now(),
        reason: "Merged into another episode by audited correction #{correction.id}."
      })

    :ok
  end

  # A warm session's transcript still holds the removed text. Installing the
  # next generation makes the following turn build a fresh Coop session rather
  # than continuing one whose exposure history is no longer eligible.
  defp replace_contaminated_session(%Episode{} = episode) do
    case Repo.one(
           from(session in Session,
             where: session.episode_id == ^episode.id and session.execution_kind == :work,
             order_by: [desc: session.generation],
             limit: 1
           )
         ) do
      %Session{coop_session_id: coop_session_id} = session when is_binary(coop_session_id) ->
        Repo.insert!(%Session{
          id: Ecto.UUID.generate(),
          episode_id: episode.id,
          execution_kind: :work,
          policy: session.policy,
          policy_digest: session.policy_digest,
          authority_digest: session.authority_digest,
          repository_ref: session.repository_ref,
          repository_context: session.repository_context,
          workspace_task: session.workspace_task,
          external_ref: "episode:#{episode.id}:session:#{session.generation + 1}",
          generation: session.generation + 1,
          create_generation: 1
        })

      _unbound_or_absent ->
        :ok
    end
  end

  defp validate(kind, request) when is_map(request) do
    request = Map.merge(%{input_refs: [], target_episode_id: nil}, request)

    with :ok <- keys(request),
         :ok <- reference(request.action_ref, :action_ref),
         :ok <- reference(request.actor_ref, :actor_ref),
         :ok <- reference(request.confirmation_ref, :confirmation_ref),
         :ok <- reason(request.reason),
         :ok <- uuid(request.source_episode_id, :source_episode_id),
         :ok <- target(kind, request),
         :ok <- input_refs(kind, request.input_refs) do
      {:ok, request}
    end
  end

  defp validate(_kind, _request), do: {:error, {:invalid_episode_correction, :request}}

  defp keys(request) do
    if Enum.sort(Map.keys(request)) ==
         ~w(action_ref actor_ref confirmation_ref input_refs reason source_episode_id target_episode_id)a,
       do: :ok,
       else: {:error, {:invalid_episode_correction, :request}}
  end

  defp target(:split, %{target_episode_id: nil}), do: :ok

  defp target(:split, _request),
    do: {:error, {:invalid_episode_correction, :target_episode_id}}

  defp target(_kind, %{source_episode_id: same, target_episode_id: same}),
    do: {:error, {:invalid_episode_correction, :target_episode_id}}

  defp target(_kind, request), do: uuid(request.target_episode_id, :target_episode_id)

  defp input_refs(:merge, []), do: :ok
  defp input_refs(:merge, _refs), do: {:error, {:invalid_episode_correction, :input_refs}}

  defp input_refs(_kind, refs)
       when is_list(refs) and refs != [] and length(refs) <= @maximum_input_refs do
    if Enum.uniq(refs) == refs and Enum.all?(refs, &(reference(&1, :input_refs) == :ok)),
      do: :ok,
      else: {:error, {:invalid_episode_correction, :input_refs}}
  end

  defp input_refs(_kind, _refs), do: {:error, {:invalid_episode_correction, :input_refs}}

  defp reason(reason)
       when is_binary(reason) and byte_size(reason) in 1..2_048 do
    if String.valid?(reason) and String.trim(reason) != "",
      do: :ok,
      else: {:error, {:invalid_episode_correction, :reason}}
  end

  defp reason(_reason), do: {:error, {:invalid_episode_correction, :reason}}

  defp uuid(value, field) do
    case Ecto.UUID.cast(value) do
      {:ok, ^value} -> :ok
      _invalid -> {:error, {:invalid_episode_correction, field}}
    end
  end

  defp reference(value, field)
       when is_binary(value) and byte_size(value) in 1..1_024 do
    if String.valid?(value) and String.trim(value) != "" and
         :binary.match(value, <<0>>) == :nomatch,
       do: :ok,
       else: {:error, {:invalid_episode_correction, field}}
  end

  defp reference(_value, field), do: {:error, {:invalid_episode_correction, field}}
end
