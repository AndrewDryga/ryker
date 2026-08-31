defmodule Responder.Slack.ChannelSetup do
  @moduledoc """
  Slack presentation and input adapter for durable channel configuration.

  This module never trusts a button value beyond the setup UUID. Repository
  choices are resolved from the persisted offered catalog, and membership plus
  operator authority are rechecked for every action or conversational answer.
  """

  alias Responder.Slack.{ConfigurationSession, MembershipTransition}

  @repository_action ~r/\Aresponder_setup_repository_([0-9]{1,2})\z/
  @user_mention ~r/<@([A-Z0-9]+)>/
  @group_mention ~r/<!subteam\^([A-Z0-9]+)(?:\|[^>]+)?>/

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
         {:ok, prompted} <- maybe_prompt(result, options) do
      {:ok, Map.put(result, :prompted, prompted)}
    end
  end

  @spec handle_interaction(Responder.Slack.Interaction.t(), map()) ::
          {:ok, map()} | {:error, term()}
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
         {:ok, _prompted} <- ensure_prompt(result.session, options) do
      {:ok, %{outcome: result.status, session_ref: result.session.id}}
    end
  end

  @spec handle_message(map(), map()) :: :not_setup | {:ok, map()} | {:error, term()}
  def handle_message(
        %{
          audience: audience,
          input: %{actor: %{kind: :user, ref: actor_ref}} = input,
          platform_thread_ref: platform_thread_ref
        },
        options
      ) do
    with {:ok, workspace_ref, channel_ref} <- destination(input.destination.conversation_ref),
         true <- MapSet.member?(options.operators, actor_ref),
         {:ok, true} <- options.directory.user_allowed(options.client, actor_ref, workspace_ref),
         {:ok, session, started?} <-
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
         {:ok, _prompted} <- ensure_prompt(result.session, options) do
      {:ok, %{outcome: result.status, session_ref: result.session.id}}
    else
      nil ->
        :not_setup

      false ->
        :not_setup

      :not_setup ->
        :not_setup

      {:error, :not_setup} ->
        :not_setup

      {:ok, false} ->
        :not_setup

      {:error, :configuration_answer_ambiguous} ->
        clarify(input, platform_thread_ref, options)

      {:error, :configuration_audience_member_invalid} ->
        clarify(input, platform_thread_ref, options)

      {:error, _reason} = error ->
        error
    end
  end

  def handle_message(_normalized, _options), do: :not_setup

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

  @spec ensure_prompt(ConfigurationSession.t(), map()) ::
          {:ok, :existing | :posted} | {:error, term()}
  def ensure_prompt(%ConfigurationSession{} = session, options) do
    delivery_ref = delivery_ref(session)

    case options.api.find_message(
           options.client,
           session.channel_ref,
           session.response_thread_ref,
           delivery_ref
         ) do
      {:ok, message_ref} ->
        bind_prompt(session, message_ref, options, :existing)

      :not_found ->
        with {:ok, message_ref} <-
               options.api.post_message(
                 options.client,
                 session.channel_ref,
                 session.response_thread_ref,
                 document(session),
                 delivery_ref
               ) do
          bind_prompt(session, message_ref, options, :posted)
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec document(ConfigurationSession.t()) :: map()
  def document(%ConfigurationSession{} = session) do
    %{
      "channel_setup" => %{
        "draft" => session.draft,
        "expires_at" => DateTime.to_iso8601(session.expires_at),
        "revision" => session.revision,
        "session_ref" => session.id,
        "status" => Atom.to_string(session.status),
        "step" => Atom.to_string(session.step)
      }
    }
  end

  defp maybe_prompt(%{session: %ConfigurationSession{} = session}, options)
       when session.status in [:asking, :confirming],
       do: ensure_prompt(session, options)

  defp maybe_prompt(_result, _options), do: {:ok, :none}

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

  defp interaction_action("responder_setup_safe_defaults", _session),
    do: {:ok, :safe_defaults, nil}

  defp interaction_action("responder_setup_be_proactive", _session),
    do: {:ok, :be_proactive, nil}

  defp interaction_action("responder_setup_customize", _session), do: {:ok, :customize, nil}

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
    text =
      text
      |> String.replace("<@#{options.bot_user_ref}>", "")
      |> String.trim()

    answer_step(String.downcase(text), text, session)
  end

  defp answer(_text, _session, _options), do: {:error, :configuration_answer_ambiguous}

  defp answer_step(text, _original, %{step: :participation, draft: %{"customizing" => false}}) do
    case text do
      "use safe defaults" -> {:ok, :safe_defaults, nil}
      "safe defaults" -> {:ok, :safe_defaults, nil}
      "be proactive" -> {:ok, :be_proactive, nil}
      "customize" -> {:ok, :customize, nil}
      _other -> {:error, :configuration_answer_ambiguous}
    end
  end

  defp answer_step(text, _original, %{step: :participation}) do
    case text do
      value when value in ["mentions", "mentions only", "mention only"] ->
        {:ok, :participation, :mentions}

      "proactive" ->
        {:ok, :participation, :proactive}

      "shadow" ->
        {:ok, :participation, :shadow}

      _other ->
        movement(text)
    end
  end

  defp answer_step(text, original, %{step: :repository, draft: draft}) do
    repository = String.trim(original, "` ")

    if repository in draft["repository_options"],
      do: {:ok, :repository, repository},
      else: movement(text)
  end

  defp answer_step(text, _original, %{step: :alerts}) do
    case text do
      value when value in ["reply", "reply in place"] ->
        {:ok, :alerts, :reply}

      value when value in ["offer", "offer incident", "offer an incident"] ->
        {:ok, :alerts, :offer}

      value when value in ["automatic", "automatically create", "auto"] ->
        {:ok, :alerts, :automatic}

      _other ->
        movement(text)
    end
  end

  defp answer_step(text, original, %{step: :audience}) do
    users = captures(@user_mention, original)
    groups = captures(@group_mention, original)

    cond do
      text in ["none", "no one", "operators only", "no additional invitees"] ->
        {:ok, :audience, :none}

      users != [] or groups != [] ->
        {:ok, :audience, %{user_group_refs: groups, user_refs: users}}

      true ->
        movement(text)
    end
  end

  defp answer_step(text, _original, %{step: :confirm}) do
    case text do
      value when value in ["save", "save configuration"] -> {:ok, :save, nil}
      value when value in ["start over", "restart"] -> {:ok, :restart, nil}
      "cancel" -> {:ok, :cancel, nil}
      _other -> movement(text)
    end
  end

  defp movement(text) do
    case text do
      value when value in ["switch to a thread", "continue in a thread"] ->
        {:ok, :move_thread, nil}

      value when value in ["back to the channel", "continue in the channel"] ->
        {:ok, :move_channel, nil}

      _other ->
        {:error, :configuration_answer_ambiguous}
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
    text =
      input.content["text"]
      |> String.replace("<@#{options.bot_user_ref}>", "")
      |> String.trim()
      |> String.downcase()

    if text in ["reconfigure this channel", "configure this channel"] do
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

  defp destination("slack:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [workspace_ref, channel_ref] -> {:ok, workspace_ref, channel_ref}
      _invalid -> :not_setup
    end
  end

  defp destination(_conversation_ref), do: :not_setup

  defp delivery_ref(session), do: "slack-setup:#{session.id}:#{session.revision}"

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
    do: "Please choose Mentions only, Proactive, or Shadow using the current setup card."

  defp clarification(%ConfigurationSession{step: :repository, draft: draft}),
    do:
      "Please choose one configured code context: " <>
        Enum.map_join(draft["repository_options"], ", ", &"`#{&1}`") <> "."

  defp clarification(%ConfigurationSession{step: :alerts}),
    do: "Please choose Reply in place, Offer incident, or Automatic incident."

  defp clarification(%ConfigurationSession{step: :audience}),
    do: "Please mention full Slack members or user groups, or choose Operators only."

  defp clarification(%ConfigurationSession{step: :confirm}),
    do: "Please choose Save configuration, Start over, or Cancel."

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
