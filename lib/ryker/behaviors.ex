defmodule Ryker.Behaviors do
  @moduledoc """
  Operator-confirmed durable behavior and guidance.

  Model tools may create inert offers only. This module rechecks the delivered
  control, derives scope from host-owned identity and destination, and
  supersedes one exact logical entry. None of these records can widen Work,
  publication, or delivery authority. Reading behavior for a model lives in
  `Ryker.Behaviors.Recall`, and standing rules meeting the messages Ryker
  receives in `Ryker.Behaviors.StandingRules`.

  A behavior confirmed, switched, superseded, used or run is announced after
  its commit (`subscribe_behaviors/0`).
  """
  alias Ryker.Behaviors.Behavior
  alias Ryker.Behaviors.Recall
  alias Ryker.Behaviors.StandingRules
  alias Ryker.CanonicalJSON
  alias Ryker.Episodes
  alias Ryker.Memories
  alias Ryker.Operator
  alias Ryker.Records
  alias Ryker.Reference
  alias Ryker.Repo
  alias Ryker.Slack
  alias Ryker.UTCDateTime
  alias Ryker.Work

  @offer_kinds ~w(preference_offer guidance_offer standing_assignment_offer)
  @maximum_total 500
  @maximum_per_scope 100

  @doc """
  Turns a confirmed preference, guidance or standing-rule offer into its
  behavior: `{:ok, %{behavior: behavior, status: :confirmed}}`,
  `status: :duplicate` for an offer already confirmed, or `{:error, reason}`
  (`:behavior_offer_stale` for an offer no longer open).
  """
  @spec confirm(keyword() | map()) :: {:ok, map()} | {:error, term()}
  def confirm(attributes) do
    with {:ok, confirmation} <-
           Records.OfferConfirmation.new(attributes, :invalid_behavior_confirmation) do
      Repo.transaction(reviewed(fn -> confirm_locked(confirmation) end))
    end
  end

  @doc """
  Switches a behavior on or off, or deletes it: `{:ok, behavior}`, or
  `{:error, :behavior_not_found | :behavior_terminal}`.
  """
  @spec set_status(String.t(), :active | :disabled | :deleted) ::
          {:ok, Behavior.t()} | {:error, term()}
  def set_status(ref, status) when status in [:active, :disabled, :deleted] do
    with :ok <- reference(ref, :behavior_ref) do
      Repo.transaction(reviewed(fn -> set_status_locked(ref, status, nil) end))
    end
  end

  def set_status(_ref, _status), do: {:error, {:invalid_behavior, :status}}

  @doc "Changes one App Home behavior through revision-fenced operator action custody."
  @spec set_home_status(
          String.t(),
          :active | :disabled | :deleted,
          pos_integer(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, map()} | {:error, term()}
  def set_home_status(ref, status, expected_revision, actor_ref, workspace_ref, action_ref)
      when status in [:active, :disabled, :deleted] and is_integer(expected_revision) and
             expected_revision > 0 do
    with :ok <- reference(ref, :behavior_ref),
         :ok <- reference(actor_ref, :actor_ref),
         :ok <- reference(workspace_ref, :workspace_ref),
         :ok <- reference(action_ref, :action_ref) do
      Operator.Actions.run(
        %{
          action: :update,
          action_ref: action_ref,
          actor_ref: actor_ref,
          kind: "behavior",
          request: %{
            "expected_revision" => expected_revision,
            "status" => Atom.to_string(status),
            "workspace_ref" => workspace_ref
          },
          resource_ref: ref
        },
        reviewed(fn ->
          set_home_status_audited_locked(ref, status, expected_revision, actor_ref, workspace_ref)
        end)
      )
    end
  end

  def set_home_status(
        _ref,
        _status,
        _expected_revision,
        _actor_ref,
        _workspace_ref,
        _action_ref
      ),
      do: {:error, {:invalid_behavior, :status}}

  # Guidance is reviewed beside facts (`Ryker.Memories.Reviews`), so every
  # write here takes the review lock first, as Memories does, and a change to
  # guidance closes the reviews of its workspace it left with nothing to
  # decide (`dismiss_moot_reviews/1`). Deleted guidance left App Home offering
  # a review whose every button failed as stale, and two confirmations of the
  # same guidance raced into its unique index instead of one replacing the
  # other (2026-10-04 review).
  defp reviewed(change) do
    fn ->
      Memories.Reviews.lock_review_maintenance!()
      change.()
    end
  end

  # Every behavior write checked every pending review in every workspace,
  # though only guidance is ever reviewed (2026-10-04 review).
  defp dismiss_moot_reviews(%{kind: :guidance, workspace_ref: workspace_ref}),
    do: Memories.Reviews.dismiss_orphan_reviews("system:behavior-change", workspace_ref)

  defp dismiss_moot_reviews(_behavior), do: :ok

  @doc """
  Changes a rule from a control in the conversation `conversation_ref`: one
  App Home could change, or one kept to that conversation. Channel controls
  ran through the App Home gate alone, which refuses a channel's own rules
  (2026-10-04 review).
  """
  @spec set_conversation_status(
          String.t(),
          :active | :disabled | :deleted,
          pos_integer(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, map()} | {:error, term()}
  def set_conversation_status(
        ref,
        status,
        expected_revision,
        actor_ref,
        workspace_ref,
        conversation_ref,
        action_ref
      )
      when status in [:active, :disabled, :deleted] and is_integer(expected_revision) and
             expected_revision > 0 do
    with :ok <- reference(ref, :behavior_ref),
         :ok <- reference(actor_ref, :actor_ref),
         :ok <- reference(workspace_ref, :workspace_ref),
         :ok <- reference(conversation_ref, :conversation_ref),
         :ok <- reference(action_ref, :action_ref) do
      Operator.Actions.run(
        %{
          action: :update,
          action_ref: action_ref,
          actor_ref: actor_ref,
          kind: "behavior",
          request: %{
            "conversation_ref" => conversation_ref,
            "expected_revision" => expected_revision,
            "status" => Atom.to_string(status),
            "workspace_ref" => workspace_ref
          },
          resource_ref: ref
        },
        reviewed(fn ->
          set_home_status_audited_locked(
            ref,
            status,
            expected_revision,
            actor_ref,
            workspace_ref,
            conversation_ref
          )
        end)
      )
    end
  end

  def set_conversation_status(
        _ref,
        _status,
        _revision,
        _actor,
        _workspace,
        _conversation,
        _action
      ),
      do: {:error, {:invalid_behavior, :status}}

  defp set_home_status_audited_locked(
         ref,
         status,
         expected_revision,
         actor_ref,
         workspace_ref,
         conversation_ref \\ nil
       ) do
    case lock_behavior(ref) do
      nil ->
        {:error, :behavior_not_found}

      %Behavior{workspace_ref: actual} when actual != workspace_ref ->
        {:error, :behavior_workspace_mismatch}

      %Behavior{revision: actual} when actual != expected_revision ->
        {:error, :behavior_revision_stale}

      %Behavior{} = behavior ->
        if home_behavior_visible?(behavior, actor_ref) or
             (behavior.scope_kind == :conversation and behavior.scope_ref == conversation_ref) do
          updated = set_status_locked(ref, status, workspace_ref)

          {:ok,
           %{
             previous: %{
               "revision" => behavior.revision,
               "status" => Atom.to_string(behavior.status)
             },
             outcome: %{
               "revision" => updated.revision,
               "status" => Atom.to_string(updated.status)
             }
           }}
        else
          {:error, :behavior_unauthorized}
        end
    end
  end

  @doc """
  The standing rules of one channel that are on or off and not expired,
  oldest first; `[]` for refs that are not valid.
  """
  @spec assignments_for_channel(String.t(), String.t()) :: [Behavior.t()]
  def assignments_for_channel(workspace_ref, conversation_ref) do
    if Reference.valid?(workspace_ref) and Reference.valid?(conversation_ref) do
      now = Repo.now!()

      Behavior.Query.by_kind(:standing_assignment)
      |> Behavior.Query.by_workspace(workspace_ref)
      |> Behavior.Query.scoped_to(:conversation, conversation_ref)
      |> Behavior.Query.by_status([:active, :disabled])
      |> Behavior.Query.unexpired_at(now)
      |> Behavior.Query.ordered_by_oldest()
      |> Behavior.Query.limit_to(100)
      |> Repo.all()
    else
      []
    end
  end

  @doc """
  Switches a channel's standing rule on or off, or deletes it, from that
  channel: `{:ok, behavior}`, or `{:error, :behavior_not_found}`, and
  `:assignment_scope_mismatch` for a rule of another channel.
  """
  @spec manage_assignment(String.t(), :active | :disabled | :deleted, String.t(), String.t()) ::
          {:ok, Behavior.t()} | {:error, term()}
  def manage_assignment(ref, status, workspace_ref, conversation_ref)
      when status in [:active, :disabled, :deleted] do
    with :ok <- reference(ref, :behavior_ref),
         :ok <- reference(workspace_ref, :workspace_ref),
         :ok <- reference(conversation_ref, :conversation_ref) do
      Repo.transaction(fn ->
        manage_assignment_locked(ref, status, workspace_ref, conversation_ref)
      end)
    end
  end

  def manage_assignment(_ref, _status, _workspace_ref, _conversation_ref),
    do: {:error, {:invalid_behavior, :assignment}}

  defp manage_assignment_locked(ref, status, workspace_ref, conversation_ref) do
    case lock_behavior(ref) do
      %Behavior{
        kind: :standing_assignment,
        scope_kind: :conversation,
        workspace_ref: ^workspace_ref,
        scope_ref: ^conversation_ref
      } ->
        update_assignment_status(ref, status, workspace_ref)

      %Behavior{} ->
        Repo.rollback(:assignment_scope_mismatch)

      nil ->
        Repo.rollback(:behavior_not_found)
    end
  end

  defp update_assignment_status(ref, status, workspace_ref) do
    case set_status_locked(ref, status, workspace_ref) do
      {:error, reason} -> Repo.rollback(reason)
      behavior -> behavior
    end
  end

  # The behaviors context API for callers outside the state layer (Slack,
  # GitHub, the control plane, work submission). Reading behavior for a model
  # lives in `Ryker.Behaviors.Recall`, and standing rules meeting messages in
  # `Ryker.Behaviors.StandingRules`; callers inside the state layer call those
  # directly.

  @doc "The bounded confirmed behavior context for one exact episode turn."
  defdelegate model_context(episode, operator_ref, repository), to: Recall

  @doc "Whether an active channel rule matches this input's trusted source and event."
  defdelegate standing_match?(input), to: StandingRules

  @doc "Recorded rule inventories for many inputs in one query, keyed by input reference."
  defdelegate rule_inventories(input_refs), to: StandingRules

  defp confirm_locked(attributes) do
    with {:ok, record, episode, turn} <- lock_offer(attributes.record_ref),
         :ok <-
           Slack.ChannelFence.authorize_in_transaction(
             episode.destination_transport,
             episode.destination_conversation_ref
           ),
         :ok <- authorize_wide_offer(record, episode),
         :ok <- authorize_personal_offer(record, turn, attributes.actor_ref),
         :ok <- delivered_from?(episode, turn, attributes.target) do
      case Repo.one(Behavior.Query.by_offer_record_id(record.id)) do
        %Behavior{} = behavior ->
          %{behavior: behavior, status: :duplicate}

        nil when record.status == :open ->
          create_behavior(record, episode, attributes)

        nil ->
          Repo.rollback(:behavior_offer_stale)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Guidance or a preference for a whole repository or workspace applies in
  # every channel, so it is confirmed only where everyone can see it asked.
  defp authorize_wide_offer(
         %Records.Record{kind: kind, payload: %{"scope" => scope}},
         %Episodes.Episode{destination_transport: "slack"} = episode
       )
       when kind in ["guidance_offer", "preference_offer"] and
              scope in ["repository", "workspace"] do
    Slack.ChannelFence.authorize_public_in_transaction(
      episode.destination_transport,
      episode.destination_conversation_ref
    )
  end

  defp authorize_wide_offer(_record, _episode), do: :ok

  # A preference or a rule a person keeps for themselves ("mine") belongs to
  # whoever confirms it, so only the person who asked for it may. Guidance
  # went unchecked until 2026-09-30: anyone in the channel could confirm
  # someone else's rule and it became theirs.
  defp authorize_personal_offer(
         %Records.Record{kind: kind, payload: %{"scope" => "operator"}},
         %Work.Turn{submission: submission},
         actor_ref
       )
       when kind in ["preference_offer", "guidance_offer"] do
    case current_human_actors(submission) do
      [^actor_ref] -> :ok
      _other -> {:error, :behavior_offer_actor_mismatch}
    end
  end

  defp authorize_personal_offer(_record, _turn, _actor_ref), do: :ok

  defp current_human_actors(%{"context" => %{"mode" => "full", "inputs" => %{"items" => items}}}) do
    items
    |> Enum.filter(&(&1["current"] == true))
    |> human_actor_refs()
  end

  defp current_human_actors(%{
         "context" => %{"mode" => "continuation", "current_inputs" => %{"items" => items}}
       }),
       do: human_actor_refs(items)

  defp current_human_actors(_submission), do: []

  defp human_actor_refs(items) do
    items
    |> Enum.flat_map(fn
      %{"actor_ref" => actor_ref} when is_binary(actor_ref) ->
        if String.contains?(actor_ref, ":user:"), do: [actor_ref], else: []

      _invalid ->
        []
    end)
    |> Enum.uniq()
  end

  defp create_behavior(record, episode, attributes) do
    with {:ok, prepared} <- prepare_behavior(record, episode, attributes),
         :ok <- capacity(prepared),
         :ok <- supersede_existing(prepared),
         {:ok, behavior} <- insert_behavior(record, episode, attributes, prepared),
         {:ok, _confirmed} <- Records.confirm_offer(record, attributes) do
      dismiss_moot_reviews(behavior)
      %{behavior: behavior, status: :confirmed}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp prepare_behavior(
         %Records.Record{kind: "preference_offer", payload: payload},
         episode,
         attributes
       ) do
    prepare_scoped(:preference, payload["key"], payload, episode, attributes)
  end

  defp prepare_behavior(
         %Records.Record{kind: "guidance_offer", payload: payload},
         episode,
         attributes
       ) do
    prepare_scoped(:guidance, payload["subject"], payload, episode, attributes)
  end

  defp prepare_behavior(
         %Records.Record{
           kind: "standing_assignment_offer",
           payload: %{"source_kind" => _} = payload
         },
         episode,
         attributes
       ) do
    workspace = Episodes.Scope.workspace_ref(episode)

    with {:ok, expires_at} <- source_event_expiry(payload["expires_at"], attributes.occurred_at) do
      {:ok,
       %{
         expires_at: expires_at,
         identity_key: source_event_identity(payload),
         kind: :standing_assignment,
         payload: payload,
         scope_kind: :conversation,
         scope_ref: episode.destination_conversation_ref,
         workspace_ref: workspace
       }}
    end
  end

  defp prepare_scoped(kind, identity_key, payload, episode, attributes) do
    workspace = Episodes.Scope.workspace_ref(episode)
    scope_kind = scope_kind(payload["scope"])

    scope_ref =
      case scope_kind do
        :workspace -> workspace
        :conversation -> episode.destination_conversation_ref
        :repository -> payload["repository"]
        :operator -> attributes.actor_ref
      end

    {:ok,
     %{
       expires_at:
         Records.OfferConfirmation.expires_at(attributes.occurred_at, payload["expires_in"]),
       identity_key: identity_key,
       kind: kind,
       payload: payload,
       scope_kind: scope_kind,
       scope_ref: scope_ref,
       workspace_ref: workspace
     }}
  end

  defp capacity(prepared) do
    now = Repo.now!()

    existing? = existing_behavior?(prepared)
    total = active_behavior_count(prepared.workspace_ref, now)
    scoped = scoped_behavior_count(prepared, now)

    if existing? or (total < @maximum_total and scoped < @maximum_per_scope),
      do: :ok,
      else: {:error, :behavior_capacity_reached}
  end

  defp existing_behavior?(prepared) do
    prepared
    |> Behavior.Query.same_identity()
    |> Behavior.Query.by_status(:active)
    |> Repo.exists?()
  end

  defp active_behavior_count(workspace_ref, now) do
    Behavior.Query.by_workspace(workspace_ref)
    |> Behavior.Query.by_status(:active)
    |> Behavior.Query.unexpired_at(now)
    |> Repo.aggregate(:count)
  end

  defp scoped_behavior_count(prepared, now) do
    Behavior.Query.by_workspace(prepared.workspace_ref)
    |> Behavior.Query.scoped_to(prepared.scope_kind, prepared.scope_ref)
    |> Behavior.Query.by_status(:active)
    |> Behavior.Query.unexpired_at(now)
    |> Repo.aggregate(:count)
  end

  defp supersede_existing(prepared) do
    prepared
    |> Behavior.Query.same_identity()
    |> Behavior.Query.by_status(:active)
    |> Behavior.Query.ordered_by_id()
    |> Behavior.Query.lock_for_update()
    |> Repo.all()
    |> Enum.reject(&(&1.id == Map.get(prepared, :id)))
    |> Enum.each(&redact!(&1, :superseded, "replaced_payload_sha256"))
  end

  @doc """
  Ends every other active behavior with `behavior`'s identity, as confirming
  one or switching one on does, before a change leaves `behavior` active under
  it. Resuming or renaming a rule through an automation change ran into the
  active-identity index instead (2026-10-04 review).
  """
  @spec supersede_namesakes_in_transaction(Behavior.t()) :: :ok
  def supersede_namesakes_in_transaction(%Behavior{status: :active} = behavior),
    do: behavior |> Map.from_struct() |> supersede_existing()

  def supersede_namesakes_in_transaction(%Behavior{}), do: :ok

  defp insert_behavior(record, episode, attributes, prepared) do
    id = Repo.generate_id()
    now = Repo.now!()

    prepared
    |> Map.merge(%{
      confirmation_ref: attributes.confirmation_ref,
      confirmed_at: attributes.occurred_at,
      confirmed_by_actor_ref: attributes.actor_ref,
      id: id,
      offer_record_id: record.id,
      ref: "behavior:#{id}",
      source_conversation_ref: episode.destination_conversation_ref,
      source_message_ref: attributes.target.message_ref,
      source_thread_ref: attributes.target.thread_ref,
      source_transport: episode.destination_transport,
      status: :active
    })
    |> Behavior.Changeset.insert()
    |> Ecto.Changeset.put_change(:inserted_at, now)
    |> Ecto.Changeset.put_change(:updated_at, now)
    |> Repo.insert()
    |> case do
      {:ok, behavior} ->
        broadcast_behavior_updated(behavior.id)
        {:ok, behavior}

      {:error, changeset} ->
        {:error, {:behavior_persistence_failed, changeset.errors}}
    end
  end

  defp lock_behavior(ref),
    do: ref |> Behavior.Query.by_ref() |> Behavior.Query.lock_for_update() |> Repo.one()

  defp set_status_locked(ref, status, workspace_ref) do
    case lock_behavior(ref) do
      nil ->
        Repo.rollback(:behavior_not_found)

      %Behavior{workspace_ref: actual}
      when not is_nil(workspace_ref) and actual != workspace_ref ->
        Repo.rollback(:behavior_workspace_mismatch)

      %Behavior{status: ^status} = behavior ->
        behavior

      %Behavior{status: current} when current in [:deleted, :expired, :superseded] ->
        Repo.rollback(:behavior_terminal)

      %Behavior{} = behavior when status == :deleted ->
        deleted = redact!(behavior, :deleted, "deleted_payload_sha256")
        dismiss_moot_reviews(deleted)
        deleted

      %Behavior{} = behavior ->
        if status == :active, do: supersede_existing(Map.from_struct(behavior))
        broadcast_behavior_updated(behavior.id)

        updated =
          behavior
          |> Behavior.Changeset.update(%{revision: behavior.revision + 1, status: status})
          |> Repo.update!()

        dismiss_moot_reviews(updated)
        updated
    end
  end

  @doc """
  Ends `behavior` as `status`, keeping only a digest of what it said under
  `hash_field`, as a deleted fact does (`Ryker.Memories.redact!/3`). Deleted
  or replaced rules, guidance and preferences kept every word, and their
  source episode's history with them (2026-10-04 review).
  """
  @spec redact!(Behavior.t(), :deleted | :superseded | :expired, String.t()) :: Behavior.t()
  def redact!(%Behavior{} = behavior, status, hash_field)
      when status in [:deleted, :superseded, :expired] do
    broadcast_behavior_updated(behavior.id)

    behavior
    |> Behavior.Changeset.update(%{
      payload: %{hash_field => CanonicalJSON.digest(behavior.payload)},
      revision: behavior.revision + 1,
      status: status
    })
    |> Repo.update!()
  end

  @doc "Whether a behavior's payload is only the digest `redact!/3` left."
  @spec redacted?(map()) :: boolean()
  def redacted?(%{} = payload) when map_size(payload) == 1,
    do: payload |> Map.keys() |> hd() |> String.ends_with?("_payload_sha256")

  def redacted?(_payload), do: false

  defp home_behavior_visible?(
         %Behavior{scope_kind: :operator, scope_ref: actor_ref},
         actor_ref
       ),
       do: true

  defp home_behavior_visible?(%Behavior{kind: :guidance} = behavior, _actor_ref) do
    behavior.scope_kind in [:repository, :workspace] and
      behavior.payload["visibility"] == "workspace"
  end

  defp home_behavior_visible?(%Behavior{} = behavior, _actor_ref),
    do: behavior.scope_kind in [:repository, :workspace]

  defp scope_kind("workspace"), do: :workspace
  defp scope_kind("conversation"), do: :conversation
  defp scope_kind("repository"), do: :repository
  defp scope_kind("operator"), do: :operator

  defp lock_offer(record_ref) do
    case Records.lock_offer(record_ref, @offer_kinds) do
      {:error, :not_found} -> {:error, :behavior_offer_not_found}
      found -> found
    end
  end

  defp delivered_from?(episode, turn, target) do
    case Records.CardDelivery.delivered_from?(episode, turn, target) do
      :ok -> :ok
      {:error, :mismatch} -> {:error, :behavior_offer_delivery_mismatch}
      {:error, :not_delivered} -> {:error, :behavior_offer_not_delivered}
    end
  end

  defp source_event_expiry(nil, _confirmed_at), do: {:ok, nil}

  defp source_event_expiry(value, confirmed_at) when is_binary(value) do
    case UTCDateTime.parse(value) do
      {:ok, expires_at} ->
        if DateTime.compare(expires_at, confirmed_at) == :gt,
          do: {:ok, expires_at},
          else: {:error, :behavior_expiry_elapsed}

      _invalid ->
        {:error, :behavior_expiry_invalid}
    end
  end

  defp source_event_expiry(_value, _confirmed_at), do: {:error, :behavior_expiry_invalid}

  @doc """
  The identity of a source-event rule: a conversation keeps one active rule
  per title, and a rule confirmed or resumed under a title replaces the one
  that had it.
  """
  @spec source_event_identity(map()) :: String.t()
  def source_event_identity(payload),
    do: "source-event:" <> CanonicalJSON.digest([payload["title"]])

  defp reference(value, field) do
    if Reference.valid?(value), do: :ok, else: {:error, {:invalid_behavior_confirmation, field}}
  end

  # -- PubSub ------------------------------------------------------------------

  @doc """
  Subscribes the caller to behavior changes: `{:behavior_updated,
  behavior_id}` once a rule, preference or piece of guidance is confirmed,
  switched on or off, superseded, deleted, used, or a standing rule runs, and
  that change has committed. A turn's use of several pieces of guidance names
  one of them.
  """
  def subscribe_behaviors, do: Ryker.PubSub.subscribe(behaviors_topic())

  @doc "Stops the announcements `subscribe_behaviors/0` started."
  def unsubscribe_behaviors, do: Ryker.PubSub.unsubscribe(behaviors_topic())

  defp behaviors_topic, do: "behaviors"

  @doc """
  Internal — announces, after the outermost commit, that behavior
  `behavior_id` changed. Memory review, which edits and retires guidance
  beside facts, calls it too.
  """
  @spec broadcast_behavior_updated(Ecto.UUID.t()) :: :ok
  def broadcast_behavior_updated(behavior_id) do
    Repo.after_commit(fn ->
      Ryker.PubSub.broadcast(behaviors_topic(), {:behavior_updated, behavior_id})
    end)
  end
end
