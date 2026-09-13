defmodule Ryker.Slack.CommandHandler do
  @moduledoc """
  Deterministic no-model recovery commands for Slack operators.

  This deliberately stays small. Product creation remains conversational and
  confirmation-backed; slash commands can inspect, quiet, shadow, or revoke.
  """

  alias Ryker.Slack.{Command, Renderer}

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

      {:error, _reason} = error ->
        error
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

      [name] when name in ["status", "settings", "config"] ->
        status(command, options)

      [name | arguments] when name in ["proactive", "watch"] ->
        change_setting(command, :proactive, arguments, options)

      ["shadow" | arguments] ->
        change_setting(command, :shadow, arguments, options)

      [name | _arguments] when name in ["assignments", "assignment"] ->
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
             conversation_ref: conversation_ref(command),
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
      {:error, _reason} = error -> error
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
      {:error, _reason} = error -> error
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
      conversation_ref: conversation_ref(command),
      workspace_ref: command.workspace_ref
    }

    case options.manage_assignment.(ref, status, scope) do
      {:ok, _assignment} ->
        {:ok, response("#{assignment_verb(verb)} `#{ref}`.")}

      {:error, reason}
      when reason in [:behavior_not_found, :behavior_terminal, :assignment_scope_mismatch] ->
        {:ok, response("That standing assignment is not active in this channel.")}

      {:error, _reason} = error ->
        error
    end
  end

  defp assignments(_command, _arguments, _options),
    do: {:ok, response(assignments_usage())}

  defp list_assignments(command, options) do
    assignments = options.list_assignments.(command.workspace_ref, conversation_ref(command))

    lines =
      case assignments do
        [] ->
          ["No standing assignments are configured in this channel."]

        values when is_list(values) ->
          Enum.map(values, fn assignment ->
            ref = Map.fetch!(assignment, :ref)
            status = Map.fetch!(assignment, :status)
            action = assignment |> Map.fetch!(:payload) |> Map.fetch!("action")
            "- `#{ref}` — #{action} (#{status})"
          end)
      end

    {:ok, response(Enum.join(["Standing assignments" | lines], "\n"))}
  end

  defp effective(command, options) do
    case options.effective_settings.(command.workspace_ref, conversation_ref(command)) do
      %{proactive: %{source: source1, value: value1}, shadow: %{source: source2, value: value2}} =
          settings
      when source1 in @sources and source2 in @sources and is_boolean(value1) and
             is_boolean(value2) ->
        {:ok, settings}

      {:error, _reason} = error ->
        error

      _invalid ->
        {:error, {:invalid_slack_command, :settings}}
    end
  end

  defp configured_operator(command, options) do
    if match?(%MapSet{}, options.operators) and
         MapSet.member?(options.operators, command.actor_ref),
       do: :ok,
       else: {:error, :operator_required}
  end

  defp member(command, options),
    do: options.directory.user_allowed(options.client, command.actor_ref, command.workspace_ref)

  defp setting_arguments([value]) when value in ["on", "off", "inherit"],
    do: {:ok, :channel, String.to_existing_atom(value)}

  defp setting_arguments(["global", value]) when value in ["on", "off", "inherit"],
    do: {:ok, :workspace, String.to_existing_atom(value)}

  defp setting_arguments(_arguments), do: {:error, :usage}

  defp assignment_arguments(text) do
    text
    |> String.trim()
    |> String.split(~r/\s+/, parts: 2, trim: true)
    |> case do
      [_command, arguments] -> String.split(arguments, ~r/\s+/, trim: true)
      [_command] -> []
      [] -> []
    end
  end

  defp conversation_ref(command),
    do: "slack:#{command.workspace_ref}:#{command.channel_ref}"

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

  defp setting_usage(setting),
    do:
      "Use `/ryker #{setting} on|off|inherit` for this channel or `/ryker #{setting} global on|off|inherit` for the workspace."

  defp assignments_usage,
    do:
      "Use `/ryker assignments`, or `pause|resume|delete <assignment-ref>`. Creation is conversational and confirmation-backed."

  defp help do
    """
    Ryker emergency kit
    `/ryker status`
    `/ryker proactive on|off|inherit`
    `/ryker proactive global on|off|inherit`
    `/ryker shadow on|off|inherit`
    `/ryker shadow global on|off|inherit`
    `/ryker assignments [list|pause|resume|delete]`

    These commands use no model or Coop session. Create tasks, schedules, memory, preferences, guidance, and assignments conversationally, then confirm the exact host-rendered offer.
    """
  end
end
