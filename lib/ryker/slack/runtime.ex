defmodule Ryker.Slack.Runtime do
  @moduledoc """
  Builds one trusted Slack Socket Mode gateway.

  Tokens and policy bindings are prepared by host configuration. Slack payloads
  can supply content and opaque platform IDs, but cannot select repositories,
  Coop policy digests, operators, or delivery authority.
  """

  alias Ryker.Artifacts
  alias Ryker.Delivery.{BinaryClient, JSONClient}
  alias Ryker.Episodes.Reactions
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.WorkProfile
  alias Ryker.Publication.{Custody, Followups}

  alias Ryker.Slack.{
    ActionTokens,
    AppHome,
    AppHomeActions,
    AppHomeControls,
    AppHomeEditor,
    AppHomeProjection,
    AttachmentIngestor,
    ChannelConfigurations,
    ChannelSettings,
    ChannelSetup,
    Client,
    CommandHandler,
    Engagement,
    FileClient,
    Gateway,
    IncidentRooms,
    IncidentRoomWorker,
    InteractionAudits,
    InteractionFeedbackWorker,
    InteractionHandler,
    InteractionRepaint,
    MembershipReconciler,
    Mentions,
    MintSocketTransport,
    Publisher,
    TaskCardWorker,
    ThreadStatusProjection,
    ThreadStatusWorker,
    WorkControls
  }

  alias Ryker.Slack.Supervisor, as: SlackSupervisor

  alias Ryker.State.{
    Automations,
    Behaviors,
    InputRequests,
    Memories,
    Records,
    ScheduleRuntime,
    Schedules,
    SlackPostOffers,
    TaskOffers
  }

  @fields [
    :app_http,
    :bot_client,
    :channel_prefix,
    :default_repository,
    :handshake_timeout_ms,
    :identity,
    :incident_policy,
    :incident_private,
    :incident_room_interval_ms,
    :incident_room_reconcile_ms,
    :maximum_open_incidents,
    :membership_reconcile_ms,
    :operators,
    :receive_timeout_ms,
    :reconnect_ms,
    :repositories,
    :schedule_policies,
    :task_card_interval_ms,
    :task_card_reconcile_ms,
    :default_participation,
    :thread_status_interval_ms
  ]
  @required_fields [
    :app_http,
    :bot_client,
    :default_repository,
    :identity,
    :incident_policy,
    :operators,
    :repositories
  ]

  @spec child_spec(keyword() | map()) :: Supervisor.child_spec()
  def child_spec(configuration) do
    options = supervisor_options!(configuration)

    %{
      id: __MODULE__,
      start: {SlackSupervisor, :start_link, [options]},
      type: :supervisor
    }
  end

  @doc false
  @spec options!(keyword() | map()) :: map()
  def options!(configuration), do: supervisor_options!(configuration).gateway

  @doc """
  Builds the trusted Delivery registry entry for the same Slack runtime.

  The host-owned incident-room state check is part of the binding, so a
  configured Delivery pool cannot accidentally post into an archived,
  deleted, or unavailable managed room.
  """
  @spec delivery_adapter!(keyword() | map()) :: map()
  def delivery_adapter!(configuration) do
    gateway = supervisor_options!(configuration).gateway
    settings = gateway.handler_settings
    workspace_ref = settings.identity.workspace_ref

    %{
      binding: %{
        destination_allowed: &IncidentRooms.delivery_allowed/2,
        mention_authority: &Mentions.authority_for_delivery/1,
        workspaces: %{
          workspace_ref => %{api: Client, client: settings.client}
        }
      },
      message_publisher: Publisher,
      reaction_publisher: Publisher
    }
  end

  defp supervisor_options!(configuration) do
    configuration = normalize_configuration!(configuration)
    app_http = Map.fetch!(configuration, :app_http)
    bot_client = Map.fetch!(configuration, :bot_client)
    default_repository = Map.fetch!(configuration, :default_repository)
    identity = Map.fetch!(configuration, :identity)
    incident_policy = Map.fetch!(configuration, :incident_policy)
    repositories = Map.fetch!(configuration, :repositories)
    operators = configuration |> Map.fetch!(:operators) |> references!(:operators)

    default_participation =
      participation!(Map.get(configuration, :default_participation, :mentions))

    channel_prefix = configuration |> Map.get(:channel_prefix, "ems") |> channel_prefix!()

    # An incident room invites the operators, who are the people authorized to
    # act on it, plus whoever the channel named in its own setup thread. There
    # is no third list to keep in a configuration file.
    incident_invite_users = operators |> MapSet.to_list() |> Enum.sort()

    incident_private =
      configuration |> Map.get(:incident_private, true) |> boolean!(:incident_private)

    maximum_open_incidents =
      configuration
      |> Map.get(:maximum_open_incidents, 25)
      |> bounded_integer!(:maximum_open_incidents, 1..1_000)

    unless match?(%JSONClient{}, app_http),
      do: raise(ArgumentError, "Slack app_http must be a prepared JSONClient")

    unless match?(%Client{}, bot_client),
      do: raise(ArgumentError, "Slack bot_client must be a prepared Slack Client")

    validate_identity!(identity)
    incident_policy = policy!(incident_policy, :incident_policy)
    repositories = repositories!(repositories)
    default_repository = default_repository!(default_repository, repositories)
    file_client = file_client!(bot_client)
    schedule_policy_resolver = schedule_policy_resolver(configuration)

    work_record_options = %{slack_api: Client, slack_client: bot_client}

    home_options = %{
      api: Client,
      client: bot_client,
      collection: &AppHomeProjection.collection/4,
      directory: Client,
      operators: operators,
      projection: &AppHomeProjection.snapshot/3,
      shared_conversations: &Client.shared_conversations/3
    }

    home_interaction_options = %{
      authorize_resource: &AppHomeActions.authorize_resource(&1, Client, bot_client),
      client: bot_client,
      directory: Client,
      discard_workspace: &AppHomeActions.discard_workspace/5,
      forget_memory: fn ref, actor_ref, workspace_ref ->
        Memories.forget_home(ref, "slack:user:#{actor_ref}", "slack:#{workspace_ref}")
      end,
      open_memory_review_editor: fn ref, trigger_ref, actor_ref, workspace_ref ->
        AppHomeEditor.open_memory_review(
          Client,
          bot_client,
          ref,
          trigger_ref,
          "slack:user:#{actor_ref}",
          workspace_ref
        )
      end,
      operators: operators,
      recover_publication: &AppHomeActions.recover_publication/6,
      refresh_home: &AppHome.handle(&1, home_options),
      resolve_memory_review: fn ref, action, actor_ref, workspace_ref, replacement ->
        Memories.resolve_home_review(
          ref,
          action,
          "slack:user:#{actor_ref}",
          workspace_ref,
          replacement
        )
      end,
      run_schedule: fn ref, actor_ref, workspace_ref, action_ref ->
        Schedules.run_now(
          ref,
          "slack:user:#{actor_ref}",
          action_ref,
          %{conversation_prefix: "slack:#{workspace_ref}:", transport: "slack"},
          schedule_policy_resolver
        )
      end,
      set_behavior_status: fn ref, status, revision, actor_ref, workspace_ref, action_ref ->
        Behaviors.set_home_status(
          ref,
          status,
          revision,
          "slack:user:#{actor_ref}",
          "slack:#{workspace_ref}",
          action_ref
        )
      end,
      set_schedule_status: fn ref, status, revision, actor_ref, workspace_ref, action_ref ->
        Schedules.set_home_status(
          ref,
          status,
          revision,
          "slack:user:#{actor_ref}",
          action_ref,
          %{
            conversation_prefix: "slack:#{workspace_ref}:",
            transport: "slack"
          }
        )
      end,
      show_collection: &AppHome.publish_collection(&1, &2, &3, home_options)
    }

    request_incident_room = fn attributes ->
      attributes
      |> Map.merge(%{
        bot_user_ref: identity.bot_user_ref,
        channel_prefix: channel_prefix,
        invite_user_refs: incident_invite_users,
        maximum_open_rooms: maximum_open_incidents,
        policy: incident_policy,
        private: incident_private
      })
      |> IncidentRooms.request()
    end

    automatic_request = fn ->
      case IncidentRooms.automatic_candidate(identity.workspace_ref) do
        {:ok, nil} -> {:ok, nil}
        {:ok, candidate} -> request_incident_room.(candidate)
        {:error, _reason} = error -> error
      end
    end

    catalog = %{
      default_repository: default_repository,
      repository_refs: repositories |> Map.keys() |> Enum.sort(),
      repository_urls: repository_urls(repositories)
    }

    setup_options = %{
      api: Client,
      bot_user_ref: identity.bot_user_ref,
      catalog: catalog,
      client: bot_client,
      configurations: ChannelConfigurations,
      directory: Client,
      operators: operators,
      settings_overrides: settings_overrides(default_participation)
    }

    handler_settings = %{
      action_tokens: &ActionTokens.remember/2,
      attachment_ingestor: AttachmentIngestor,
      attachment_options: %{
        client: file_client,
        downloader: FileClient,
        store: Artifacts
      },
      client: bot_client,
      command_handler: CommandHandler,
      command_options: %{
        bot_user_ref: identity.bot_user_ref,
        change_setting: &ChannelSettings.change(&1, default_participation),
        client: bot_client,
        directory: Client,
        effective_settings: effective_settings(default_participation),
        list_assignments: &Behaviors.assignments_for_channel/2,
        manage_assignment: &manage_assignment/3,
        operators: operators,
        settings_view: settings_view(catalog, default_participation)
      },
      continuation: &Engagement.continuation?/1,
      conversation_actor_allowed: incident_actor_allowed(operators),
      directory: Client,
      effective_settings: effective_settings(default_participation),
      home_handler: AppHome,
      home_interaction_handler: AppHomeControls,
      home_interaction_options: home_interaction_options,
      home_options: home_options,
      identity: identity,
      incident_lifecycle: &IncidentRooms.observe_lifecycle/1,
      inbox: Inbox,
      interaction_audit: &InteractionAudits.record/2,
      reaction_feedback: &Reactions.record/1,
      interaction_handler: InteractionHandler,
      interaction_options: %{
        answer_input_request: &InputRequests.answer/1,
        approve_publication: &Custody.approve/1,
        approve_task_publication: &WorkControls.approve_publication/1,
        check_publication: &Followups.request_check/2,
        check_task_publication: &WorkControls.check_publication/1,
        recover_task_publication: &WorkControls.recover_publication/2,
        client: bot_client,
        close_work: &WorkControls.close/1,
        configure_channel: &ChannelSetup.handle_interaction(&1, setup_options),
        confirm_automation: &Automations.confirm/1,
        confirm_behavior: &Behaviors.confirm/1,
        confirm_memory: &Memories.confirm/1,
        confirm_schedule: &Schedules.confirm/1,
        confirm_slack_post: &SlackPostOffers.confirm/1,
        confirm_task_offer: &TaskOffers.confirm/1,
        delete_behavior: fn ref, revision, actor_ref, workspace_ref, action_ref ->
          Behaviors.set_home_status(
            ref,
            :deleted,
            revision,
            "slack:user:#{actor_ref}",
            "slack:#{workspace_ref}",
            action_ref
          )
        end,
        resume_behavior: fn ref, revision, actor_ref, workspace_ref, action_ref ->
          Behaviors.set_home_status(
            ref,
            :active,
            revision,
            "slack:user:#{actor_ref}",
            "slack:#{workspace_ref}",
            action_ref
          )
        end,
        delete_schedule: fn ref, revision, actor_ref, workspace_ref, action_ref ->
          Schedules.set_home_status(
            ref,
            :deleted,
            revision,
            "slack:user:#{actor_ref}",
            action_ref,
            %{conversation_prefix: "slack:#{workspace_ref}:", transport: "slack"}
          )
        end,
        directory: Client,
        forget_memory: fn ref, actor_ref, workspace_ref ->
          Memories.forget_home(ref, "slack:user:#{actor_ref}", "slack:#{workspace_ref}")
        end,
        incident_policy: incident_policy,
        investigate_incident: &IncidentRooms.investigate/1,
        operators: operators,
        records: Records,
        request_incident_room: request_incident_room,
        request_publication_review: &Custody.request_review/1,
        repositories: repositories,
        show_work_record: &WorkControls.show_record(&1, work_record_options),
        resume_work: &WorkControls.resume/1,
        stop_work: &WorkControls.stop/1
      },
      standing_matcher: &Behaviors.standing_match?/1,
      setup_allowed: setup_allowed(),
      setup_handler: ChannelSetup,
      setup_options: setup_options,
      work_profile: work_profile(default_repository, repositories)
    }

    gateway =
      %{
        handler_settings: handler_settings,
        name: Gateway,
        receive_timeout_ms: Map.get(configuration, :receive_timeout_ms, 45_000),
        reconnect_ms: Map.get(configuration, :reconnect_ms, 1_000),
        transport: MintSocketTransport,
        transport_options: %{
          handshake_timeout_ms: Map.get(configuration, :handshake_timeout_ms, 10_000),
          http: app_http,
          requester: JSONClient
        }
      }
      |> Gateway.options!()

    reconciler =
      MembershipReconciler.options!(%{
        api: Client,
        client: bot_client,
        configurations: ChannelConfigurations,
        interval_ms: Map.get(configuration, :membership_reconcile_ms, 5 * 60 * 1_000),
        managed_channel?: &IncidentRooms.managed_channel?/2,
        name: MembershipReconciler,
        setup_handler: ChannelSetup,
        setup_options: setup_options,
        workspace_ref: identity.workspace_ref
      })

    incident_worker =
      IncidentRoomWorker.options!(%{
        api: Client,
        automatic_request: automatic_request,
        bot_user_ref: identity.bot_user_ref,
        client: bot_client,
        directory: Client,
        health_check_seconds:
          configuration
          |> Map.get(:incident_room_reconcile_ms, 5 * 60 * 1_000)
          |> bounded_integer!(:incident_room_reconcile_ms, 1_000..86_400_000)
          |> then(&max(div(&1 + 999, 1_000), 1)),
        interval_ms: Map.get(configuration, :incident_room_interval_ms, 1_000),
        lease_seconds: 300,
        max_attempts: 8,
        name: IncidentRoomWorker,
        reserve_channel: &ChannelConfigurations.reserve_managed_channel/2,
        retry_base_seconds: 1,
        worker_ref: "slack-incident-room:#{identity.workspace_ref}"
      })

    task_card_worker =
      TaskCardWorker.options!(%{
        api: Client,
        check_interval_seconds:
          configuration
          |> Map.get(:task_card_reconcile_ms, 2_000)
          |> bounded_integer!(:task_card_reconcile_ms, 1_000..86_400_000)
          |> then(&max(div(&1 + 999, 1_000), 1)),
        client: bot_client,
        interval_ms: Map.get(configuration, :task_card_interval_ms, 1_000),
        lease_seconds: 300,
        name: TaskCardWorker,
        retry_base_seconds: 1,
        worker_ref: "slack-task-card:#{identity.workspace_ref}"
      })

    setup_presentation = ChannelSetup.presentation(setup_options)

    interaction_feedback_worker =
      InteractionFeedbackWorker.options!(%{
        api: Client,
        client: bot_client,
        interval_ms: 1_000,
        lease_seconds: 300,
        max_attempts: 8,
        name: InteractionFeedbackWorker,
        repaint: &InteractionRepaint.repaint(&1, Map.put(&2, :setup, setup_presentation)),
        retry_base_seconds: 1,
        worker_ref: "slack-interaction-feedback:#{identity.workspace_ref}"
      })

    thread_status_worker =
      ThreadStatusWorker.options!(%{
        api: Client,
        client: bot_client,
        interval_ms: Map.get(configuration, :thread_status_interval_ms, 1_000),
        minimum_interval_ms: 3_000,
        name: ThreadStatusWorker,
        refresh_interval_ms: 90_000,
        retry_base_ms: 1_000,
        snapshot: &ThreadStatusProjection.snapshot/1,
        worker_ref: "slack-thread-status:#{identity.workspace_ref}",
        workspace_ref: identity.workspace_ref
      })

    %{
      action_tokens: %{name: ActionTokens},
      gateway: gateway,
      incident_worker: incident_worker,
      interaction_feedback_worker: interaction_feedback_worker,
      reconciler: reconciler,
      task_card_worker: task_card_worker,
      thread_status_worker: thread_status_worker
    }
  end

  defp effective_settings(default_participation) do
    fn workspace_ref, conversation_ref ->
      channel_ref = conversation_ref |> String.split(":", parts: 3) |> List.last()

      case IncidentRooms.channel_profile(workspace_ref, channel_ref) do
        {:ok, %{channel_state: :active, status: :ready}} ->
          %{
            proactive: %{source: :incident_room, value: true},
            shadow: %{source: :incident_room, value: false}
          }

        {:ok, _inactive_room} ->
          %{
            proactive: %{source: :incident_room, value: false},
            shadow: %{source: :incident_room, value: false}
          }

        :not_found ->
          ChannelSettings.effective(workspace_ref, conversation_ref, default_participation)
      end
    end
  end

  defp schedule_policy_resolver(configuration) do
    case Map.get(configuration, :schedule_policies) do
      %{} = policies ->
        policies
        |> ScheduleRuntime.options!()
        |> Map.fetch!(:dispatcher_options)
        |> Keyword.fetch!(:policy_resolver)

      nil ->
        fn _schedule -> {:error, :schedule_policy_unavailable} end
    end
  end

  defp work_profile(default_repository, repositories) do
    fn workspace_ref, conversation_ref ->
      channel_ref = conversation_ref |> String.split(":", parts: 3) |> List.last()

      case IncidentRooms.channel_profile(workspace_ref, channel_ref) do
        {:ok, profile} ->
          work_profile =
            %{
              policy: profile.policy,
              policy_digest: profile.policy_digest,
              repository_ref: profile.repository_ref
            }
            |> maybe_put_repository_context(profile.repository_context)

          {:ok, work_profile}

        :not_found ->
          repository_ref = configured_repository(workspace_ref, channel_ref, default_repository)
          {:ok, repositories |> Map.fetch!(repository_ref) |> Map.fetch!(:work_profile)}
      end
    end
  end

  defp configured_repository(workspace_ref, channel_ref, default_repository) do
    case ChannelConfigurations.configuration(workspace_ref, channel_ref) do
      %{repository_ref: repository_ref} when is_binary(repository_ref) -> repository_ref
      _unconfigured -> default_repository
    end
  end

  defp incident_actor_allowed(operators) do
    fn input ->
      channel_ref =
        input.destination.conversation_ref |> String.split(":", parts: 3) |> List.last()

      case IncidentRooms.channel_profile(input.source.ref, channel_ref) do
        :not_found ->
          {:ok, true}

        {:ok, %{channel_state: :active, status: :ready}} ->
          {:ok, input.actor.kind == :user and MapSet.member?(operators, input.actor.ref)}

        {:ok, _inactive_room} ->
          {:ok, false}
      end
    end
  end

  # The setup surfaces need the same override view as the gateway, keyed by
  # channel rather than conversation reference.
  defp settings_overrides(default_participation) do
    effective = effective_settings(default_participation)

    fn workspace_ref, channel_ref ->
      effective.(workspace_ref, "slack:#{workspace_ref}:#{channel_ref}")
    end
  end

  defp settings_view(catalog, default_participation) do
    overrides = settings_overrides(default_participation)

    fn workspace_ref, channel_ref ->
      ChannelConfigurations.effective_settings(
        workspace_ref,
        channel_ref,
        catalog,
        overrides.(workspace_ref, channel_ref)
      )
    end
  end

  defp setup_allowed do
    fn workspace_ref, conversation_ref ->
      channel_ref = conversation_ref |> String.split(":", parts: 3) |> List.last()
      {:ok, not IncidentRooms.managed_channel?(workspace_ref, channel_ref)}
    end
  end

  defp manage_assignment(ref, status, scope) do
    Behaviors.manage_assignment(ref, status, scope.workspace_ref, scope.conversation_ref)
  end

  defp normalize_configuration!(configuration) when is_list(configuration) do
    if Keyword.keyword?(configuration) and
         Enum.uniq(Keyword.keys(configuration)) == Keyword.keys(configuration) do
      configuration |> Map.new() |> normalize_configuration!()
    else
      raise ArgumentError, "Slack runtime configuration must use unique fields"
    end
  end

  defp normalize_configuration!(%{} = configuration) do
    keys = Map.keys(configuration)

    if keys -- @fields == [] and Enum.all?(@required_fields, &(&1 in keys)),
      do: configuration,
      else: raise(ArgumentError, "Slack runtime configuration has missing or unknown fields")
  end

  defp normalize_configuration!(_configuration) do
    raise ArgumentError, "Slack runtime configuration must be a map or keyword list"
  end

  defp validate_identity!(%{} = identity) do
    expected = [:bot_ref, :bot_user_ref, :workspace_ref]

    unless Map.keys(identity) |> Enum.sort() == Enum.sort(expected) and
             Enum.all?(expected, &slack_ref?(Map.fetch!(identity, &1))) do
      raise ArgumentError, "Slack identity must contain exact bounded Slack IDs"
    end
  end

  defp validate_identity!(_identity) do
    raise ArgumentError, "Slack identity must be a map"
  end

  defp references!(values, field) when is_list(values) do
    if Enum.uniq(values) == values and Enum.all?(values, &slack_ref?/1),
      do: MapSet.new(values),
      else: raise(ArgumentError, "Slack #{field} must contain unique Slack IDs")
  end

  defp references!(_values, field) do
    raise ArgumentError, "Slack #{field} must be a list"
  end

  defp participation!(value) when value in [:mentions, :proactive, :shadow], do: value

  defp participation!(_value),
    do: raise(ArgumentError, "Slack default_participation must be mentions, proactive, or shadow")

  defp channel_prefix!(value) do
    if is_binary(value) and Regex.match?(~r/\A[a-z0-9_-]{1,20}\z/, value),
      do: value,
      else: raise(ArgumentError, "Slack channel_prefix is invalid")
  end

  defp boolean!(value, _field) when is_boolean(value), do: value
  defp boolean!(_value, field), do: raise(ArgumentError, "Slack #{field} must be boolean")

  defp bounded_integer!(value, field, range) when is_integer(value) do
    if value in range,
      do: value,
      else: raise(ArgumentError, "Slack #{field} is out of range")
  end

  defp bounded_integer!(_value, field, _range),
    do: raise(ArgumentError, "Slack #{field} is out of range")

  defp repositories!(repositories) when is_map(repositories) do
    Map.new(repositories, fn
      {name, %{contributor_policy: policy} = attributes} when is_binary(name) and name != "" ->
        contributor_policy = policy!(policy, :contributor_policy)

        work_profile =
          Map.get(attributes, :work_profile, %{
            policy: contributor_policy.name,
            policy_digest: contributor_policy.digest,
            repository_ref: name
          })

        case WorkProfile.prepare(work_profile) do
          {:ok, profile} ->
            {name,
             %{
               contributor_policy: contributor_policy,
               github_repository: github_repository!(Map.get(attributes, :github_repository)),
               work_profile: profile
             }}

          {:error, _reason} ->
            raise ArgumentError, "Slack repositories must contain a valid Work profile"
        end

      _invalid ->
        raise ArgumentError, "Slack repositories must map names to contributor policies"
    end)
  end

  defp repositories!(_repositories) do
    raise ArgumentError, "Slack repositories must be a map"
  end

  defp github_repository!(nil), do: nil

  defp github_repository!(value) do
    if is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, value),
      do: value,
      else: raise(ArgumentError, "Slack repositories must name GitHub repositories as owner/name")
  end

  defp repository_urls(repositories) do
    repositories
    |> Enum.flat_map(fn
      {name, %{github_repository: full_name}} when is_binary(full_name) ->
        [{name, "https://github.com/#{full_name}"}]

      _repository ->
        []
    end)
    |> Map.new()
  end

  defp default_repository!(repository, repositories) do
    if is_binary(repository) and Map.has_key?(repositories, repository),
      do: repository,
      else: raise(ArgumentError, "Slack default_repository must name a configured repository")
  end

  defp file_client!(%Client{http: %JSONClient{} = http, requester: requester}) do
    with {:ok, binary_http} <-
           BinaryClient.new(%{
             finch: http.finch,
             receive_timeout: http.receive_timeout,
             token_provider: http.token_provider
           }),
         {:ok, file_client} <-
           FileClient.new(%{
             binary_http: binary_http,
             binary_requester: BinaryClient,
             json_http: http,
             json_requester: requester
           }) do
      file_client
    else
      {:error, reason} -> raise ArgumentError, "invalid Slack file client: #{inspect(reason)}"
    end
  end

  defp file_client!(_client), do: raise(ArgumentError, "Slack bot_client must use JSONClient")

  defp policy!(%{digest: digest, name: name} = source, field) do
    if is_binary(name) and String.valid?(name) and String.trim(name) != "" and
         byte_size(name) <= 256 and is_binary(digest) and
         Regex.match?(~r/\A[0-9a-f]{64}\z/, digest) do
      %{digest: digest, name: name}
      |> maybe_put_policy_placement(source)
    else
      raise ArgumentError, "Slack #{field} must contain a policy name and SHA-256 digest"
    end
  end

  defp policy!(_policy, field) do
    raise ArgumentError, "Slack #{field} must be a map"
  end

  defp maybe_put_policy_placement(policy, %{repository_ref: repository_ref} = source) do
    policy
    |> Map.put(:repository_ref, repository_ref)
    |> maybe_put_repository_context(Map.get(source, :repository_context))
  end

  defp maybe_put_policy_placement(policy, _source), do: policy

  defp maybe_put_repository_context(policy, nil), do: policy

  defp maybe_put_repository_context(policy, context),
    do: Map.put(policy, :repository_context, context)

  defp slack_ref?(value) do
    is_binary(value) and Regex.match?(~r/\A[A-Z0-9]+\z/, value) and byte_size(value) <= 256
  end
end
