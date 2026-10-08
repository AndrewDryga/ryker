defmodule Ryker.Slack do
  @moduledoc """
  What the console and other contexts ask of the Slack context: the names
  Slack references read as, links into Slack, whether a value is a Slack id or
  message timestamp, the words and marks of a task card's phases, and the
  channel settings a person changes from a channel's page. Each forwards to
  the module that owns it (`Ryker.Slack.Names`, `Ryker.Slack.Permalink`,
  `Ryker.Slack.Id`, `Ryker.Slack.Timestamp`, `Ryker.Slack.TaskCardDetails`,
  `Ryker.Slack.ChannelConfigurations`), so the console never reaches below
  this one (`Ryker.Checks.WebNoNestedDomainCalls`).
  """
  alias Ryker.Slack.{ChannelConfigurations, Id, Names, Permalink, TaskCardDetails, Timestamp}

  @doc "A Slack reference's name in `workspace`, or a description of it when no name is known."
  @spec name(String.t(), String.t()) :: String.t()
  defdelegate name(workspace, ref), to: Names

  @doc "A person's name and profile link in `workspace`; see `Ryker.Slack.Names.person/2`."
  defdelegate person(workspace, ref), to: Names

  @doc "Whether `ref` is a Slack person's reference."
  @spec person_ref?(term()) :: boolean()
  defdelegate person_ref?(ref), to: Names

  @doc "A destination (`slack:<workspace>:<channel>[:<thread>]`) in words."
  @spec destination_name(String.t()) :: String.t()
  defdelegate destination_name(destination), to: Names, as: :destination

  @doc "Whether a destination resolved to a real Slack name."
  @spec named_destination?(term()) :: boolean()
  defdelegate named_destination?(destination), to: Names, as: :named?

  @doc "The workspace a Slack destination is in, or nil for any other destination."
  @spec destination_workspace(term()) :: String.t() | nil
  defdelegate destination_workspace(destination), to: Names, as: :workspace_from_destination

  @doc "Slack's link to a channel or a person; see `Ryker.Slack.Permalink.app_redirect/2`."
  @spec app_redirect(term(), term()) :: String.t() | nil
  defdelegate app_redirect(workspace_ref, channel_ref), to: Permalink

  @doc "Slack's link to one message; see `Ryker.Slack.Permalink.app_redirect/3`."
  @spec app_redirect(term(), term(), term()) :: String.t() | nil
  defdelegate app_redirect(workspace_ref, channel_ref, message_ref), to: Permalink

  @doc "Whether `value` is a Slack id: a workspace, channel, person or bot."
  @spec id?(term()) :: boolean()
  defdelegate id?(value), to: Id, as: :valid?

  @doc "Whether `value` is a Slack message timestamp."
  @spec timestamp?(term()) :: boolean()
  defdelegate timestamp?(value), to: Timestamp, as: :valid?

  @doc "The workspace whose names Ryker knows, or nil when Slack is off."
  @spec workspace() :: String.t() | nil
  defdelegate workspace(), to: Names

  @doc "A task card phase in words."
  @spec task_phase_label(String.t()) :: String.t()
  defdelegate task_phase_label(phase), to: TaskCardDetails, as: :label

  @doc "The mark a task card shows beside a phase in `state`."
  @spec task_state_glyph(String.t()) :: String.t()
  defdelegate task_state_glyph(state), to: TaskCardDetails, as: :glyph

  @doc "Changes when Ryker answers in a channel; see `Ryker.Slack.ChannelConfigurations.change_participation/1`."
  defdelegate change_channel_participation(attributes),
    to: ChannelConfigurations,
    as: :change_participation

  @doc "Changes which alerts a channel's Ryker takes up; see `Ryker.Slack.ChannelConfigurations.change_alert_policy/1`."
  defdelegate change_channel_alert_policy(attributes),
    to: ChannelConfigurations,
    as: :change_alert_policy

  @doc "Moves a channel to an environment; see `Ryker.Slack.ChannelConfigurations.select_environment/4`."
  defdelegate select_channel_environment(workspace_ref, channel_ref, environment_ref, actor_ref),
    to: ChannelConfigurations,
    as: :select_environment
end
