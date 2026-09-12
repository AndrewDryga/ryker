defmodule Responder.Slack.ChannelConfigurations do
  @moduledoc """
  Durable Slack channel membership and typed setup custody.

  A joined channel is configured with defaults the moment Responder is added;
  the optional setup Q&A and the welcome controls only revise that row. Slack
  presentation is deliberately outside this module. A card or message is only
  an authenticated input to this state machine; it cannot grant authority,
  select an unconfigured repository, or partially save a draft.
  """

  import Ecto.Query

  alias Responder.CanonicalJSON
  alias Responder.Repo
  alias Responder.State.{Continuity, Memories}

  alias Responder.Slack.{
    ChannelConfiguration,
    ChannelConfigurationChangeset,
    ChannelFence,
    ChannelMembership,
    ChannelMembershipEvent,
    ChannelSettings,
    ConfigurationAction,
    ConfigurationSession
  }

  @membership_fields [:actor_ref, :channel_ref, :event_ref, :kind, :occurred_at, :workspace_ref]
  @participation_change_fields [
    :actor_ref,
    :channel_ref,
    :configuration_ref,
    :event_ref,
    :expected_revision,
    :occurred_at,
    :participation,
    :workspace_ref
  ]
  @reconfiguration_fields [
    :actor_ref,
    :channel_ref,
    :event_ref,
    :occurred_at,
    :thread_ref,
    :workspace_ref
  ]
  @action_fields [
    :action,
    :actor_ref,
    :channel_ref,
    :event_ref,
    :message_ref,
    :occurred_at,
    :session_ref,
    :source,
    :thread_ref,
    :value,
    :workspace_ref
  ]
  @membership_kinds [:joined, :left, :deleted]
  @participation [:mentions, :proactive, :shadow]
  @alerts [:reply, :offer, :automatic]
  @session_seconds 30 * 60

  @type catalog :: %{
          optional(:on_call_count) => non_neg_integer(),
          optional(:repository_urls) => %{String.t() => String.t()},
          default_repository: String.t(),
          repository_refs: [String.t()]
        }

  @spec observe_membership(map() | keyword(), catalog()) :: {:ok, map()} | {:error, term()}
  def observe_membership(attributes, catalog) do
    with {:ok, attributes} <- exact_map(attributes, @membership_fields, :membership),
         :ok <- membership_attributes(attributes),
         {:ok, catalog} <- catalog(catalog) do
      Repo.transaction(fn -> observe_membership_locked(attributes, catalog) end)
      |> transaction_result()
    end
  end

  @spec start_reconfiguration(map() | keyword(), catalog()) :: {:ok, map()} | {:error, term()}
  def start_reconfiguration(attributes, catalog) do
    with {:ok, attributes} <- exact_map(attributes, @reconfiguration_fields, :reconfiguration),
         :ok <- reconfiguration_attributes(attributes),
         {:ok, catalog} <- catalog(catalog) do
      Repo.transaction(fn -> start_reconfiguration_locked(attributes, catalog) end)
      |> transaction_result()
    end
  end

  @spec reconcile_joined(
          String.t(),
          [%{channel_ref: String.t(), external_shared: boolean() | nil, private: boolean()}],
          catalog()
        ) ::
          {:ok, [map()]} | {:error, term()}
  def reconcile_joined(workspace_ref, channels, catalog) do
    with :ok <- reference(workspace_ref, :workspace_ref, 256),
         :ok <- bounded_channels(channels),
         {:ok, catalog} <- catalog(catalog) do
      reconcile_joined_channels(workspace_ref, channels, catalog)
    end
  end

  @doc "Marks joined memberships missing from one complete Slack snapshot as left."
  @spec reconcile_absent(
          String.t(),
          [%{channel_ref: String.t(), external_shared: boolean() | nil, private: boolean()}],
          DateTime.t()
        ) :: {:ok, non_neg_integer()} | {:error, term()}
  def reconcile_absent(workspace_ref, channels, snapshot_started_at) do
    with :ok <- reference(workspace_ref, :workspace_ref, 256),
         :ok <- bounded_channels(channels),
         :ok <- utc(snapshot_started_at, :snapshot_started_at) do
      present_refs = Enum.map(channels, & &1.channel_ref)

      Repo.transaction(fn ->
        reconcile_absent_locked(workspace_ref, present_refs, snapshot_started_at)
      end)
      |> transaction_result()
    end
  end

  defp reconcile_absent_locked(workspace_ref, present_refs, snapshot_started_at) do
    query =
      from(membership in ChannelMembership,
        where:
          membership.workspace_ref == ^workspace_ref and membership.status == :joined and
            membership.updated_at <= ^snapshot_started_at,
        order_by: [asc: membership.channel_ref],
        lock: "FOR UPDATE"
      )

    query =
      if present_refs == [],
        do: query,
        else: from(membership in query, where: membership.channel_ref not in ^present_refs)

    memberships = Repo.all(query)
    now = database_now!()

    Enum.each(memberships, fn membership ->
      cancel_active_sessions!(membership, :cancelled)
      leave_membership!(membership, now)
    end)

    length(memberships)
  end

  defp reconcile_joined_channels(workspace_ref, channels, catalog) do
    Enum.reduce_while(channels, {:ok, []}, fn channel, {:ok, results} ->
      case reconcile_joined_channel(workspace_ref, channel, catalog) do
        {:ok, result} -> {:cont, {:ok, [result | results]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_results()
  end

  defp reverse_results({:ok, results}), do: {:ok, Enum.reverse(results)}
  defp reverse_results({:error, _reason} = error), do: error

  @spec bind_prompt(Ecto.UUID.t(), pos_integer(), String.t(), String.t() | nil) ::
          {:ok, ConfigurationSession.t()} | {:error, term()}
  def bind_prompt(session_ref, revision, message_ref, thread_ref) do
    with :ok <- uuid(session_ref, :session_ref),
         :ok <- positive(revision, :revision),
         :ok <- reference(message_ref, :message_ref),
         :ok <- optional_reference(thread_ref, :thread_ref) do
      Repo.transaction(fn ->
        bind_prompt_locked(session_ref, revision, message_ref, thread_ref)
      end)
      |> transaction_result()
    end
  end

  @spec apply_action(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def apply_action(attributes) do
    with {:ok, attributes} <- exact_map(attributes, @action_fields, :action),
         :ok <- action_attributes(attributes) do
      Repo.transaction(fn -> apply_action_locked(attributes) end)
      |> transaction_result()
    end
  end

  @spec fetch_session(Ecto.UUID.t()) ::
          {:ok, ConfigurationSession.t()} | {:error, :configuration_session_not_found}
  def fetch_session(session_ref) do
    case Ecto.UUID.cast(session_ref) do
      {:ok, session_ref} ->
        case Repo.get(ConfigurationSession, session_ref) do
          %ConfigurationSession{} = session -> {:ok, session}
          nil -> {:error, :configuration_session_not_found}
        end

      :error ->
        {:error, :configuration_session_not_found}
    end
  end

  @spec configuration(String.t(), String.t()) :: ChannelConfiguration.t() | nil
  def configuration(workspace_ref, channel_ref) do
    Repo.get_by(ChannelConfiguration, workspace_ref: workspace_ref, channel_ref: channel_ref)
  end

  @spec membership(String.t(), String.t()) :: ChannelMembership.t() | nil
  def membership(workspace_ref, channel_ref) do
    Repo.get_by(ChannelMembership, workspace_ref: workspace_ref, channel_ref: channel_ref)
  end

  @doc """
  Changes only participation from the welcome message, preserving the saved
  repository, alert policy and invitations. The control names the exact
  configuration revision it was rendered from, so a stale card cannot save.
  """
  @spec change_participation(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def change_participation(attributes) do
    with {:ok, attributes} <-
           exact_map(attributes, @participation_change_fields, :participation_change),
         :ok <- participation_change_attributes(attributes) do
      Repo.transaction(fn -> change_participation_locked(attributes) end)
      |> transaction_result()
    end
  end

  @doc "Records the welcome message that presents this channel's effective settings."
  @spec bind_welcome(String.t(), String.t(), String.t()) ::
          {:ok, ChannelConfiguration.t()} | {:error, term()}
  def bind_welcome(workspace_ref, channel_ref, message_ref) do
    with :ok <- reference(workspace_ref, :workspace_ref, 256),
         :ok <- reference(channel_ref, :channel_ref, 256),
         :ok <- reference(message_ref, :message_ref, 256) do
      Repo.transaction(fn -> bind_welcome_locked(workspace_ref, channel_ref, message_ref) end)
      |> transaction_result()
    end
  end

  @doc """
  One effective-settings projection shared by the welcome, the setup Q&A
  completion and settings shown on request. Reading never mutates.

  `overrides` is the resolved participation view (`ChannelSettings.effective/3`
  or the incident-room equivalent) and already names the layer that decided it.
  """
  @spec effective_settings(String.t(), String.t(), catalog(), map()) ::
          {:ok, map()} | {:error, term()}
  def effective_settings(workspace_ref, channel_ref, catalog, overrides) do
    with :ok <- reference(workspace_ref, :workspace_ref, 256),
         :ok <- reference(channel_ref, :channel_ref, 256),
         {:ok, catalog} <- catalog(catalog),
         :ok <- overrides(overrides) do
      configuration = configuration(workspace_ref, channel_ref)
      {:ok, settings_document(configuration, catalog, overrides)}
    end
  end

  @doc false
  @spec settings_document(ChannelConfiguration.t() | nil, catalog(), map()) :: map()
  def settings_document(configuration, catalog, overrides) do
    participation = ChannelSettings.effective_participation(overrides)

    %{
      "alert_policy" => alert_policy(configuration),
      "configuration_ref" => configuration && configuration.id,
      "customized_by" => configuration && configuration.actor_ref,
      "default_repository" => default_repository(configuration, catalog),
      "invitations" => %{
        "user_group_refs" => (configuration && configuration.invite_user_group_refs) || [],
        "user_refs" => (configuration && configuration.invite_user_refs) || []
      },
      "observation" => %{
        "on" => participation.value == :shadow,
        "source" => Atom.to_string(overrides.shadow.source)
      },
      "participation" => %{
        "source" => Atom.to_string(participation.source),
        "value" => Atom.to_string(participation.value)
      },
      "repositories" =>
        Enum.map(catalog.repository_refs, fn repository_ref ->
          %{
            "ref" => repository_ref,
            "url" => catalog |> Map.get(:repository_urls, %{}) |> Map.get(repository_ref)
          }
        end),
      "revision" => configuration && configuration.revision
    }
  end

  defp alert_policy(%ChannelConfiguration{alert_policy: policy}), do: Atom.to_string(policy)
  defp alert_policy(nil), do: "reply"

  defp default_repository(%ChannelConfiguration{repository_ref: repository_ref}, catalog) do
    if repository_ref in catalog.repository_refs, do: repository_ref, else: nil
  end

  defp default_repository(nil, catalog), do: catalog.default_repository

  defp overrides(%{proactive: proactive, shadow: shadow} = overrides)
       when map_size(overrides) == 2 do
    if Enum.all?([proactive, shadow], &override?/1),
      do: :ok,
      else: {:error, {:invalid_channel_configuration, :overrides}}
  end

  defp overrides(_overrides), do: {:error, {:invalid_channel_configuration, :overrides}}

  defp override?(%{source: source, value: value} = override) when map_size(override) == 2,
    do: is_boolean(value) and source in [:channel, :incident_room, :installation]

  defp override?(_override), do: false

  @doc """
  Reserves one Slack channel for a host-owned artifact such as an incident room.

  A join event can race artifact provisioning. Keeping the membership row while
  cancelling its setup draft prevents both a stale setup card from becoming
  actionable and the periodic membership reconciler from opening another one.
  """
  @spec reserve_managed_channel(String.t(), String.t()) :: :ok | {:error, term()}
  def reserve_managed_channel(workspace_ref, channel_ref) do
    with :ok <- reference(workspace_ref, :workspace_ref, 256),
         :ok <- reference(channel_ref, :channel_ref, 256) do
      reserve_managed_transaction(workspace_ref, channel_ref)
    end
  end

  defp reserve_managed_transaction(workspace_ref, channel_ref) do
    case Repo.transaction(fn -> reserve_managed_locked(workspace_ref, channel_ref) end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp reserve_managed_locked(workspace_ref, channel_ref) do
    lock_channel!(workspace_ref, channel_ref)

    Repo.delete_all(
      from(configuration in ChannelConfiguration,
        where:
          configuration.workspace_ref == ^workspace_ref and
            configuration.channel_ref == ^channel_ref
      )
    )

    Repo.update_all(
      from(session in ConfigurationSession,
        where:
          session.workspace_ref == ^workspace_ref and session.channel_ref == ^channel_ref and
            session.status in [:asking, :confirming]
      ),
      set: [status: :cancelled, updated_at: database_now!()]
    )

    :ok
  end

  @spec active_session(String.t(), String.t()) :: ConfigurationSession.t() | nil
  def active_session(workspace_ref, channel_ref) do
    now = database_now!()
    expire_active_sessions!(workspace_ref, channel_ref, now)

    Repo.one(
      from(session in ConfigurationSession,
        where:
          session.workspace_ref == ^workspace_ref and session.channel_ref == ^channel_ref and
            session.status in [:asking, :confirming] and session.expires_at > ^now,
        order_by: [desc: session.inserted_at],
        limit: 1
      )
    )
  end

  defp start_reconfiguration_locked(attributes, catalog) do
    lock_channel!(attributes.workspace_ref, attributes.channel_ref)
    fingerprint = reconfiguration_fingerprint(attributes)

    case Repo.one(
           from(session in ConfigurationSession,
             where: session.start_event_ref == ^attributes.event_ref,
             lock: "FOR UPDATE"
           )
         ) do
      %ConfigurationSession{start_fingerprint: ^fingerprint} = session ->
        %{session: session, status: :duplicate}

      %ConfigurationSession{} ->
        Repo.rollback(:configuration_reconfiguration_conflict)

      nil ->
        start_new_reconfiguration(attributes, catalog, fingerprint)
    end
  end

  defp start_new_reconfiguration(attributes, catalog, fingerprint) do
    membership =
      Repo.one(
        from(membership in ChannelMembership,
          where:
            membership.workspace_ref == ^attributes.workspace_ref and
              membership.channel_ref == ^attributes.channel_ref,
          lock: "FOR UPDATE"
        )
      )

    now = database_now!()
    expire_active_sessions!(attributes.workspace_ref, attributes.channel_ref, now)

    active =
      Repo.one(
        from(session in ConfigurationSession,
          where:
            session.workspace_ref == ^attributes.workspace_ref and
              session.channel_ref == ^attributes.channel_ref and
              session.status in [:asking, :confirming],
          lock: "FOR UPDATE"
        )
      )

    cond do
      not match?(%ChannelMembership{status: :joined}, membership) ->
        Repo.rollback(:configuration_membership_not_joined)

      active ->
        %{session: active, status: :existing}

      true ->
        session =
          insert_session!(
            membership,
            attributes.actor_ref,
            catalog,
            attributes.event_ref,
            fingerprint,
            attributes.thread_ref
          )

        %{session: session, status: :started}
    end
  end

  defp observe_membership_locked(attributes, catalog) do
    lock_channel!(attributes.workspace_ref, attributes.channel_ref)
    fingerprint = membership_fingerprint(attributes)

    case Repo.one(
           from(event in ChannelMembershipEvent,
             where:
               event.workspace_ref == ^attributes.workspace_ref and
                 event.event_ref == ^attributes.event_ref,
             lock: "FOR UPDATE"
           )
         ) do
      %ChannelMembershipEvent{event_fingerprint: ^fingerprint} = event ->
        membership = Repo.get!(ChannelMembership, event.membership_id)

        %{
          configuration: configuration(membership.workspace_ref, membership.channel_ref),
          membership: membership,
          status: :duplicate
        }

      %ChannelMembershipEvent{} ->
        Repo.rollback(:channel_membership_event_conflict)

      nil ->
        transition_membership(attributes, catalog, fingerprint)
    end
  end

  defp reconcile_joined_channel(
         workspace_ref,
         %{channel_ref: channel_ref, private: private} = channel,
         catalog
       ) do
    external_shared = Map.get(channel, :external_shared)

    Repo.transaction(fn ->
      lock_channel!(workspace_ref, channel_ref)

      membership =
        Repo.one(
          from(membership in ChannelMembership,
            where:
              membership.workspace_ref == ^workspace_ref and
                membership.channel_ref == ^channel_ref,
            lock: "FOR UPDATE"
          )
        )

      reconcile_joined_membership(
        membership,
        workspace_ref,
        channel_ref,
        private,
        external_shared,
        catalog
      )
    end)
    |> transaction_result()
  end

  defp reconcile_joined_membership(
         %ChannelMembership{status: :joined} = membership,
         _workspace_ref,
         _channel_ref,
         private,
         external_shared,
         catalog
       ) do
    membership =
      if membership.private == private and membership.external_shared == external_shared do
        membership
      else
        membership
        |> ChannelConfigurationChangeset.membership(%{
          external_shared: external_shared,
          private: private
        })
        |> Repo.update!()
      end

    %{
      configuration: ensure_configuration!(membership, catalog),
      membership: membership,
      status: :unchanged
    }
  end

  defp reconcile_joined_membership(
         membership,
         workspace_ref,
         channel_ref,
         private,
         external_shared,
         catalog
       ) do
    generation = if membership, do: membership.generation + 1, else: 1
    now = database_now!()

    attributes = %{
      actor_ref: nil,
      channel_ref: channel_ref,
      external_shared: external_shared,
      event_ref: "slack-reconcile:#{workspace_ref}:#{channel_ref}:#{generation}",
      kind: :joined,
      occurred_at: now,
      private: private,
      workspace_ref: workspace_ref
    }

    transition_membership(attributes, catalog, membership_fingerprint(attributes))
  end

  defp transition_membership(attributes, catalog, fingerprint) do
    membership =
      Repo.one(
        from(membership in ChannelMembership,
          where:
            membership.workspace_ref == ^attributes.workspace_ref and
              membership.channel_ref == ^attributes.channel_ref,
          lock: "FOR UPDATE"
        )
      )

    {membership, configuration, status} =
      case {membership, attributes.kind} do
        {nil, :joined} ->
          membership = insert_membership!(attributes, :joined, 1)
          {membership, join_configuration!(membership, catalog), :joined}

        {nil, :left} ->
          {insert_membership!(attributes, :left, 1), nil, :left}

        {nil, :deleted} ->
          membership = insert_membership!(attributes, :deleted, 1)
          delete_channel_state!(membership)
          {membership, nil, :deleted}

        {%ChannelMembership{status: :joined} = membership, :joined} ->
          {membership, ensure_configuration!(membership, catalog), :unchanged}

        {%ChannelMembership{} = membership, :joined} ->
          membership =
            rejoin_membership!(
              membership,
              attributes.occurred_at,
              Map.get(attributes, :private),
              Map.get(attributes, :external_shared)
            )

          {membership, join_configuration!(membership, catalog), :joined}

        {%ChannelMembership{} = membership, :left} ->
          cancel_active_sessions!(membership, :cancelled)
          {leave_membership!(membership, attributes.occurred_at), nil, :left}

        {%ChannelMembership{} = membership, :deleted} ->
          delete_channel_state!(membership)
          {delete_membership!(membership, attributes.occurred_at), nil, :deleted}
      end

    insert_membership_event!(membership, attributes, fingerprint)
    %{configuration: configuration, membership: membership, status: status}
  end

  # A join keeps any configuration the channel saved before it left, but its
  # welcome is a new message: the old one, if still visible, is stale.
  defp join_configuration!(membership, catalog) do
    case ensure_configuration!(membership, catalog) do
      %ChannelConfiguration{welcome_message_ref: nil} = configuration ->
        configuration

      %ChannelConfiguration{} = configuration ->
        configuration
        |> ChannelConfigurationChangeset.configuration(%{welcome_message_ref: nil})
        |> Repo.update!()
    end
  end

  defp ensure_configuration!(membership, catalog) do
    case Repo.one(
           from(configuration in ChannelConfiguration,
             where:
               configuration.workspace_ref == ^membership.workspace_ref and
                 configuration.channel_ref == ^membership.channel_ref,
             lock: "FOR UPDATE"
           )
         ) do
      %ChannelConfiguration{} = configuration ->
        configuration

      nil ->
        %{
          actor_ref: nil,
          alert_policy: :reply,
          channel_ref: membership.channel_ref,
          id: Ecto.UUID.generate(),
          invite_user_group_refs: [],
          invite_user_refs: [],
          # No explicit choice yet: the channel inherits the installation default.
          participation: nil,
          repository_ref: catalog.default_repository,
          revision: 1,
          saved_at: database_now!(),
          welcome_message_ref: nil,
          workspace_ref: membership.workspace_ref
        }
        |> ChannelConfigurationChangeset.configuration()
        |> Repo.insert!()
    end
  end

  defp insert_membership!(attributes, status, generation) do
    timestamps = membership_timestamps(status, attributes.occurred_at)

    attributes
    |> Map.take([:channel_ref, :external_shared, :private, :workspace_ref])
    |> Map.merge(timestamps)
    |> Map.merge(%{generation: generation, id: Ecto.UUID.generate(), status: status})
    |> ChannelConfigurationChangeset.membership()
    |> Repo.insert!()
  end

  defp rejoin_membership!(membership, occurred_at, private, external_shared) do
    membership
    |> ChannelConfigurationChangeset.membership(%{
      deleted_at: nil,
      external_shared: external_shared,
      generation: membership.generation + 1,
      joined_at: occurred_at,
      left_at: nil,
      private: private,
      status: :joined
    })
    |> Repo.update!()
  end

  defp leave_membership!(membership, occurred_at) do
    membership
    |> ChannelConfigurationChangeset.membership(%{
      deleted_at: nil,
      joined_at: membership.joined_at || occurred_at,
      left_at: occurred_at,
      status: :left
    })
    |> Repo.update!()
  end

  defp delete_membership!(membership, occurred_at) do
    membership
    |> ChannelConfigurationChangeset.membership(%{
      deleted_at: occurred_at,
      joined_at: membership.joined_at,
      left_at: membership.left_at,
      status: :deleted
    })
    |> Repo.update!()
  end

  defp membership_timestamps(:joined, occurred_at),
    do: %{deleted_at: nil, joined_at: occurred_at, left_at: nil}

  defp membership_timestamps(:left, occurred_at),
    do: %{deleted_at: nil, joined_at: occurred_at, left_at: occurred_at}

  defp membership_timestamps(:deleted, occurred_at),
    do: %{deleted_at: occurred_at, joined_at: nil, left_at: nil}

  defp insert_session!(
         membership,
         initiator_ref,
         catalog,
         start_event_ref,
         start_fingerprint,
         thread_ref
       ) do
    now = database_now!()

    %{
      channel_ref: membership.channel_ref,
      draft: empty_draft(catalog),
      expires_at: DateTime.add(now, @session_seconds, :second),
      id: Ecto.UUID.generate(),
      initiator_ref: initiator_ref,
      membership_generation: membership.generation,
      response_thread_ref: thread_ref,
      revision: 1,
      root_message_ref: thread_ref,
      start_event_ref: start_event_ref,
      start_fingerprint: start_fingerprint,
      status: :asking,
      step: :participation,
      workspace_ref: membership.workspace_ref
    }
    |> ChannelConfigurationChangeset.session()
    |> Repo.insert!()
  end

  defp insert_membership_event!(membership, attributes, fingerprint) do
    attributes
    |> Map.take([:actor_ref, :channel_ref, :event_ref, :kind, :occurred_at, :workspace_ref])
    |> Map.merge(%{
      event_fingerprint: fingerprint,
      id: Ecto.UUID.generate(),
      membership_id: membership.id
    })
    |> ChannelConfigurationChangeset.membership_event()
    |> Repo.insert!()
  end

  defp cancel_active_sessions!(membership, status) do
    Repo.update_all(
      from(session in ConfigurationSession,
        where:
          session.workspace_ref == ^membership.workspace_ref and
            session.channel_ref == ^membership.channel_ref and
            session.status in [:asking, :confirming]
      ),
      set: [status: status, updated_at: database_now!()]
    )

    :ok
  end

  defp expire_active_sessions!(workspace_ref, channel_ref, now) do
    Repo.update_all(
      from(session in ConfigurationSession,
        where:
          session.workspace_ref == ^workspace_ref and session.channel_ref == ^channel_ref and
            session.status in [:asking, :confirming] and session.expires_at <= ^now
      ),
      set: [status: :expired, updated_at: now]
    )

    :ok
  end

  defp delete_channel_state!(membership) do
    :ok =
      Memories.delete_slack_channel_in_transaction(
        membership.workspace_ref,
        membership.channel_ref
      )

    :ok =
      Continuity.delete_slack_channel_in_transaction(
        membership.workspace_ref,
        membership.channel_ref
      )

    Repo.delete_all(
      from(configuration in ChannelConfiguration,
        where:
          configuration.workspace_ref == ^membership.workspace_ref and
            configuration.channel_ref == ^membership.channel_ref
      )
    )

    Repo.delete_all(
      from(session in ConfigurationSession,
        where:
          session.workspace_ref == ^membership.workspace_ref and
            session.channel_ref == ^membership.channel_ref
      )
    )

    :ok
  end

  defp bind_prompt_locked(session_ref, revision, message_ref, thread_ref) do
    case Repo.one(
           from(session in ConfigurationSession,
             where: session.id == ^session_ref,
             lock: "FOR UPDATE"
           )
         ) do
      nil ->
        Repo.rollback(:configuration_session_not_found)

      %ConfigurationSession{revision: stored} when stored != revision ->
        Repo.rollback(:configuration_revision_stale)

      %ConfigurationSession{current_message_ref: current}
      when not is_nil(current) and current != message_ref ->
        Repo.rollback(:configuration_prompt_already_bound)

      %ConfigurationSession{} = session ->
        root_message_ref = session.root_message_ref || message_ref

        session
        |> ChannelConfigurationChangeset.session(%{
          current_message_ref: message_ref,
          response_thread_ref: thread_ref,
          root_message_ref: root_message_ref
        })
        |> Repo.update!()
    end
  end

  defp apply_action_locked(attributes) do
    fingerprint = action_fingerprint(attributes)

    case Repo.one(
           from(action in ConfigurationAction,
             where: action.event_ref == ^attributes.event_ref,
             lock: "FOR UPDATE"
           )
         ) do
      %ConfigurationAction{event_fingerprint: ^fingerprint} = action ->
        %{session: Repo.get!(ConfigurationSession, action.session_id), status: :duplicate}

      %ConfigurationAction{} ->
        Repo.rollback(:configuration_action_event_conflict)

      nil ->
        apply_new_action(attributes, fingerprint)
    end
  end

  defp apply_new_action(attributes, fingerprint) do
    lock_channel!(attributes.workspace_ref, attributes.channel_ref)

    session =
      Repo.one(
        from(session in ConfigurationSession,
          where: session.id == ^attributes.session_ref,
          lock: "FOR UPDATE"
        )
      )

    case action_identity(session, attributes) do
      :ok -> apply_action_for_session(session, attributes, fingerprint)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp apply_action_for_session(session, attributes, fingerprint) do
    membership =
      Repo.one(
        from(membership in ChannelMembership,
          where:
            membership.workspace_ref == ^attributes.workspace_ref and
              membership.channel_ref == ^attributes.channel_ref,
          lock: "FOR UPDATE"
        )
      )

    with :ok <- live_membership(membership, session),
         :ok <- action_scope(session, attributes),
         :ok <- not_expired(session),
         {:ok, transition} <- transition(session, attributes),
         {:ok, updated_session, outcome} <- persist_transition(session, attributes, transition) do
      insert_action!(updated_session, attributes, fingerprint, outcome)
      %{session: updated_session, status: outcome}
    else
      {:error, :configuration_expired} ->
        expire_session!(session)
        {:configuration_error, :configuration_expired}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp action_identity(nil, _attributes), do: {:error, :configuration_session_not_found}

  defp action_identity(session, attributes) do
    cond do
      session.workspace_ref != attributes.workspace_ref ->
        {:error, :configuration_workspace_mismatch}

      session.channel_ref != attributes.channel_ref ->
        {:error, :configuration_channel_mismatch}

      true ->
        :ok
    end
  end

  defp live_membership(
         %ChannelMembership{generation: generation, status: :joined},
         %ConfigurationSession{membership_generation: generation}
       ),
       do: :ok

  defp live_membership(nil, _session), do: {:error, :configuration_membership_not_found}
  defp live_membership(_membership, nil), do: {:error, :configuration_session_not_found}
  defp live_membership(_membership, _session), do: {:error, :configuration_membership_stale}

  defp action_scope(session, attributes) do
    with :ok <- active_session_status(session),
         :ok <- exact_session_actor(session, attributes.actor_ref) do
      action_source_scope(session, attributes)
    end
  end

  defp active_session_status(%ConfigurationSession{status: status})
       when status in [:asking, :confirming],
       do: :ok

  defp active_session_status(_session), do: {:error, :configuration_session_terminal}

  defp exact_session_actor(%ConfigurationSession{initiator_ref: nil}, _actor_ref), do: :ok
  defp exact_session_actor(%ConfigurationSession{initiator_ref: actor_ref}, actor_ref), do: :ok
  defp exact_session_actor(_session, _actor_ref), do: {:error, :configuration_actor_mismatch}

  defp action_source_scope(session, %{source: :control} = attributes) do
    cond do
      session.current_message_ref != attributes.message_ref ->
        {:error, :configuration_message_mismatch}

      session.response_thread_ref != attributes.thread_ref ->
        {:error, :configuration_thread_mismatch}

      true ->
        :ok
    end
  end

  defp action_source_scope(session, %{source: :message} = attributes) do
    if setup_message_location?(session, attributes),
      do: :ok,
      else: {:error, :configuration_thread_mismatch}
  end

  defp setup_message_location?(_session, %{thread_ref: nil}), do: true

  defp setup_message_location?(%ConfigurationSession{root_message_ref: root}, %{
         thread_ref: root
       })
       when is_binary(root),
       do: true

  defp setup_message_location?(_session, _attributes), do: false

  defp not_expired(session) do
    if DateTime.compare(session.expires_at, database_now!()) == :gt,
      do: :ok,
      else: {:error, :configuration_expired}
  end

  defp transition(%ConfigurationSession{step: :participation}, %{
         action: :participation,
         value: value
       })
       when value in @participation,
       do: {:ok, {:draft, "participation", Atom.to_string(value), :repository}}

  defp transition(%ConfigurationSession{step: :repository, draft: draft}, %{
         action: :repository,
         value: repository_ref
       })
       when is_binary(repository_ref) do
    if repository_ref in draft["repository_options"],
      do: {:ok, {:draft, "repository_ref", repository_ref, :alerts}},
      else: {:error, :configuration_repository_not_offered}
  end

  defp transition(%ConfigurationSession{step: :alerts}, %{action: :alerts, value: value})
       when value in @alerts,
       do: {:ok, {:draft, "alert_policy", Atom.to_string(value), :audience}}

  defp transition(%ConfigurationSession{step: :audience}, %{
         action: :audience,
         value: value
       }) do
    with {:ok, audience} <- audience(value) do
      {:ok, {:audience, audience}}
    end
  end

  defp transition(%ConfigurationSession{status: :confirming}, %{action: :save, value: nil}),
    do: {:ok, :save}

  defp transition(%ConfigurationSession{}, %{action: :restart, value: nil}),
    do: {:ok, :restart}

  defp transition(%ConfigurationSession{}, %{action: :cancel, value: nil}),
    do: {:ok, :cancel}

  defp transition(_session, _attributes), do: {:error, :configuration_action_mismatch}

  defp persist_transition(session, attributes, :save),
    do: save_session(session, attributes, session.draft)

  defp persist_transition(session, attributes, {:draft, key, value, next_step}) do
    update_session(
      session,
      attributes,
      %{draft: Map.put(session.draft, key, value), step: next_step},
      :advanced
    )
  end

  defp persist_transition(session, attributes, {:audience, audience}) do
    draft =
      session.draft
      |> Map.put("invite_user_refs", audience.user_refs)
      |> Map.put("invite_user_group_refs", audience.user_group_refs)

    update_session(
      session,
      attributes,
      %{draft: draft, status: :confirming, step: :confirm},
      :advanced
    )
  end

  defp persist_transition(session, attributes, :restart) do
    catalog = %{
      default_repository: session.draft["default_repository"],
      repository_refs: session.draft["repository_options"]
    }

    update_session(
      session,
      attributes,
      %{draft: empty_draft(catalog), status: :asking, step: :participation},
      :restarted
    )
  end

  defp persist_transition(session, attributes, :cancel) do
    update_session(session, attributes, %{status: :cancelled}, :cancelled)
  end

  defp save_session(session, attributes, draft) do
    with :ok <- complete_draft(draft) do
      save_configuration!(session, attributes.actor_ref, draft)

      update_session(
        session,
        attributes,
        %{draft: draft, status: :saved},
        :saved
      )
    end
  end

  # The wizard message is updated in place after every step, so the session
  # keeps its bound message across revisions instead of posting a new card.
  defp update_session(session, attributes, changes, outcome) do
    changes =
      changes
      |> Map.put(:initiator_ref, session.initiator_ref || attributes.actor_ref)
      |> Map.put(:revision, session.revision + 1)

    updated =
      session
      |> ChannelConfigurationChangeset.session(changes)
      |> Repo.update!()

    {:ok, updated, outcome}
  end

  defp save_configuration!(session, actor_ref, draft) do
    now = database_now!()

    existing =
      Repo.one(
        from(configuration in ChannelConfiguration,
          where:
            configuration.workspace_ref == ^session.workspace_ref and
              configuration.channel_ref == ^session.channel_ref,
          lock: "FOR UPDATE"
        )
      )

    attributes = %{
      actor_ref: actor_ref,
      alert_policy: String.to_existing_atom(draft["alert_policy"]),
      invite_user_group_refs: draft["invite_user_group_refs"],
      invite_user_refs: draft["invite_user_refs"],
      participation: String.to_existing_atom(draft["participation"]),
      repository_ref: draft["repository_ref"],
      revision: if(existing, do: existing.revision + 1, else: 1),
      saved_at: now
    }

    case existing do
      %ChannelConfiguration{} = configuration ->
        configuration
        |> ChannelConfigurationChangeset.configuration(attributes)
        |> Repo.update!()

      nil ->
        attributes
        |> Map.merge(%{
          channel_ref: session.channel_ref,
          id: Ecto.UUID.generate(),
          welcome_message_ref: nil,
          workspace_ref: session.workspace_ref
        })
        |> ChannelConfigurationChangeset.configuration()
        |> Repo.insert!()
    end
  end

  defp change_participation_locked(attributes) do
    lock_channel!(attributes.workspace_ref, attributes.channel_ref)

    membership =
      Repo.one(
        from(membership in ChannelMembership,
          where:
            membership.workspace_ref == ^attributes.workspace_ref and
              membership.channel_ref == ^attributes.channel_ref,
          lock: "FOR UPDATE"
        )
      )

    configuration =
      Repo.one(
        from(configuration in ChannelConfiguration,
          where:
            configuration.workspace_ref == ^attributes.workspace_ref and
              configuration.channel_ref == ^attributes.channel_ref,
          lock: "FOR UPDATE"
        )
      )

    cond do
      not match?(%ChannelMembership{status: :joined}, membership) ->
        Repo.rollback(:configuration_membership_not_joined)

      is_nil(configuration) ->
        Repo.rollback(:configuration_not_found)

      configuration.id != attributes.configuration_ref ->
        Repo.rollback(:configuration_not_found)

      configuration.revision != attributes.expected_revision ->
        Repo.rollback(:configuration_revision_stale)

      configuration.participation == attributes.participation ->
        %{configuration: configuration, status: :unchanged}

      true ->
        saved =
          configuration
          |> ChannelConfigurationChangeset.configuration(%{
            actor_ref: attributes.actor_ref,
            participation: attributes.participation,
            revision: configuration.revision + 1,
            saved_at: database_now!()
          })
          |> Repo.update!()

        %{configuration: saved, status: :saved}
    end
  end

  defp bind_welcome_locked(workspace_ref, channel_ref, message_ref) do
    case Repo.one(
           from(configuration in ChannelConfiguration,
             where:
               configuration.workspace_ref == ^workspace_ref and
                 configuration.channel_ref == ^channel_ref,
             lock: "FOR UPDATE"
           )
         ) do
      nil ->
        Repo.rollback(:configuration_not_found)

      %ChannelConfiguration{welcome_message_ref: ^message_ref} = configuration ->
        configuration

      %ChannelConfiguration{welcome_message_ref: nil} = configuration ->
        configuration
        |> ChannelConfigurationChangeset.configuration(%{welcome_message_ref: message_ref})
        |> Repo.update!()

      %ChannelConfiguration{} ->
        Repo.rollback(:configuration_welcome_already_bound)
    end
  end

  defp insert_action!(session, attributes, fingerprint, outcome) do
    %{
      action: Atom.to_string(attributes.action),
      actor_ref: attributes.actor_ref,
      event_fingerprint: fingerprint,
      event_ref: attributes.event_ref,
      id: Ecto.UUID.generate(),
      outcome: Atom.to_string(outcome),
      session_id: session.id,
      session_revision: session.revision
    }
    |> ChannelConfigurationChangeset.action()
    |> Repo.insert!()
  end

  defp expire_session!(nil), do: :ok

  defp expire_session!(session) do
    session
    |> ChannelConfigurationChangeset.session(%{status: :expired})
    |> Repo.update!()

    :ok
  end

  defp complete_draft(draft) do
    valid =
      draft["participation"] in Enum.map(@participation, &Atom.to_string/1) and
        draft["alert_policy"] in Enum.map(@alerts, &Atom.to_string/1) and
        draft["repository_ref"] in draft["repository_options"] and
        is_list(draft["invite_user_refs"]) and is_list(draft["invite_user_group_refs"])

    if valid, do: :ok, else: {:error, :configuration_draft_incomplete}
  end

  defp empty_draft(catalog) do
    %{
      "alert_policy" => nil,
      "default_repository" => catalog.default_repository,
      "invite_user_group_refs" => [],
      "invite_user_refs" => [],
      "participation" => nil,
      "repository_options" => catalog.repository_refs,
      "repository_ref" => nil
    }
  end

  defp audience(:none), do: {:ok, %{user_group_refs: [], user_refs: []}}

  defp audience(%{user_group_refs: groups, user_refs: users} = audience)
       when map_size(audience) == 2 do
    with :ok <- references(users, :invite_user_refs),
         :ok <- references(groups, :invite_user_group_refs) do
      {:ok, %{user_group_refs: Enum.sort(groups), user_refs: Enum.sort(users)}}
    end
  end

  defp audience(_value), do: {:error, :configuration_audience_invalid}

  defp membership_attributes(attributes) do
    with :ok <- member(attributes.kind, @membership_kinds, :kind),
         :ok <- reference(attributes.workspace_ref, :workspace_ref, 256),
         :ok <- reference(attributes.channel_ref, :channel_ref, 256),
         :ok <- reference(attributes.event_ref, :event_ref, 512),
         :ok <- optional_reference(attributes.actor_ref, :actor_ref) do
      utc(attributes.occurred_at, :occurred_at)
    end
  end

  defp reconfiguration_attributes(attributes) do
    with :ok <- reference(attributes.actor_ref, :actor_ref, 256),
         :ok <- reference(attributes.workspace_ref, :workspace_ref, 256),
         :ok <- reference(attributes.channel_ref, :channel_ref, 256),
         :ok <- reference(attributes.event_ref, :event_ref, 512),
         :ok <- optional_reference(attributes.thread_ref, :thread_ref) do
      utc(attributes.occurred_at, :occurred_at)
    end
  end

  defp action_attributes(attributes) do
    with :ok <- member(attributes.source, [:control, :message], :source),
         :ok <- reference(attributes.workspace_ref, :workspace_ref, 256),
         :ok <- reference(attributes.channel_ref, :channel_ref, 256),
         :ok <- reference(attributes.actor_ref, :actor_ref, 256),
         :ok <- reference(attributes.event_ref, :event_ref, 512),
         :ok <- reference(attributes.message_ref, :message_ref, 256),
         :ok <- optional_reference(attributes.thread_ref, :thread_ref),
         :ok <- uuid(attributes.session_ref, :session_ref),
         :ok <- utc(attributes.occurred_at, :occurred_at) do
      action_name(attributes.action)
    end
  end

  defp action_name(value)
       when value in [:alerts, :audience, :cancel, :participation, :repository, :restart, :save],
       do: :ok

  defp action_name(_value), do: {:error, {:invalid_channel_configuration, :action}}

  defp participation_change_attributes(attributes) do
    with :ok <- reference(attributes.actor_ref, :actor_ref, 256),
         :ok <- reference(attributes.workspace_ref, :workspace_ref, 256),
         :ok <- reference(attributes.channel_ref, :channel_ref, 256),
         :ok <- reference(attributes.event_ref, :event_ref, 512),
         :ok <- uuid(attributes.configuration_ref, :configuration_ref),
         :ok <- positive(attributes.expected_revision, :expected_revision),
         :ok <- member(attributes.participation, @participation, :participation) do
      utc(attributes.occurred_at, :occurred_at)
    end
  end

  defp catalog(%{default_repository: default, repository_refs: refs} = catalog)
       when map_size(catalog) in 2..4 do
    on_call_count = Map.get(catalog, :on_call_count, 0)
    urls = Map.get(catalog, :repository_urls, %{})

    with :ok <- reference(default, :default_repository, 256),
         :ok <- references(refs, :repository_refs),
         true <- default in refs,
         true <-
           Map.keys(catalog) --
             [:default_repository, :on_call_count, :repository_refs, :repository_urls] == [],
         true <- is_integer(on_call_count) and on_call_count >= 0,
         :ok <- repository_urls(urls, refs) do
      {:ok,
       %{
         default_repository: default,
         on_call_count: on_call_count,
         repository_refs: Enum.sort(refs),
         repository_urls: urls
       }}
    else
      false -> {:error, {:invalid_channel_configuration, :catalog}}
      {:error, _reason} = error -> error
    end
  end

  defp catalog(_catalog), do: {:error, {:invalid_channel_configuration, :catalog}}

  defp repository_urls(urls, refs) when is_map(urls) do
    valid =
      Enum.all?(urls, fn
        {repository_ref, "https://" <> _rest = url} ->
          repository_ref in refs and reference(url, :repository_urls, 2_048) == :ok

        _entry ->
          false
      end)

    if valid, do: :ok, else: {:error, {:invalid_channel_configuration, :repository_urls}}
  end

  defp repository_urls(_urls, _refs),
    do: {:error, {:invalid_channel_configuration, :repository_urls}}

  defp exact_map(attributes, fields, boundary) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes),
       do: attributes |> Map.new() |> exact_map(fields, boundary),
       else: {:error, {:invalid_channel_configuration, boundary}}
  end

  defp exact_map(%{} = attributes, fields, boundary) do
    if Map.keys(attributes) |> Enum.sort() == Enum.sort(fields),
      do: {:ok, attributes},
      else: {:error, {:invalid_channel_configuration, boundary}}
  end

  defp exact_map(_attributes, _fields, boundary),
    do: {:error, {:invalid_channel_configuration, boundary}}

  defp references(values, field) when is_list(values) and values != [] do
    if Enum.uniq(values) == values and Enum.all?(values, &(reference(&1, field, 256) == :ok)),
      do: :ok,
      else: {:error, {:invalid_channel_configuration, field}}
  end

  defp references([], _field), do: :ok
  defp references(_values, field), do: {:error, {:invalid_channel_configuration, field}}

  defp bounded_channels(values) when is_list(values) and length(values) <= 10_000 do
    refs =
      Enum.map(values, fn
        %{channel_ref: ref, private: private} = channel
        when is_boolean(private) ->
          if is_boolean(Map.get(channel, :external_shared)) or
               is_nil(Map.get(channel, :external_shared)),
             do: ref,
             else: nil

        _invalid ->
          nil
      end)

    if Enum.uniq(refs) == refs and
         Enum.all?(refs, &(reference(&1, :channel_ref, 256) == :ok)),
       do: :ok,
       else: {:error, {:invalid_channel_configuration, :channel_refs}}
  end

  defp bounded_channels(_values),
    do: {:error, {:invalid_channel_configuration, :channel_refs}}

  defp member(value, values, field) do
    if value in values,
      do: :ok,
      else: {:error, {:invalid_channel_configuration, field}}
  end

  defp positive(value, _field) when is_integer(value) and value > 0, do: :ok
  defp positive(_value, field), do: {:error, {:invalid_channel_configuration, field}}

  defp uuid(value, field) do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> :ok
      :error -> {:error, {:invalid_channel_configuration, field}}
    end
  end

  defp optional_reference(nil, _field), do: :ok
  defp optional_reference(value, field), do: reference(value, field)

  defp reference(value, field, maximum \\ 1_024) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
         String.trim(value) != "" and :binary.match(value, <<0>>) == :nomatch,
       do: :ok,
       else: {:error, {:invalid_channel_configuration, field}}
  end

  defp utc(%DateTime{} = value, _field) do
    if value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0,
      do: :ok,
      else: {:error, {:invalid_channel_configuration, :occurred_at}}
  end

  defp utc(_value, field), do: {:error, {:invalid_channel_configuration, field}}

  defp membership_fingerprint(attributes) do
    attributes
    |> Map.update!(:kind, &Atom.to_string/1)
    |> Map.update!(:occurred_at, &DateTime.to_iso8601/1)
    |> json_document()
    |> fingerprint()
  end

  defp reconfiguration_fingerprint(attributes) do
    attributes
    |> Map.update!(:occurred_at, &DateTime.to_iso8601/1)
    |> json_document()
    |> fingerprint()
  end

  defp action_fingerprint(attributes) do
    attributes
    |> Map.update!(:action, &Atom.to_string/1)
    |> Map.update!(:source, &Atom.to_string/1)
    |> Map.update!(:occurred_at, &DateTime.to_iso8601/1)
    |> Map.update!(:value, &json_value/1)
    |> json_document()
    |> fingerprint()
  end

  defp json_value(value) when is_atom(value), do: Atom.to_string(value)

  defp json_value(%{} = value), do: json_document(value)

  defp json_value(value), do: value

  defp json_document(document) do
    Map.new(document, fn {key, value} ->
      value = if is_atom(value), do: Atom.to_string(value), else: value
      {to_string(key), value}
    end)
  end

  defp fingerprint(document), do: CanonicalJSON.digest(document)

  defp lock_channel!(workspace_ref, channel_ref) do
    case ChannelFence.lock_in_transaction(workspace_ref, channel_ref) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp database_now! do
    case Repo.query!("SELECT clock_timestamp()") do
      %{rows: [[%DateTime{} = now]]} -> now
    end
  end

  defp transaction_result({:ok, {:configuration_error, reason}}), do: {:error, reason}
  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}
end
