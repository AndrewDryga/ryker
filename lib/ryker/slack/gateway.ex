defmodule Ryker.Slack.Gateway do
  @moduledoc """
  Durable acknowledgement boundary for Slack Socket Mode envelopes.

  An Events API envelope becomes acknowledgeable only after its normalized
  input is durable. A host control becomes acknowledgeable only after its
  authority-checked transition has completed. Transient failures deliberately
  leave the envelope unacknowledged for Slack to retry.

  Envelopes are handled one at a time, so nothing slow runs here: a voice
  message's recording is kept and its message recorded with the transcript
  pending, and `Ryker.Transcription.Worker` transcribes it after the
  acknowledgement.

  The connection coming up or going down is announced
  (`subscribe_connection/0`): it is process state, not a row, so no commit
  says it.
  """

  use GenServer

  @member_ttl_ms 5 * 60 * 1_000

  require Logger

  alias Ryker.Ingress.Inbox
  alias Ryker.Options

  alias Ryker.Slack.{
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

  # Controls whose confirmation repaints the message they sit on from saved
  # state, so its buttons go. An engineering task's offer is not here: its
  # message becomes the task card.
  @repainted_on_confirmation ~w(ryker_confirm_automation ryker_confirm_behavior ryker_confirm_memory ryker_confirm_schedule ryker_confirm_slack_post ryker_investigate_incident ryker_open_incident)

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

  @doc "Returns whether the named Socket Mode gateway currently has a live connection."
  @spec connected?(GenServer.server()) :: boolean()
  def connected?(server \\ __MODULE__) do
    GenServer.call(server, :connected?)
  catch
    :exit, _reason -> false
  end

  @impl GenServer
  def init(options) do
    send(self(), :connect)

    {:ok,
     Map.merge(options, %{
       connection: nil,
       connected_at_ms: nil,
       idle_ref: nil,
       reconnect_timer: nil,
       reconnect_failures: 0
     })}
  end

  @impl GenServer
  def handle_call(:connected?, _from, state), do: {:reply, not is_nil(state.connection), state}

  @impl GenServer
  # Every attempt clears the retry it came from, or one a direct `:connect`
  # overtook, so a failure always leaves exactly one retry waiting. Until
  # 2026-09-27 a retry that also failed scheduled nothing, and Slack stayed
  # disconnected until Ryker was restarted.
  def handle_info(:connect, %{connection: nil} = state) do
    state = cancel_reconnect(state)

    case state.transport.connect(state.transport_options) do
      {:ok, connection} ->
        if state.reconnect_failures > 0,
          do:
            Logger.info("Slack Socket Mode connected after #{state.reconnect_failures} failures")

        broadcast_connection_changed(true)

        {:noreply,
         state
         |> Map.put(:connection, connection)
         |> Map.put(:connected_at_ms, System.monotonic_time(:millisecond))
         |> arm_idle()}

      {:error, reason} ->
        Logger.warning("Slack Socket Mode connection failed: #{inspect(reason)}")

        {:noreply,
         state
         |> Map.update!(:reconnect_failures, &(&1 + 1))
         |> schedule_reconnect()}
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
    broadcast_connection_changed(false)
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
      :ignore -> handle_unsupported_command(envelope)
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
    with {:ok, true} <- author_allowed(normalized, settings),
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

  defp handle_unsupported_command(_envelope), do: {:ack, {:ignored, :unsupported_command}}

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
             one_input_per_revision: true,
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
        tell(interaction, :selection_required, settings)
        {:ack, {:interaction, :selection_required}}

      {:ok, %{outcome: outcome}}
      when outcome in [:denied, :invalid, :room_capacity, :task_not_here] ->
        refuse_interaction(interaction, outcome, settings)

      {:ok, %{outcome: outcome}}
      when outcome in [:confirmed, :duplicate, :requested] and
             interaction.action_id in @repainted_on_confirmation ->
        # Normalize duplicate delivery to the original confirmation outcome so
        # a crash between commit and acknowledgement retains one repaint intent.
        acknowledge_interaction(interaction, outcome, :confirmed, settings)

      {:ok, %{outcome: outcome}}
      when outcome in [:deleted, :forgotten, :resumed] and
             interaction.action_id in ~w(ryker_delete_schedule ryker_delete_behavior ryker_forget_memory ryker_resume_behavior) ->
        # The saved-entity message repaints from the entity's current state: a
        # removed one loses its controls, and a resumed one comes back active.
        acknowledge_interaction(interaction, outcome, :confirmed, settings)

      {:ok, %{outcome: outcome}} ->
        {:ack, {:interaction, outcome}}

      {:error, reason} ->
        {:retry, reason}
    end
  end

  # A refused control is audited as denied or invalid; a full set of incident
  # rooms, or a task this channel cannot start, is audited as invalid, but the
  # person hears which.
  defp refuse_interaction(interaction, outcome, settings) do
    audited = if outcome in [:room_capacity, :task_not_here], do: :invalid, else: outcome

    with {:ack, _result} = acknowledged <-
           acknowledge_interaction(interaction, outcome, audited, settings) do
      tell(interaction, outcome, settings)
      acknowledged
    end
  end

  defp acknowledge_interaction(interaction, outcome, audit_outcome, settings) do
    case audit_interaction(interaction, audit_outcome, settings) do
      {:ok, _audit} -> {:ack, {:interaction, outcome}}
      {:error, reason} -> {:retry, reason}
    end
  end

  # Slack shows nothing from the acknowledgement of a button press: a
  # block_actions envelope accepts no response payload, so every note on a
  # refused press went nowhere (2026-10-04 review). It is posted to the person
  # who pressed instead, beside the acknowledgement. A confirmation needs no
  # note: its message is repainted.
  defp tell(interaction, reason, settings) do
    case Map.get(settings, :interaction_feedback) do
      callback when is_function(callback, 2) -> callback.(interaction, feedback_text(reason))
      _missing -> :ok
    end
  end

  defp audit_interaction(interaction, outcome, settings) do
    case Map.get(settings, :interaction_audit) do
      callback when is_function(callback, 2) -> callback.(interaction, outcome)
      _missing -> {:error, :slack_interaction_audit_unavailable}
    end
  end

  defp feedback_text(:selection_required),
    do: "Choose an option first, then select Submit answer."

  defp feedback_text(:denied), do: "You don't have permission to use that Ryker control."

  defp feedback_text(:invalid),
    do: "That control is no longer current. Use the refreshed message instead."

  defp feedback_text(:room_capacity),
    do:
      "Ryker already has as many incident rooms open as it keeps. Close one whose " <>
        "incident is over on Ryker's Incident rooms page, then press again. An " <>
        "archived room keeps its place, since it can come back."

  defp feedback_text(:task_not_here),
    do:
      "Ryker can't start this task in this channel. " <>
        "Its environment doesn't let Ryker change that repository."

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

  # Whether someone may use Ryker is read from Slack at most once in five
  # minutes for each person. Read for every event and reaction, a busy channel
  # ran into users.info's rate limit, which delayed and then dropped the
  # events behind it. Envelopes are handled in the gateway's own process, so
  # its dictionary keeps the answers, each for the directory that gave it.
  defp actor_allowed(%{kind: :user, ref: actor_ref}, settings) do
    workspace_ref = settings.identity.workspace_ref
    key = {__MODULE__, :member, settings.directory, settings.client, workspace_ref, actor_ref}
    now = System.monotonic_time(:millisecond)

    case Process.get(key) do
      {allowed, read_at} when now - read_at < @member_ttl_ms ->
        {:ok, allowed}

      _unread_or_stale ->
        with {:ok, allowed} <-
               settings.directory.user_allowed(settings.client, actor_ref, workspace_ref) do
          # credo:disable-for-next-line Ryker.Checks.NoProcessDictionary
          Process.put(key, {allowed, now})
          {:ok, allowed}
        end
    end
  end

  defp actor_allowed(_actor, _settings), do: {:ok, false}

  # Apps and bots have no member to look up. Slack names the author's
  # workspace on messages from a shared channel, and an app another
  # organization runs there is not one of ours; one with no workspace named is
  # this workspace's own integration, such as an incoming webhook.
  defp author_allowed(%{input: %{actor: %{kind: kind}}} = normalized, settings)
       when kind in [:app, :bot] do
    event = Map.get(normalized, :source_envelope) || %{}

    profile_team =
      case event["bot_profile"] do
        %{"team_id" => team} -> team
        _none -> nil
      end

    teams = [event["team"], event["user_team"], event["source_team"], profile_team]
    {:ok, Enum.all?(teams, &(is_nil(&1) or &1 == settings.identity.workspace_ref))}
  end

  defp author_allowed(normalized, settings), do: actor_allowed(normalized.input.actor, settings)

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
      {"direct_or_mention", "yes"} -> "Ryker was mentioned in or sent this message."
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
        {:error, {:invalid_slack_settings, :effective}}
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

  defp database_now do
    case Ryker.Repo.query("SELECT clock_timestamp()") do
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

  defp process_frames([{:close, code, reason} | _frames], state) do
    Logger.info("Slack closed Socket Mode: #{inspect({code, reason})}")
    {:reconnect, state}
  end

  defp process_frames([{:binary, _payload} | _frames], state) do
    Logger.warning("Slack sent a binary Socket Mode frame; reconnecting")
    {:reconnect, state}
  end

  defp process_frames([invalid | _frames], state) do
    Logger.warning("Slack sent an unexpected Socket Mode frame: #{inspect(invalid, limit: 5)}")
    {:reconnect, state}
  end

  defp process_text(payload, state)
       when is_binary(payload) and byte_size(payload) <= @maximum_envelope_bytes do
    case Jason.decode(payload) do
      {:ok, %{"type" => "disconnect"} = envelope} ->
        # Slack says why: refresh_requested and warning are routine, while
        # link_disabled or too_many_websockets mean it will not stay up.
        Logger.info("Slack asked Socket Mode to disconnect: #{inspect(envelope["reason"])}")

        {:reconnect, state}

      {:ok, %{} = envelope} ->
        acknowledge(envelope, handle_envelope(envelope, state.handler_settings), state)

      {:ok, _document} ->
        {:ok, state}

      {:error, _reason} ->
        {:ok, state}
    end
  end

  defp process_text(_payload, state) do
    Logger.warning(
      "Slack sent a Socket Mode envelope over #{@maximum_envelope_bytes} bytes; reconnecting"
    )

    {:reconnect, state}
  end

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
    if state.connection do
      broadcast_connection_changed(false)
      state.transport.close(state.connection)
    end

    # A socket that disappears before one receive window has passed was not a
    # recovery. Slack can accept a connection and immediately reject it with
    # too_many_websockets; resetting on connect would retry forever at 1s.
    failures =
      if System.monotonic_time(:millisecond) - state.connected_at_ms >=
           state.receive_timeout_ms,
         do: 0,
         else: state.reconnect_failures + 1

    state
    |> Map.put(:connection, nil)
    |> Map.put(:connected_at_ms, nil)
    |> Map.put(:idle_ref, nil)
    |> Map.put(:reconnect_failures, failures)
    |> schedule_reconnect()
  end

  @maximum_reconnect_ms 60_000

  # One retry waits at a time. Repeated failures wait twice as long each time,
  # up to a minute, so an app token Slack keeps refusing is not asked every
  # second.
  defp schedule_reconnect(%{reconnect_timer: timer} = state) when is_reference(timer), do: state

  defp schedule_reconnect(state) do
    doublings = min(max(state.reconnect_failures - 1, 0), 16)
    delay = min(state.reconnect_ms * Integer.pow(2, doublings), @maximum_reconnect_ms)
    %{state | reconnect_timer: Process.send_after(self(), :connect, delay)}
  end

  defp cancel_reconnect(%{reconnect_timer: timer} = state) when is_reference(timer) do
    _remaining = Process.cancel_timer(timer)
    %{state | reconnect_timer: nil}
  end

  defp cancel_reconnect(state), do: state

  defp arm_idle(state) do
    idle_ref = make_ref()
    Process.send_after(self(), {:socket_idle, idle_ref}, state.receive_timeout_ms)
    %{state | idle_ref: idle_ref}
  end

  defp normalize_configuration!(configuration) do
    Options.normalize!(
      configuration,
      @configuration_fields,
      [:handler_settings, :transport, :transport_options],
      list: "Slack gateway configuration must use unique fields",
      map: "Slack gateway configuration has missing or unknown fields",
      other: "Slack gateway configuration must be a map or keyword list"
    )
  end

  defp transport?(transport) when is_atom(transport) do
    Code.ensure_loaded?(transport) and
      Enum.all?([{:connect, 1}, {:stream, 2}, {:send_frame, 2}, {:close, 1}], fn
        {name, arity} -> function_exported?(transport, name, arity)
      end)
  end

  defp transport?(_transport), do: false

  defp positive_timeout?(value), do: is_integer(value) and value > 0 and value <= 300_000

  # -- PubSub ------------------------------------------------------------------

  @doc """
  Subscribes the caller to the Socket Mode connection:
  `{:slack_connection_changed, connected?}` once it comes up or goes down.
  """
  def subscribe_connection, do: Ryker.PubSub.subscribe(connection_topic())

  def unsubscribe_connection, do: Ryker.PubSub.unsubscribe(connection_topic())

  defp connection_topic, do: "slack:connection"

  defp broadcast_connection_changed(connected?),
    do: Ryker.PubSub.broadcast(connection_topic(), {:slack_connection_changed, connected?})
end
