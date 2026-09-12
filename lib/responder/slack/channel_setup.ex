defmodule Responder.Slack.ChannelSetup do
  @moduledoc """
  Slack presentation and input adapter for durable channel configuration.

  A joined channel gets one welcome message rendered from its effective saved
  settings. The welcome's own controls change participation or start the
  optional setup Q&A; the Q&A is one wizard message that replaces itself in the
  welcome thread and, once saved, re-renders that same welcome. Settings asked
  for in conversation or through `/responder status` reuse the same projection.

  This module never trusts a button value beyond the setup or configuration
  identity it names. Repository choices are resolved from the persisted offered
  catalog, and membership plus operator authority are rechecked for every action
  or conversational answer.
  """

  alias Responder.Slack.{
    ChannelConfiguration,
    Collections,
    ConfigurationSession,
    MembershipTransition
  }

  @repository_action ~r/\Aresponder_setup_repository_([0-9]{1,2})\z/
  @welcome_value ~r/\A([0-9a-f-]{36})\|([1-9][0-9]{0,9})\z/
  @user_mention ~r/<@([A-Z0-9]+)>/
  @group_mention ~r/<!subteam\^([A-Z0-9]+)(?:\|[^>]+)?>/
  @reconfigure_requests ["reconfigure this channel", "configure this channel"]
  @settings_requests [
    "settings",
    "show settings",
    "show your settings",
    "what are your settings",
    "what are your settings here",
    "how are you configured",
    "how are you configured here",
    "channel settings",
    "show channel settings"
  ]
  @collection_requests %{
    "active schedules" => :schedules,
    "list schedules" => :schedules,
    "show schedules" => :schedules,
    "what schedules are active" => :schedules,
    "which schedules are active" => :schedules,
    "active rules" => :standing_rules,
    "active standing rules" => :standing_rules,
    "list rules" => :standing_rules,
    "list standing rules" => :standing_rules,
    "show rules" => :standing_rules,
    "show standing rules" => :standing_rules,
    "what rules are active" => :standing_rules,
    "list saved knowledge" => :knowledge,
    "show saved knowledge" => :knowledge,
    "show what you remember" => :knowledge,
    "what do you remember here" => :knowledge,
    "what have you saved here" => :knowledge
  }

  @spec handle_membership(MembershipTransition.t(), map()) :: {:ok, map()} | {:error, term()}
  def handle_membership(%MembershipTransition{} = transition, options) do
    actor_ref =
      if is_binary(transition.actor_ref) and
           MapSet.member?(options.operators, transition.actor_ref),
         do: transition.actor_ref,
         else: nil

    request = %{
      actor_ref: actor_ref,
      channel_ref: transition.channel_ref,
      event_ref: transition.event_ref,
      kind: transition.kind,
      occurred_at: transition.occurred_at,
      workspace_ref: transition.workspace_ref
    }

    with {:ok, result} <- options.configurations.observe_membership(request, options.catalog),
         {:ok, prompted} <- maybe_welcome(result, options) do
      {:ok, Map.put(result, :prompted, prompted)}
    end
  end

  @spec handle_interaction(Responder.Slack.Interaction.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def handle_interaction(%{action_id: "responder_welcome_" <> _rest} = interaction, options) do
    with {:ok, configuration_ref, revision} <- welcome_value(interaction.action_value) do
      welcome_action(interaction, configuration_ref, revision, options)
    end
  end

  def handle_interaction(interaction, options) do
    with {:ok, session} <- options.configurations.fetch_session(interaction.action_value),
         {:ok, action, value} <- interaction_action(interaction.action_id, session),
         :ok <- validate_choice(action, value, interaction.workspace_ref, options),
         {:ok, result} <-
           options.configurations.apply_action(%{
             action: action,
             actor_ref: interaction.actor_ref,
             channel_ref: interaction.channel_ref,
             event_ref: interaction.event_ref,
             message_ref: interaction.message_ref,
             occurred_at: interaction.occurred_at,
             session_ref: session.id,
             source: :control,
             thread_ref: interaction.thread_ref,
             value: value,
             workspace_ref: interaction.workspace_ref
           }),
         {:ok, _prompted} <- ensure_prompt(result.session, options),
         :ok <- welcome_after_save(result, options) do
      {:ok, %{outcome: result.status, session_ref: result.session.id}}
    end
  end

  @spec handle_message(map(), map()) :: :not_setup | {:ok, map()} | {:error, term()}
  def handle_message(
        %{
          audience: audience,
          input: %{actor: %{kind: :user, ref: actor_ref}} = input,
          platform_thread_ref: platform_thread_ref
        } = normalized,
        options
      ) do
    with {:ok, workspace_ref, channel_ref} <- destination(input.destination.conversation_ref),
         request = read_request(audience, input, options),
         true <- request != nil or MapSet.member?(options.operators, actor_ref),
         {:ok, true} <- options.directory.user_allowed(options.client, actor_ref, workspace_ref) do
      case request do
        :settings ->
          show_settings(input, platform_thread_ref, workspace_ref, channel_ref, options)

        nil ->
          setup_message(normalized, workspace_ref, channel_ref, options)

        kind ->
          show_collection(kind, input, platform_thread_ref, workspace_ref, channel_ref, options)
      end
    else
      :not_setup -> :not_setup
      false -> :not_setup
      {:ok, false} -> :not_setup
      {:error, _reason} = error -> error
    end
  end

  def handle_message(_normalized, _options), do: :not_setup

  defp setup_message(
         %{audience: audience, input: input, platform_thread_ref: platform_thread_ref},
         workspace_ref,
         channel_ref,
         options
       ) do
    with {:ok, session, started?} <-
           setup_session(
             audience,
             input,
             platform_thread_ref,
             workspace_ref,
             channel_ref,
             options
           ),
         {:ok, result} <-
           apply_message(
             started?,
             session,
             input,
             platform_thread_ref,
             workspace_ref,
             channel_ref,
             options
           ),
         {:ok, _prompted} <- ensure_prompt(result.session, options),
         :ok <- welcome_after_save(result, options) do
      {:ok, %{outcome: result.status, session_ref: result.session.id}}
    else
      {:error, :not_setup} ->
        :not_setup

      {:error, :configuration_answer_ambiguous} ->
        clarify(input, platform_thread_ref, options)

      {:error, :configuration_audience_member_invalid} ->
        clarify(input, platform_thread_ref, options)

      {:error, _reason} = error ->
        error
    end
  end

  defp apply_message(true, session, _input, _thread_ref, _workspace_ref, _channel_ref, _options),
    do: {:ok, %{session: session, status: :started}}

  defp apply_message(
         false,
         session,
         input,
         thread_ref,
         workspace_ref,
         channel_ref,
         options
       ) do
    with {:ok, action, value} <- answer(input.content["text"], session, options),
         :ok <- validate_choice(action, value, workspace_ref, options) do
      options.configurations.apply_action(%{
        action: action,
        actor_ref: input.actor.ref,
        channel_ref: channel_ref,
        event_ref: input.event_ref,
        message_ref: input.source_item_ref,
        occurred_at: input.occurred_at,
        session_ref: session.id,
        source: :message,
        thread_ref: thread_ref,
        value: value,
        workspace_ref: workspace_ref
      })
    end
  end

  @doc """
  Posts the wizard once, then updates that same message after every step. The
  wizard never replaces the welcome; saving re-renders the welcome separately.
  """
  @spec ensure_prompt(ConfigurationSession.t(), map()) ::
          {:ok, :existing | :posted | :updated} | {:error, term()}
  def ensure_prompt(%ConfigurationSession{current_message_ref: nil} = session, options) do
    delivery_ref = delivery_ref(session)

    case options.api.find_message(
           options.client,
           session.channel_ref,
           session.response_thread_ref,
           delivery_ref
         ) do
      {:ok, message_ref} ->
        with :ok <- update_prompt(session, message_ref, options) do
          bind_prompt(session, message_ref, options, :existing)
        end

      :not_found ->
        with {:ok, message_ref} <-
               options.api.post_message(
                 options.client,
                 session.channel_ref,
                 session.response_thread_ref,
                 document(session, presentation(options)),
                 delivery_ref
               ) do
          bind_prompt(session, message_ref, options, :posted)
        end

      {:error, _reason} = error ->
        error
    end
  end

  def ensure_prompt(%ConfigurationSession{current_message_ref: message_ref} = session, options) do
    with :ok <- update_prompt(session, message_ref, options) do
      {:ok, :updated}
    end
  end

  @doc """
  Posts the channel welcome once per membership generation and re-renders that
  same message from the effective saved settings afterwards.
  """
  @spec ensure_welcome(ChannelConfiguration.t(), String.t() | nil, map()) ::
          {:ok, :posted | :updated} | {:error, term()}
  def ensure_welcome(%ChannelConfiguration{} = configuration, notice, options) do
    with {:ok, document} <- welcome_document(configuration, notice, options) do
      deliver_welcome(configuration, document, options)
    end
  end

  @doc false
  @spec welcome_document(ChannelConfiguration.t(), String.t() | nil, map()) ::
          {:ok, map()} | {:error, term()}
  def welcome_document(%ChannelConfiguration{} = configuration, notice, options) do
    with {:ok, settings} <-
           settings(configuration.workspace_ref, configuration.channel_ref, options) do
      {:ok,
       %{
         "channel_welcome" => %{
           "bot_user_ref" => options.bot_user_ref,
           "configuration_ref" => configuration.id,
           "notice" => notice,
           "revision" => configuration.revision,
           "settings" => settings
         }
       }}
    end
  end

  @doc false
  @spec settings_document(String.t(), String.t(), :private | :thread, map()) ::
          {:ok, map()} | {:error, term()}
  def settings_document(workspace_ref, channel_ref, audience, options) do
    with {:ok, settings} <- settings(workspace_ref, channel_ref, options) do
      {:ok,
       %{
         "channel_settings" => %{
           "audience" => Atom.to_string(audience),
           "bot_user_ref" => options.bot_user_ref,
           "configuration_ref" => settings["configuration_ref"],
           "revision" => settings["revision"],
           "settings" => settings
         }
       }}
    end
  end

  @doc "The wizard document; `presentation` names the bot and the configured on-call count."
  @spec document(ConfigurationSession.t(), %{
          bot_user_ref: String.t(),
          on_call_count: non_neg_integer()
        }) :: map()
  def document(%ConfigurationSession{} = session, %{bot_user_ref: bot_user_ref}) do
    %{
      "channel_setup" => %{
        "bot_user_ref" => bot_user_ref,
        "draft" => session.draft,
        "expires_at" => DateTime.to_iso8601(session.expires_at),
        "revision" => session.revision,
        "session_ref" => session.id,
        "status" => Atom.to_string(session.status),
        "step" => Atom.to_string(session.step)
      }
    }
  end

  @doc false
  @spec presentation(map()) :: %{bot_user_ref: String.t(), on_call_count: non_neg_integer()}
  def presentation(options) do
    %{
      bot_user_ref: options.bot_user_ref,
      on_call_count: Map.get(options.catalog, :on_call_count, 0)
    }
  end

  defp settings(workspace_ref, channel_ref, options) do
    options.configurations.effective_settings(
      workspace_ref,
      channel_ref,
      options.catalog,
      options.settings_overrides.(workspace_ref, channel_ref)
    )
  end

  defp deliver_welcome(
         %ChannelConfiguration{welcome_message_ref: nil} = configuration,
         document,
         options
       ) do
    delivery_ref = welcome_delivery_ref(configuration, options)

    case options.api.find_message(options.client, configuration.channel_ref, nil, delivery_ref) do
      {:ok, message_ref} ->
        with :ok <-
               options.api.update_message(
                 options.client,
                 configuration.channel_ref,
                 message_ref,
                 document,
                 delivery_ref
               ),
             {:ok, _configuration} <- bind_welcome(configuration, message_ref, options) do
          {:ok, :updated}
        end

      :not_found ->
        with {:ok, message_ref} <-
               options.api.post_message(
                 options.client,
                 configuration.channel_ref,
                 nil,
                 document,
                 delivery_ref
               ),
             {:ok, _configuration} <- bind_welcome(configuration, message_ref, options) do
          {:ok, :posted}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp deliver_welcome(
         %ChannelConfiguration{welcome_message_ref: message_ref} = configuration,
         document,
         options
       ) do
    with :ok <-
           options.api.update_message(
             options.client,
             configuration.channel_ref,
             message_ref,
             document,
             welcome_delivery_ref(configuration, options)
           ) do
      {:ok, :updated}
    end
  end

  # A re-added channel gets a fresh welcome; the generation keeps a bounded
  # history scan from rebinding the previous membership's message.
  defp welcome_delivery_ref(configuration, options) do
    generation =
      case options.configurations.membership(
             configuration.workspace_ref,
             configuration.channel_ref
           ) do
        %{generation: generation} -> generation
        nil -> 0
      end

    "slack-welcome:#{configuration.id}:#{generation}"
  end

  defp bind_welcome(configuration, message_ref, options) do
    options.configurations.bind_welcome(
      configuration.workspace_ref,
      configuration.channel_ref,
      message_ref
    )
  end

  defp maybe_welcome(
         %{configuration: %ChannelConfiguration{} = configuration, status: status},
         options
       )
       when status in [:joined, :duplicate],
       do: ensure_welcome(configuration, nil, options)

  defp maybe_welcome(_result, _options), do: {:ok, :none}

  # Who changed it and when, the way a teammate would say it — not a system
  # notice that leaves the channel guessing which of them pressed something.
  defp settings_notice(%ChannelConfiguration{actor_ref: actor, saved_at: %DateTime{} = at})
       when is_binary(actor),
       do: %{"actor_ref" => actor, "at" => DateTime.to_iso8601(at)}

  defp settings_notice(_configuration), do: "Settings changed."

  defp welcome_after_save(%{status: :saved, session: session}, options) do
    case options.configurations.configuration(session.workspace_ref, session.channel_ref) do
      %ChannelConfiguration{} = configuration ->
        with {:ok, _delivered} <-
               ensure_welcome(configuration, settings_notice(configuration), options) do
          :ok
        end

      nil ->
        {:error, :configuration_not_found}
    end
  end

  defp welcome_after_save(_result, _options), do: :ok

  defp update_prompt(session, message_ref, options) do
    options.api.update_message(
      options.client,
      session.channel_ref,
      message_ref,
      document(session, presentation(options)),
      delivery_ref(session)
    )
  end

  defp bind_prompt(session, message_ref, options, outcome) do
    case options.configurations.bind_prompt(
           session.id,
           session.revision,
           message_ref,
           session.response_thread_ref
         ) do
      {:ok, _session} -> {:ok, outcome}
      {:error, :configuration_prompt_already_bound} -> {:ok, :existing}
      {:error, _reason} = error -> error
    end
  end

  defp welcome_value(value) when is_binary(value) do
    case Regex.run(@welcome_value, value) do
      [_whole, configuration_ref, revision] ->
        {:ok, configuration_ref, String.to_integer(revision)}

      nil ->
        {:error, :configuration_action_mismatch}
    end
  end

  defp welcome_value(_value), do: {:error, :configuration_action_mismatch}

  defp welcome_action(
         %{action_id: "responder_welcome_configure"} = interaction,
         configuration_ref,
         revision,
         options
       ) do
    with {:ok, configuration} <-
           current_configuration(interaction, configuration_ref, revision, options),
         {:ok, %{session: session, status: status}} <-
           options.configurations.start_reconfiguration(
             %{
               actor_ref: interaction.actor_ref,
               channel_ref: interaction.channel_ref,
               event_ref: interaction.event_ref,
               occurred_at: interaction.occurred_at,
               thread_ref: configuration.welcome_message_ref,
               workspace_ref: interaction.workspace_ref
             },
             options.catalog
           ),
         {:ok, _prompted} <- ensure_prompt(session, options) do
      {:ok, %{outcome: status, session_ref: session.id}}
    end
  end

  defp welcome_action(
         %{action_id: "responder_welcome_view_" <> collection} = interaction,
         configuration_ref,
         revision,
         options
       )
       when collection in ~w(schedules rules) do
    kind = if collection == "schedules", do: :schedules, else: :standing_rules

    with {:ok, _configuration} <-
           current_configuration(interaction, configuration_ref, revision, options),
         {:ok, result} <-
           Collections.deliver(
             kind,
             %{
               channel_ref: interaction.channel_ref,
               request_ref: interaction.event_ref,
               thread_ref: interaction.thread_ref || interaction.message_ref,
               workspace_ref: interaction.workspace_ref
             },
             options
           ) do
      {:ok,
       %{collection: kind, outcome: :collection_shown, shown: result.shown, total: result.total}}
    end
  end

  defp welcome_action(interaction, configuration_ref, revision, options) do
    {participation, notice} =
      case interaction.action_id do
        "responder_welcome_be_proactive" -> {:proactive, "Update: proactive mode is on."}
        "responder_welcome_mentions_only" -> {:mentions, "Update: I'll reply when mentioned."}
      end

    with {:ok, %{configuration: configuration, status: status}} <-
           options.configurations.change_participation(%{
             actor_ref: interaction.actor_ref,
             channel_ref: interaction.channel_ref,
             configuration_ref: configuration_ref,
             event_ref: interaction.event_ref,
             expected_revision: revision,
             occurred_at: interaction.occurred_at,
             participation: participation,
             workspace_ref: interaction.workspace_ref
           }),
         {:ok, _delivered} <-
           ensure_welcome(configuration, if(status == :saved, do: notice), options) do
      {:ok, %{configuration_ref: configuration.id, outcome: status}}
    end
  end

  defp current_configuration(interaction, configuration_ref, revision, options) do
    case options.configurations.configuration(interaction.workspace_ref, interaction.channel_ref) do
      %ChannelConfiguration{id: ^configuration_ref, revision: ^revision} = configuration ->
        {:ok, configuration}

      %ChannelConfiguration{id: ^configuration_ref} ->
        {:error, :configuration_revision_stale}

      _other ->
        {:error, :configuration_not_found}
    end
  end

  defp interaction_action("responder_setup_participation_mentions", _session),
    do: {:ok, :participation, :mentions}

  defp interaction_action("responder_setup_participation_proactive", _session),
    do: {:ok, :participation, :proactive}

  defp interaction_action("responder_setup_participation_shadow", _session),
    do: {:ok, :participation, :shadow}

  defp interaction_action("responder_setup_alerts_reply", _session),
    do: {:ok, :alerts, :reply}

  defp interaction_action("responder_setup_alerts_offer", _session),
    do: {:ok, :alerts, :offer}

  defp interaction_action("responder_setup_alerts_automatic", _session),
    do: {:ok, :alerts, :automatic}

  defp interaction_action("responder_setup_audience_none", _session),
    do: {:ok, :audience, :none}

  defp interaction_action("responder_setup_save", _session), do: {:ok, :save, nil}
  defp interaction_action("responder_setup_restart", _session), do: {:ok, :restart, nil}
  defp interaction_action("responder_setup_cancel", _session), do: {:ok, :cancel, nil}

  defp interaction_action(action_id, session) do
    case Regex.run(@repository_action, action_id) do
      [_whole, index] ->
        with {index, ""} <- Integer.parse(index),
             repository_ref when is_binary(repository_ref) <-
               Enum.at(session.draft["repository_options"], index) do
          {:ok, :repository, repository_ref}
        else
          _invalid -> {:error, :configuration_action_mismatch}
        end

      _invalid ->
        {:error, :configuration_action_mismatch}
    end
  end

  defp answer(text, session, options) when is_binary(text) do
    text = addressed_text(text, options)
    answer_step(String.downcase(text), text, session)
  end

  defp answer(_text, _session, _options), do: {:error, :configuration_answer_ambiguous}

  defp answer_step(text, _original, %{step: :participation}) do
    case text do
      value when value in ["mentions", "mentions only", "mention only"] ->
        {:ok, :participation, :mentions}

      value when value in ["proactive", "be proactive"] ->
        {:ok, :participation, :proactive}

      value when value in ["shadow", "observe", "observe only"] ->
        {:ok, :participation, :shadow}

      _other ->
        {:error, :configuration_answer_ambiguous}
    end
  end

  defp answer_step(_text, original, %{step: :repository, draft: draft}) do
    repository = String.trim(original, "` ")

    if repository in draft["repository_options"],
      do: {:ok, :repository, repository},
      else: {:error, :configuration_answer_ambiguous}
  end

  defp answer_step(text, _original, %{step: :alerts}) do
    case text do
      value when value in ["reply", "reply in place", "investigate"] ->
        {:ok, :alerts, :reply}

      value when value in ["offer", "offer a choice", "offer incident", "offer an incident"] ->
        {:ok, :alerts, :offer}

      value when value in ["automatic", "automatically create", "create automatically", "auto"] ->
        {:ok, :alerts, :automatic}

      _other ->
        {:error, :configuration_answer_ambiguous}
    end
  end

  defp answer_step(text, original, %{step: :audience}) do
    users = captures(@user_mention, original)
    groups = captures(@group_mention, original)

    cond do
      text in ["none", "no one", "no invitations", "operators only", "on-call responders only"] ->
        {:ok, :audience, :none}

      users != [] or groups != [] ->
        {:ok, :audience, %{user_group_refs: groups, user_refs: users}}

      true ->
        {:error, :configuration_answer_ambiguous}
    end
  end

  defp answer_step(text, _original, %{step: :confirm}) do
    case text do
      value when value in ["save", "save settings", "save configuration"] -> {:ok, :save, nil}
      value when value in ["start over", "restart"] -> {:ok, :restart, nil}
      "cancel" -> {:ok, :cancel, nil}
      _other -> {:error, :configuration_answer_ambiguous}
    end
  end

  defp captures(regex, text) do
    regex
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp validate_choice(
         :audience,
         %{user_group_refs: groups, user_refs: users},
         workspace_ref,
         options
       ) do
    with :ok <- validate_users(users, workspace_ref, options) do
      validate_groups(groups, workspace_ref, options)
    end
  end

  defp validate_choice(_action, _value, _workspace_ref, _options), do: :ok

  defp validate_users(users, workspace_ref, options) do
    Enum.reduce_while(users, :ok, fn user_ref, :ok ->
      case options.directory.user_allowed(options.client, user_ref, workspace_ref) do
        {:ok, true} -> {:cont, :ok}
        {:ok, false} -> {:halt, {:error, :configuration_audience_member_invalid}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_groups(groups, workspace_ref, options) do
    if function_exported?(options.directory, :user_group_members, 3) do
      Enum.reduce_while(groups, :ok, fn group_ref, :ok ->
        validate_group(group_ref, workspace_ref, options)
      end)
    else
      {:error, :configuration_user_group_directory_unavailable}
    end
  end

  defp validate_group(group_ref, workspace_ref, options) do
    case options.directory.user_group_members(options.client, group_ref, workspace_ref) do
      {:ok, users} when is_list(users) -> {:cont, :ok}
      {:error, _reason} = error -> {:halt, error}
      _invalid -> {:halt, {:error, {:slack_protocol_error, :user_group}}}
    end
  end

  defp setup_session(audience, input, thread_ref, workspace_ref, channel_ref, options) do
    case options.configurations.active_session(workspace_ref, channel_ref) do
      %ConfigurationSession{} = session ->
        {:ok, session, false}

      nil ->
        start_reconfiguration(
          audience,
          input,
          thread_ref,
          workspace_ref,
          channel_ref,
          options
        )
    end
  end

  defp start_reconfiguration(:mention, input, thread_ref, workspace_ref, channel_ref, options) do
    text = input.content["text"] |> addressed_text(options) |> String.downcase()

    if text in @reconfigure_requests do
      options.configurations.start_reconfiguration(
        %{
          actor_ref: input.actor.ref,
          channel_ref: channel_ref,
          event_ref: input.event_ref,
          occurred_at: input.occurred_at,
          thread_ref: thread_ref,
          workspace_ref: workspace_ref
        },
        options.catalog
      )
      |> case do
        {:ok, %{session: session}} -> {:ok, session, true}
        {:error, _reason} = error -> error
      end
    else
      {:error, :not_setup}
    end
  end

  defp start_reconfiguration(
         _audience,
         _input,
         _thread_ref,
         _workspace_ref,
         _channel_ref,
         _options
       ),
       do: {:error, :not_setup}

  # Settings and collections are read-only answers any full member may ask
  # for; they are recognized deterministically when Responder is addressed.
  defp read_request(:mention, %{content: %{"text" => text}}, options) when is_binary(text) do
    request =
      text
      |> addressed_text(options)
      |> String.downcase()
      |> String.trim_trailing("?")
      |> String.trim_trailing(".")

    cond do
      request in @settings_requests -> :settings
      Map.has_key?(@collection_requests, request) -> Map.fetch!(@collection_requests, request)
      true -> nil
    end
  end

  defp read_request(_audience, _input, _options), do: nil

  defp show_collection(kind, input, thread_ref, workspace_ref, channel_ref, options) do
    with {:ok, result} <-
           Collections.deliver(
             kind,
             %{
               channel_ref: channel_ref,
               request_ref: input.event_ref,
               thread_ref: thread_ref || input.source_item_ref,
               workspace_ref: workspace_ref
             },
             options
           ) do
      {:ok,
       %{outcome: :collection_shown, collection: kind, shown: result.shown, total: result.total}}
    end
  end

  # A settings question is answered in the thread it was asked in, from the
  # same projection as the welcome, and never changes anything.
  defp show_settings(input, thread_ref, workspace_ref, channel_ref, options) do
    thread_ref = thread_ref || input.source_item_ref
    delivery_ref = "slack-settings:#{input.event_ref}"

    with {:ok, document} <- settings_document(workspace_ref, channel_ref, :thread, options),
         :not_found <-
           options.api.find_message(options.client, channel_ref, thread_ref, delivery_ref),
         {:ok, _message_ref} <-
           options.api.post_message(
             options.client,
             channel_ref,
             thread_ref,
             document,
             delivery_ref
           ) do
      {:ok, %{outcome: :settings_shown}}
    else
      {:ok, _message_ref} -> {:ok, %{outcome: :settings_shown}}
      {:error, _reason} = error -> error
    end
  end

  defp addressed_text(text, options) do
    text
    |> String.replace("<@#{options.bot_user_ref}>", "")
    |> String.trim()
  end

  defp destination("slack:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [workspace_ref, channel_ref] -> {:ok, workspace_ref, channel_ref}
      _invalid -> :not_setup
    end
  end

  defp destination(_conversation_ref), do: :not_setup

  defp delivery_ref(session), do: "slack-setup:#{session.id}"

  defp clarify(input, thread_ref, options) do
    with {:ok, workspace_ref, channel_ref} <- destination(input.destination.conversation_ref),
         %ConfigurationSession{} = session <-
           options.configurations.active_session(workspace_ref, channel_ref),
         delivery_ref <- "slack-setup-clarification:#{session.id}:#{input.event_ref}",
         :not_found <-
           options.api.find_message(options.client, channel_ref, thread_ref, delivery_ref),
         {:ok, _message_ref} <-
           options.api.post_message(
             options.client,
             channel_ref,
             thread_ref,
             clarification(session),
             delivery_ref
           ) do
      {:ok, %{outcome: :clarification, session_ref: session.id}}
    else
      {:ok, _message_ref} ->
        {:ok, %{outcome: :clarification, session_ref: active_session_ref(input, options)}}

      nil ->
        :not_setup

      {:error, _reason} = error ->
        error
    end
  end

  defp clarification(%ConfigurationSession{step: :participation}),
    do: "Please choose Mentions only, Be proactive, or Observe only using the current setup card."

  defp clarification(%ConfigurationSession{step: :repository, draft: draft}),
    do:
      "Please choose one connected repository: " <>
        Enum.map_join(draft["repository_options"], ", ", &"`#{&1}`") <> "."

  defp clarification(%ConfigurationSession{step: :alerts}),
    do: "Please choose Investigate, Offer a choice, or Create automatically."

  defp clarification(%ConfigurationSession{step: :audience}),
    do:
      "Please mention the full Slack members or user groups to invite, or choose the button to invite no one else."

  defp clarification(%ConfigurationSession{step: :confirm}),
    do: "Please choose Save settings, Start over, or Cancel."

  defp active_session_ref(input, options) do
    with {:ok, workspace_ref, channel_ref} <- destination(input.destination.conversation_ref),
         %ConfigurationSession{id: session_ref} <-
           options.configurations.active_session(workspace_ref, channel_ref) do
      session_ref
    else
      _missing -> nil
    end
  end
end
