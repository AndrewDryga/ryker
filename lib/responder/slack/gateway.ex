defmodule Responder.Slack.Gateway do
  @moduledoc """
  Durable acknowledgement boundary for Slack Socket Mode envelopes.

  An Events API envelope becomes acknowledgeable only after its normalized
  input is durable. A host control becomes acknowledgeable only after its
  authority-checked transition has completed. Transient failures deliberately
  leave the envelope unacknowledged for Slack to retry.
  """

  use GenServer

  require Logger

  alias Responder.Ingress.Inbox

  alias Responder.Slack.{
    Command,
    Event,
    HomeEvent,
    HomeInteraction,
    HomeSubmission,
    Interaction,
    MembershipTransition,
    ReactionEvent,
    Shortcut
  }

  @configuration_fields [
    :handler_settings,
    :name,
    :receive_timeout_ms,
    :reconnect_ms,
    :transport,
    :transport_options
  ]
  @maximum_envelope_bytes 1_048_576

  @type outcome ::
          {:ack, term()}
          | {:ack, term(), map()}
          | {:retry, term()}
          | :ignore

  @spec start_link(keyword() | map()) :: GenServer.on_start()
  def start_link(configuration) do
    options = options!(configuration)

    case options.name do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  @impl GenServer
  def init(options) do
    send(self(), :connect)

    {:ok,
     Map.merge(options, %{
       connection: nil,
       idle_ref: nil,
       reconnect_scheduled: false
     })}
  end

  @impl GenServer
  def handle_info(:connect, %{connection: nil} = state) do
    case state.transport.connect(state.transport_options) do
      {:ok, connection} ->
        {:noreply,
         state
         |> Map.put(:connection, connection)
         |> Map.put(:reconnect_scheduled, false)
         |> arm_idle()}

      {:error, reason} ->
        Logger.warning("Slack Socket Mode connection failed: #{inspect(reason)}")
        {:noreply, schedule_reconnect(state)}
    end
  end

  def handle_info(:connect, state), do: {:noreply, state}

  def handle_info({:socket_idle, idle_ref}, %{idle_ref: idle_ref} = state) do
    Logger.warning("Slack Socket Mode connection became idle; reconnecting")
    {:noreply, reconnect(state)}
  end

  def handle_info({:socket_idle, _old_ref}, state), do: {:noreply, state}

  def handle_info(message, %{connection: nil} = state) do
    _ignored = message
    {:noreply, state}
  end

  def handle_info(message, state) do
    case state.transport.stream(state.connection, message) do
      {:ok, connection, frames} when is_list(frames) ->
        state = state |> Map.put(:connection, connection) |> arm_idle()

        case process_frames(frames, state) do
          {:ok, state} -> {:noreply, state}
          {:reconnect, state} -> {:noreply, reconnect(state)}
        end

      {:unknown, connection} ->
        {:noreply, %{state | connection: connection}}

      {:error, reason} ->
        Logger.warning("Slack Socket Mode stream failed: #{inspect(reason)}")
        {:noreply, reconnect(state)}
    end
  end

  @impl GenServer
  def terminate(_reason, %{connection: nil}), do: :ok

  def terminate(_reason, state) do
    state.transport.close(state.connection)
  end

  @spec handle_envelope(map(), map()) :: outcome()
  def handle_envelope(%{"type" => "events_api"} = envelope, settings) do
    case HomeEvent.from_socket(envelope, settings.identity) do
      {:ok, event} ->
        handle_home(event, settings)

      :ignore ->
        handle_membership_envelope(envelope, settings)
    end
  end

  def handle_envelope(%{"type" => "interactive"} = envelope, settings) do
    now = database_now()

    case HomeInteraction.from_socket(envelope, settings.identity.workspace_ref, now) do
      {:ok, interaction} ->
        handle_home_interaction(interaction, settings)

      :ignore ->
        case HomeSubmission.from_socket(envelope, settings.identity.workspace_ref, now) do
          {:ok, submission} ->
            handle_home_interaction(submission, settings)

          {:error, errors} ->
            {:ack, {:app_home_control, :invalid},
             %{"errors" => errors, "response_action" => "errors"}}

          :ignore ->
            handle_message_interaction(envelope, now, settings)
        end
    end
  end

  def handle_envelope(%{"type" => "slash_commands"} = envelope, settings) do
    case Command.from_socket(envelope, settings.identity.workspace_ref, database_now()) do
      {:ok, command} -> handle_command(command, settings)
      :ignore -> {:ack, {:ignored, :unsupported_command}}
    end
  end

  def handle_envelope(%{"type" => type}, _settings) when type in ["disconnect", "hello"],
    do: :ignore

  def handle_envelope(%{"envelope_id" => _envelope_id}, _settings),
    do: {:ack, {:ignored, :unsupported_envelope}}

  def handle_envelope(_envelope, _settings), do: :ignore

  defp handle_membership_envelope(envelope, settings) do
    case MembershipTransition.from_socket(envelope, settings.identity) do
      {:ok, transition} -> handle_membership(transition, settings)
      :ignore -> handle_event_envelope(envelope, settings)
      {:error, _reason} -> {:ack, {:ignored, :invalid_membership_event}}
    end
  end

  defp handle_event_envelope(envelope, settings) do
    case ReactionEvent.from_socket(envelope, settings.identity) do
      {:ok, reaction} ->
        handle_reaction(reaction, settings)

      :ignore ->
        case Event.from_socket(envelope, settings.identity) do
          {:ok, normalized} -> handle_event(normalized, settings)
          :ignore -> {:ack, {:ignored, :unsupported_event}}
          {:error, _reason} -> {:ack, {:ignored, :invalid_event}}
        end

      {:error, _reason} ->
        {:ack, {:ignored, :invalid_reaction_event}}
    end
  end

  @doc false
  @spec options!(keyword() | map()) :: map()
  def options!(configuration) do
    configuration = normalize_configuration!(configuration)
    transport = Map.fetch!(configuration, :transport)
    reconnect_ms = Map.get(configuration, :reconnect_ms, 1_000)
    receive_timeout_ms = Map.get(configuration, :receive_timeout_ms, 45_000)

    unless transport?(transport),
      do: raise(ArgumentError, "Slack transport must implement SocketTransport")

    unless positive_timeout?(reconnect_ms),
      do: raise(ArgumentError, "Slack reconnect_ms must be a positive integer")

    unless positive_timeout?(receive_timeout_ms),
      do: raise(ArgumentError, "Slack receive_timeout_ms must be a positive integer")

    %{
      handler_settings: Map.fetch!(configuration, :handler_settings),
      name: Map.get(configuration, :name),
      receive_timeout_ms: receive_timeout_ms,
      reconnect_ms: reconnect_ms,
      transport: transport,
      transport_options: Map.fetch!(configuration, :transport_options)
    }
  end

  defp handle_event(normalized, settings) do
    with {:ok, true} <- actor_allowed(normalized.input.actor, settings),
         {:ok, true} <- conversation_actor_allowed(normalized.input, settings) do
      case setup_message(normalized, settings) do
        {:ok, %{outcome: outcome}} -> {:ack, {:configuration, outcome}}
        :not_setup -> handle_ingress_event(normalized, settings)
        {:error, reason} -> {:retry, reason}
      end
    else
      {:ok, false} -> {:ack, {:ignored, :actor_not_authorized}}
      {:error, reason} -> {:retry, reason}
    end
  end

  defp handle_reaction(reaction, settings) do
    with {:ok, true} <- actor_allowed(%{kind: :user, ref: reaction.actor_ref}, settings),
         callback when is_function(callback, 1) <- Map.get(settings, :reaction_feedback) do
      case callback.(reaction) do
        {:ok, %{status: status}} when status in [:applied, :duplicate] ->
          {:ack, {:reaction, status}}

        {:error, :conversation_reaction_target_not_found} ->
          {:ack, {:ignored, :reaction_target_not_found}}

        {:error, reason} ->
          {:retry, reason}

        _invalid ->
          {:retry, :slack_reaction_feedback_invalid}
      end
    else
      {:ok, false} -> {:ack, {:ignored, :actor_not_authorized}}
      {:error, reason} -> {:retry, reason}
      _missing -> {:retry, :slack_reaction_feedback_unavailable}
    end
  end

  defp handle_ingress_event(normalized, settings) do
    case engagement_mode(normalized, settings) do
      {:ok, execution_mode, receipt} ->
        record_ingress(
          Map.put(normalized, :engagement_receipt, receipt),
          execution_mode,
          settings
        )

      {:engaged, false} ->
        {:ack, {:ignored, :not_engaged}}

      {:error, reason} ->
        {:retry, reason}
    end
  end

  defp handle_message_interaction(envelope, now, settings) do
    case Interaction.from_socket(envelope, settings.identity.workspace_ref, now) do
      {:ok, interaction} -> handle_interaction(interaction, settings)
      :ignore -> handle_shortcut_envelope(envelope, now, settings)
    end
  end

  defp handle_shortcut_envelope(envelope, now, settings) do
    case Shortcut.from_socket(envelope, settings.identity.workspace_ref, now) do
      {:ok, normalized} -> handle_shortcut(normalized, settings)
      :ignore -> {:ack, {:ignored, :unsupported_interaction}}
      {:error, _reason} -> {:ack, {:ignored, :invalid_shortcut}}
    end
  end

  defp handle_shortcut(normalized, settings) do
    with {:ok, true} <- actor_allowed(normalized.input.actor, settings),
         {:ok, true} <- conversation_actor_allowed(normalized.input, settings) do
      # An explicit shortcut bypasses the ordinary engagement gate entirely; the
      # receipt says so rather than claiming channel settings were applied.
      receipt = %{
        "version" => 1,
        "path" => "slack_shortcut",
        "result" => "process",
        "reason" => "Explicitly submitted through a Slack shortcut.",
        "checks" => [],
        "settings" => nil,
        "execution_mode" => "live"
      }

      record_ingress(Map.put(normalized, :engagement_receipt, receipt), :live, settings)
    else
      {:ok, false} -> {:ack, {:ignored, :actor_not_authorized}}
      {:error, reason} -> {:retry, reason}
    end
  end

  defp record_ingress(normalized, execution_mode, settings) do
    with {:ok, enriched} <- ingest_attachments(normalized, settings),
         {:ok, work_profile} <- work_profile(enriched.input, settings),
         {:ok, receipt} <-
           settings.inbox.record(enriched.input,
             execution_mode: execution_mode,
             slack_audience: normalized.audience,
             slack_bot_user_ref: settings.identity.bot_user_ref,
             source_envelope: normalized[:source_envelope],
             engagement_receipt: normalized[:engagement_receipt],
             work_profile: work_profile
           ),
         :ok <- remember_action_token(enriched, settings) do
      {:ack, {receipt.status, Inbox.ref(receipt.entry)}}
    else
      {:error, {:input_conflict, _details}} -> {:ack, {:ignored, :event_conflict}}
      {:error, reason} -> {:retry, reason}
    end
  end

  defp remember_action_token(%{action_token: nil}, _settings), do: :ok

  defp remember_action_token(%{action_token: token, input: input}, settings)
       when is_binary(token) do
    case Map.get(settings, :action_tokens) do
      callback when is_function(callback, 2) -> callback.(input.event_ref, token)
      _unconfigured -> :ok
    end
  end

  defp work_profile(input, settings) do
    case Map.get(settings, :work_profile) do
      callback when is_function(callback, 2) ->
        case callback.(input.source.ref, input.destination.conversation_ref) do
          {:ok, profile} when is_map(profile) -> {:ok, profile}
          {:error, _reason} = error -> error
          _invalid -> {:error, {:invalid_slack_settings, :work_profile}}
        end

      _none ->
        {:ok, nil}
    end
  end

  defp handle_membership(transition, settings) do
    case incident_lifecycle(transition, settings) do
      {:ok, %{status: :not_incident_room}} -> handle_setup_membership(transition, settings)
      {:ok, %{status: status}} -> {:ack, {:incident_room, status}}
      :not_configured -> handle_setup_membership(transition, settings)
      {:error, reason} -> {:retry, reason}
    end
  end

  defp incident_lifecycle(transition, settings) do
    case Map.get(settings, :incident_lifecycle) do
      callback when is_function(callback, 1) -> callback.(transition)
      _missing -> :not_configured
    end
  end

  defp handle_setup_membership(%{kind: kind}, _settings)
       when kind in [:archived, :unarchived],
       do: {:ack, {:ignored, :unmanaged_channel_lifecycle}}

  defp handle_setup_membership(transition, settings) do
    case {Map.get(settings, :setup_handler), Map.get(settings, :setup_options)} do
      {handler, options} when is_atom(handler) and is_map(options) ->
        case handler.handle_membership(transition, options) do
          {:ok, %{status: status}} -> {:ack, {:membership, status}}
          {:error, reason} -> {:retry, reason}
        end

      _missing ->
        {:retry, :slack_setup_unavailable}
    end
  end

  defp setup_message(normalized, settings) do
    case setup_allowed(normalized.input, settings) do
      {:ok, true} ->
        case {Map.get(settings, :setup_handler), Map.get(settings, :setup_options)} do
          {handler, options} when is_atom(handler) and is_map(options) ->
            handler.handle_message(normalized, options)

          _missing ->
            :not_setup
        end

      {:ok, false} ->
        :not_setup

      {:error, _reason} = error ->
        error
    end
  end

  defp setup_allowed(input, settings) do
    case Map.get(settings, :setup_allowed) do
      callback when is_function(callback, 2) ->
        case callback.(input.source.ref, input.destination.conversation_ref) do
          {:ok, allowed} when is_boolean(allowed) -> {:ok, allowed}
          {:error, _reason} = error -> error
          _invalid -> {:error, {:invalid_slack_settings, :setup_allowed}}
        end

      _missing ->
        {:ok, true}
    end
  end

  defp ingest_attachments(%{input: %{content: %{"files" => []}}} = normalized, _settings),
    do: {:ok, normalized}

  defp ingest_attachments(normalized, settings) do
    with ingestor when is_atom(ingestor) <- Map.get(settings, :attachment_ingestor),
         options when is_map(options) <- Map.get(settings, :attachment_options) do
      ingestor.ingest(normalized, options)
    else
      _missing -> {:error, :slack_attachment_ingestor_unavailable}
    end
  end

  defp handle_interaction(interaction, settings) do
    case settings.interaction_handler.handle(interaction, settings.interaction_options) do
      {:ok, %{outcome: :selection_required}} ->
        {:ack, {:interaction, :selection_required}, interaction_feedback(:selection_required)}

      {:ok, %{outcome: outcome}} when outcome in [:denied, :invalid] ->
        acknowledge_interaction(interaction, outcome, outcome, settings)

      {:ok, %{outcome: outcome}}
      when outcome in [:confirmed, :duplicate] and
             interaction.action_id in ~w(responder_confirm_behavior responder_confirm_memory responder_confirm_schedule responder_confirm_automation) ->
        # Normalize duplicate delivery to the original confirmation outcome so
        # a crash between commit and acknowledgement retains one repaint intent.
        acknowledge_interaction(interaction, outcome, :confirmed, settings)

      {:ok, %{outcome: outcome}}
      when outcome in [:deleted, :forgotten] and
             interaction.action_id in ~w(responder_delete_schedule responder_delete_behavior responder_forget_memory) ->
        # The saved-entity message repaints to its removed state with no controls.
        acknowledge_interaction(interaction, outcome, :confirmed, settings)

      {:ok, %{outcome: outcome}} ->
        {:ack, {:interaction, outcome}}

      {:error, reason} ->
        {:retry, reason}
    end
  end

  defp acknowledge_interaction(interaction, outcome, audit_outcome, settings) do
    case audit_interaction(interaction, audit_outcome, settings) do
      {:ok, _audit} ->
        {:ack, {:interaction, outcome}, interaction_feedback(audit_outcome)}

      {:error, reason} ->
        {:retry, reason}
    end
  end

  defp audit_interaction(interaction, outcome, settings) do
    case Map.get(settings, :interaction_audit) do
      callback when is_function(callback, 2) -> callback.(interaction, outcome)
      _missing -> {:error, :slack_interaction_audit_unavailable}
    end
  end

  defp interaction_feedback(:selection_required) do
    %{
      "response_type" => "ephemeral",
      "text" => "Choose an option first, then select Submit answer."
    }
  end

  defp interaction_feedback(:denied) do
    %{
      "response_type" => "ephemeral",
      "text" => "You don't have permission to use that Responder control."
    }
  end

  defp interaction_feedback(:invalid) do
    %{
      "response_type" => "ephemeral",
      "text" => "That control is no longer current. Use the refreshed message instead."
    }
  end

  defp interaction_feedback(:confirmed) do
    %{
      "response_type" => "ephemeral",
      "text" => "Your confirmation is saved. The message is being updated."
    }
  end

  defp handle_home(event, settings) do
    case {Map.get(settings, :home_handler), Map.get(settings, :home_options)} do
      {handler, options} when is_atom(handler) and is_map(options) ->
        case handler.handle(event, options) do
          {:ok, %{outcome: outcome}} -> {:ack, {:app_home, outcome}}
          {:error, reason} -> {:retry, reason}
        end

      _missing ->
        {:ack, {:ignored, :app_home_unavailable}}
    end
  end

  defp handle_home_interaction(interaction, settings) do
    case {Map.get(settings, :home_interaction_handler),
          Map.get(settings, :home_interaction_options)} do
      {handler, options} when is_atom(handler) and is_map(options) ->
        case handler.handle(interaction, options) do
          {:ok, %{outcome: outcome}} -> {:ack, {:app_home_control, outcome}}
          {:error, reason} -> {:retry, reason}
        end

      _missing ->
        {:ack, {:ignored, :app_home_controls_unavailable}}
    end
  end

  defp handle_command(command, settings) do
    case settings.command_handler.handle(command, settings.command_options) do
      {:ok, %{} = payload} -> {:ack, {:command, :handled}, payload}
      {:error, reason} -> {:retry, reason}
    end
  end

  defp actor_allowed(%{kind: :user, ref: actor_ref}, settings) do
    settings.directory.user_allowed(
      settings.client,
      actor_ref,
      settings.identity.workspace_ref
    )
  end

  defp actor_allowed(%{kind: kind}, _settings) when kind in [:app, :bot], do: {:ok, true}
  defp actor_allowed(_actor, _settings), do: {:ok, false}

  defp conversation_actor_allowed(input, settings) do
    case Map.get(settings, :conversation_actor_allowed) do
      callback when is_function(callback, 1) -> callback.(input)
      _missing -> {:ok, true}
    end
  end

  # The gate is a short-circuiting disjunction, and the receipt records exactly
  # that: each predicate is evaluated in the same order and only as far as the
  # decision needs, and a predicate the gate never reached is recorded as
  # "not checked" rather than as a "no" nobody established.
  defp engagement_mode(%{input: input} = normalized, settings) do
    with {:ok, channel_settings} <- effective_channel_settings(input, settings) do
      {engaged, checks} = engagement_checks(normalized, channel_settings, settings)

      cond do
        not engaged ->
          {:engaged, false}

        channel_settings.shadow ->
          {:ok, :shadow, engagement_receipt(checks, channel_settings, :shadow)}

        true ->
          {:ok, :live, engagement_receipt(checks, channel_settings, :live)}
      end
    end
  end

  defp engagement_checks(%{audience: audience} = normalized, channel_settings, settings) do
    cond do
      audience in [:direct, :mention] -> {true, [{"direct_or_mention", "yes"}]}
      audience != :ambient -> {false, [{"direct_or_mention", "no"}]}
      true -> ambient_checks(normalized, channel_settings, settings)
    end
  end

  defp ambient_checks(normalized, channel_settings, settings) do
    checks = [{"direct_or_mention", "no"}]

    cond do
      continuation?(normalized, settings) ->
        {true, checks ++ [{"existing_episode_thread", "yes"}]}

      standing_match?(normalized.input, settings) ->
        {true, checks ++ [{"existing_episode_thread", "no"}, {"standing_rule", "matched"}]}

      true ->
        {channel_settings.proactive or channel_settings.shadow,
         checks ++
           [
             {"existing_episode_thread", "no"},
             {"standing_rule", "not_matched"},
             {"proactive_participation", on_off(channel_settings.proactive)},
             {"shadow_evaluation", on_off(channel_settings.shadow)}
           ]}
    end
  end

  defp on_off(true), do: "on"
  defp on_off(_value), do: "off"

  defp engagement_receipt(checks, channel_settings, execution_mode) do
    %{
      "version" => 1,
      "path" => "slack_event",
      "result" => if(execution_mode == :shadow, do: "evaluate_only", else: "process"),
      "reason" => engagement_reason(checks, execution_mode),
      "checks" =>
        Enum.map(checks, fn {check, outcome} -> %{"check" => check, "outcome" => outcome} end),
      "settings" => %{
        "proactive" => setting_document(channel_settings.proactive_setting),
        "shadow" => setting_document(channel_settings.shadow_setting)
      },
      "execution_mode" => Atom.to_string(execution_mode)
    }
  end

  defp engagement_reason(checks, :shadow) do
    "Shadow mode is enabled for this channel; " <>
      String.downcase(engagement_reason(checks, :live))
  end

  defp engagement_reason(checks, _mode) do
    case List.last(checks) do
      {"direct_or_mention", "yes"} -> "Responder was mentioned in or sent this message."
      {"existing_episode_thread", "yes"} -> "The message is in a thread with existing work."
      {"standing_rule", "matched"} -> "A standing rule matched this message."
      {"shadow_evaluation", _} -> "Ambient participation is enabled for this channel."
      _other -> "The engagement gate admitted this message."
    end
  end

  defp setting_document(%{value: value, source: source}),
    do: %{"value" => value, "source" => Atom.to_string(source)}

  defp setting_document(_setting), do: nil

  defp effective_channel_settings(input, settings) do
    fallback =
      MapSet.member?(settings.watch_channels, slack_channel(input.destination.conversation_ref))

    case Map.get(settings, :effective_settings) do
      callback when is_function(callback, 2) ->
        case callback.(input.source.ref, input.destination.conversation_ref) do
          %{
            proactive: %{value: proactive} = proactive_setting,
            shadow: %{value: shadow} = shadow_setting
          }
          when is_boolean(proactive) and is_boolean(shadow) ->
            {:ok,
             %{
               proactive: proactive,
               shadow: shadow,
               proactive_setting: setting_source(proactive_setting),
               shadow_setting: setting_source(shadow_setting)
             }}

          {:error, _reason} = error ->
            error

          _invalid ->
            {:error, {:invalid_slack_settings, :effective}}
        end

      _none ->
        {:ok,
         %{
           proactive: fallback,
           shadow: false,
           proactive_setting: %{value: fallback, source: :watch_channels},
           shadow_setting: %{value: false, source: :deployment}
         }}
    end
  end

  defp setting_source(%{value: value, source: source}) when is_atom(source),
    do: %{value: value, source: source}

  defp setting_source(%{value: value}), do: %{value: value, source: :not_recorded}

  defp continuation?(normalized, settings) do
    case Map.get(settings, :continuation) do
      callback when is_function(callback, 1) -> callback.(normalized)
      _none -> false
    end
  end

  defp standing_match?(input, settings) do
    case Map.get(settings, :standing_matcher) do
      callback when is_function(callback, 1) -> callback.(input)
      _none -> false
    end
  end

  defp slack_channel(conversation_ref) do
    case String.split(conversation_ref, ":", parts: 3) do
      ["slack", _workspace_ref, channel_ref] -> channel_ref
      _invalid -> ""
    end
  end

  defp database_now do
    case Responder.Repo.query("SELECT clock_timestamp()") do
      {:ok, %{rows: [[%DateTime{} = now]]}} -> now
      _failure -> DateTime.utc_now()
    end
  end

  defp process_frames([], state), do: {:ok, state}

  defp process_frames([{:text, payload} | frames], state) do
    case process_text(payload, state) do
      {:ok, state} -> process_frames(frames, state)
      {:reconnect, state} -> {:reconnect, state}
    end
  end

  defp process_frames([{:ping, payload} | frames], state) do
    case send_frame(state, {:pong, payload}) do
      {:ok, state} -> process_frames(frames, state)
      {:error, state} -> {:reconnect, state}
    end
  end

  defp process_frames([{:pong, _payload} | frames], state), do: process_frames(frames, state)

  defp process_frames([{:close, _code, _reason} | _frames], state),
    do: {:reconnect, state}

  defp process_frames([{:binary, _payload} | _frames], state), do: {:reconnect, state}
  defp process_frames([_invalid | _frames], state), do: {:reconnect, state}

  defp process_text(payload, state)
       when is_binary(payload) and byte_size(payload) <= @maximum_envelope_bytes do
    case Jason.decode(payload) do
      {:ok, %{"type" => "disconnect"}} ->
        {:reconnect, state}

      {:ok, %{} = envelope} ->
        acknowledge(envelope, handle_envelope(envelope, state.handler_settings), state)

      {:ok, _document} ->
        {:ok, state}

      {:error, _reason} ->
        {:ok, state}
    end
  end

  defp process_text(_payload, state), do: {:reconnect, state}

  defp acknowledge(%{"envelope_id" => _envelope_ref} = envelope, outcome, state)
       when elem(outcome, 0) == :ack do
    acknowledgement = acknowledgement(envelope, outcome) |> Jason.encode!()

    case send_frame(state, {:text, acknowledgement}) do
      {:ok, state} -> {:ok, state}
      {:error, state} -> {:reconnect, state}
    end
  end

  defp acknowledge(_envelope, _outcome, state), do: {:ok, state}

  @doc false
  def acknowledgement(
        %{"accepts_response_payload" => true, "envelope_id" => envelope_ref},
        {:ack, _outcome, %{} = payload}
      )
      when is_binary(envelope_ref) and envelope_ref != "" do
    %{"envelope_id" => envelope_ref, "payload" => payload}
  end

  def acknowledgement(%{"envelope_id" => envelope_ref}, {:ack, _outcome})
      when is_binary(envelope_ref) and envelope_ref != "" do
    %{"envelope_id" => envelope_ref}
  end

  def acknowledgement(%{"envelope_id" => envelope_ref}, {:ack, _outcome, _payload})
      when is_binary(envelope_ref) and envelope_ref != "" do
    %{"envelope_id" => envelope_ref}
  end

  def acknowledgement(_envelope, _outcome), do: %{}

  defp send_frame(state, frame) do
    case state.transport.send_frame(state.connection, frame) do
      {:ok, connection} ->
        {:ok, %{state | connection: connection}}

      {:error, reason} ->
        Logger.warning("Slack Socket Mode send failed: #{inspect(reason)}")
        {:error, state}
    end
  end

  defp reconnect(state) do
    if state.connection, do: state.transport.close(state.connection)

    state
    |> Map.put(:connection, nil)
    |> Map.put(:idle_ref, nil)
    |> schedule_reconnect()
  end

  defp schedule_reconnect(%{reconnect_scheduled: true} = state), do: state

  defp schedule_reconnect(state) do
    Process.send_after(self(), :connect, state.reconnect_ms)
    %{state | reconnect_scheduled: true}
  end

  defp arm_idle(state) do
    idle_ref = make_ref()
    Process.send_after(self(), {:socket_idle, idle_ref}, state.receive_timeout_ms)
    %{state | idle_ref: idle_ref}
  end

  defp normalize_configuration!(configuration) when is_list(configuration) do
    if Keyword.keyword?(configuration) and
         Enum.uniq(Keyword.keys(configuration)) == Keyword.keys(configuration) do
      configuration |> Map.new() |> normalize_configuration!()
    else
      raise ArgumentError, "Slack gateway configuration must use unique fields"
    end
  end

  defp normalize_configuration!(%{} = configuration) do
    keys = Map.keys(configuration)
    required = [:handler_settings, :transport, :transport_options]

    if keys -- @configuration_fields == [] and Enum.all?(required, &(&1 in keys)),
      do: configuration,
      else: raise(ArgumentError, "Slack gateway configuration has missing or unknown fields")
  end

  defp normalize_configuration!(_configuration) do
    raise ArgumentError, "Slack gateway configuration must be a map or keyword list"
  end

  defp transport?(transport) when is_atom(transport) do
    Code.ensure_loaded?(transport) and
      Enum.all?([{:connect, 1}, {:stream, 2}, {:send_frame, 2}, {:close, 1}], fn
        {name, arity} -> function_exported?(transport, name, arity)
      end)
  end

  defp transport?(_transport), do: false

  defp positive_timeout?(value), do: is_integer(value) and value > 0 and value <= 300_000
end
