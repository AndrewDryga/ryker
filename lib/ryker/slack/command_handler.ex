defmodule Ryker.Slack.CommandHandler do
  @moduledoc """
  Deterministic no-model recovery commands for Slack operators.

  This deliberately stays small. Product creation remains conversational and
  confirmation-backed; slash commands can inspect, quiet, shadow, or revoke.
  """
  alias Ryker.ConversationRef
  alias Ryker.Slack.{Command, Operators, Renderer}

  @sources [:channel, :incident_room, :installation]

  @spec handle(Command.t(), map()) :: {:ok, map()} | {:error, term()}
  def handle(%Command{} = command, options) when is_map(options) do
    with :ok <- configured_operator(command, options),
         {:ok, true} <- member(command, options) do
      dispatch(command, options)
    else
      {:error, :operator_required} ->
        {:ok, response("Only a configured Ryker operator can use `/ryker`.")}

      {:ok, false} ->
        {:ok, response("Commands require an active full workspace member.")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle(_command, _options), do: {:error, {:invalid_slack_command, :input}}

  defp dispatch(%Command{text: text} = command, options) do
    fields = text |> String.downcase() |> String.split(~r/\s+/, trim: true)

    case fields do
      [] ->
        {:ok, response(help())}

      ["help"] ->
        {:ok, response(help())}

      ["status"] ->
        status(command, options)

      ["proactive" | arguments] ->
        change_setting(command, :proactive, arguments, options)

      ["shadow" | arguments] ->
        change_setting(command, :shadow, arguments, options)

      ["assignments" | _arguments] ->
        assignments(command, assignment_arguments(text), options)

      [name | _arguments] ->
        {:ok, response("Unknown `/ryker` subcommand `#{name}`.\n\n#{help()}")}
    end
  end

  defp change_setting(command, setting, arguments, options) do
    with {:ok, scope, value} <- setting_arguments(arguments),
         {:ok, _change} <-
           options.change_setting.(%{
             actor_ref: command.actor_ref,
             conversation_ref: ConversationRef.slack(command),
             event_ref: command.event_ref,
             occurred_at: command.occurred_at,
             scope: scope,
             setting: setting,
             value: value,
             workspace_ref: command.workspace_ref
           }),
         {:ok, effective} <- effective(command, options) do
      source = effective[setting].source

      {:ok,
       response(
         "#{label(setting)}: #{on_off(effective[setting].value)} (#{source_name(source)}). " <>
           "`inherit` follows the installation default again; `/ryker status` explains both settings."
       )}
    else
      {:error, :usage} -> {:ok, response(setting_usage(setting))}
      {:error, reason} -> {:error, reason}
    end
  end

  # `/ryker status` is the private form of the structured settings view
  # the welcome and conversational settings questions share. Reading never
  # mutates: the view is rendered from the effective saved settings only.
  defp status(command, options) do
    with {:ok, settings} <- settings_view(command, options),
         {:ok, rendered} <-
           Renderer.render(%{
             "channel_settings" => %{
               "audience" => "private",
               "bot_user_ref" => options.bot_user_ref,
               "configuration_ref" => settings["configuration_ref"],
               "revision" => settings["revision"],
               "settings" => settings
             }
           }) do
      {:ok, Map.put(rendered, "response_type", "ephemeral")}
    end
  end

  defp settings_view(command, options) do
    case options.settings_view.(command.workspace_ref, command.channel_ref) do
      {:ok, %{} = settings} -> {:ok, settings}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, {:invalid_slack_command, :settings}}
    end
  end

  defp assignments(command, [], options), do: list_assignments(command, options)
  defp assignments(command, ["list"], options), do: list_assignments(command, options)

  defp assignments(_command, ["create" | _rest], _options) do
    {:ok,
     response(
       "Ask for the standing assignment in ordinary language. Ryker will show its normalized read-only bounds for explicit confirmation."
     )}
  end

  defp assignments(command, [verb, ref], options) when verb in ["pause", "resume", "delete"] do
    status = %{"pause" => :disabled, "resume" => :active, "delete" => :deleted}[verb]

    scope = %{
      conversation_ref: ConversationRef.slack(command),
      workspace_ref: command.workspace_ref
    }

    case options.manage_assignment.(ref, status, scope) do
      {:ok, _assignment} ->
        {:ok, response("#{assignment_verb(verb)} `#{ref}`.")}

      {:error, reason}
      when reason in [:behavior_not_found, :behavior_terminal, :assignment_scope_mismatch] ->
        {:ok, response("That standing assignment is not active in this channel.")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp assignments(_command, _arguments, _options),
    do: {:ok, response(assignments_usage())}

  defp list_assignments(command, options) do
    assignments = options.list_assignments.(command.workspace_ref, ConversationRef.slack(command))

    lines =
      case assignments do
        [] ->
          ["No standing assignments are configured in this channel."]

        values when is_list(values) ->
          Enum.map(values, fn assignment ->
            ref = Map.fetch!(assignment, :ref)
            status = Map.fetch!(assignment, :status)
            title = assignment |> Map.fetch!(:payload) |> Map.fetch!("title")
            "- `#{ref}`: #{title} (#{status})"
          end)
      end

    {:ok, response(Enum.join(["Standing assignments" | lines], "\n"))}
  end

  defp effective(command, options) do
    case options.effective_settings.(command.workspace_ref, ConversationRef.slack(command)) do
      %{proactive: %{source: source1, value: value1}, shadow: %{source: source2, value: value2}} =
          settings
      when source1 in @sources and source2 in @sources and is_boolean(value1) and
             is_boolean(value2) ->
        {:ok, settings}

      {:error, reason} ->
        {:error, reason}

      _invalid ->
        {:error, {:invalid_slack_command, :settings}}
    end
  end

  defp configured_operator(command, options) do
    if Operators.operator?(options.operators, command.actor_ref),
      do: :ok,
      else: {:error, :operator_required}
  end

  defp member(command, options),
    do: options.directory.user_allowed(options.client, command.actor_ref, command.workspace_ref)

  defp setting_arguments([value]) when value in ["on", "off", "inherit"],
    do: {:ok, :channel, String.to_existing_atom(value)}

  # The workspace default has no default above it to follow, and "global
  # inherit" saved it as off (2026-10-04 review).
  defp setting_arguments(["global", value]) when value in ["on", "off"],
    do: {:ok, :workspace, String.to_existing_atom(value)}

  defp setting_arguments(_arguments), do: {:error, :usage}

  # A verb is read whatever its case, as every other `/ryker` word is; a
  # reference keeps its own (2026-10-04 review: "Pause" was unknown).
  defp assignment_arguments(text) do
    text
    |> String.trim()
    |> String.split(~r/\s+/, parts: 2, trim: true)
    |> case do
      [_command, arguments] ->
        case String.split(arguments, ~r/\s+/, trim: true) do
          [verb | rest] -> [String.downcase(verb) | rest]
          [] -> []
        end

      [_command] ->
        []

      [] ->
        []
    end
  end

  defp response(text), do: %{"response_type" => "ephemeral", "text" => String.trim(text)}

  defp label(:proactive), do: "Proactive"
  defp label(:shadow), do: "Shadow"
  defp on_off(true), do: "on"
  defp on_off(false), do: "off"
  defp source_name(:channel), do: "saved for this channel"
  defp source_name(:incident_room), do: "incident room"
  defp source_name(:installation), do: "installation default"
  defp assignment_verb("pause"), do: "Paused"
  defp assignment_verb("resume"), do: "Resumed"
  defp assignment_verb("delete"), do: "Deleted"

  defp setting_usage(setting) do
    "Use `/ryker #{setting} on|off|inherit` for this channel or `/ryker #{setting} global on|off` for the workspace."
  end

  defp assignments_usage do
    "Use `/ryker assignments`, or `pause|resume|delete <assignment-ref>`. Creation is conversational and confirmation-backed."
  end

  # In the words the channel setup card uses for the same choices.
  defp help do
    """
    *Ryker commands*
    `/ryker status`: what I do in this channel, and why
    `/ryker proactive on|off|inherit`: join conversations here when I think you could use my help
    `/ryker proactive global on|off`: the same for every channel
    `/ryker shadow on|off|inherit`: observe only here, without replying
    `/ryker shadow global on|off`: the same for every channel
    `/ryker assignments [list|pause|resume|delete]`: your standing rules

    For anything else, ask me in a message: tasks, schedules, things to remember, preferences and rules. I'll say what I'll do, and nothing changes until you confirm.
    """
  end
end
