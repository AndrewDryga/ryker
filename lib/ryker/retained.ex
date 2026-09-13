defmodule Ryker.Retained do
  @moduledoc """
  The names the product wrote into durable rows and posted into Slack before it
  was renamed from Responder to Ryker on 2026-09-13, and the one place code that
  meets those rows again may recognise them.

  Every value here is an explicit rule, never a decoder fallback: each names a
  kind of record that still exists (a Work session a worker still holds, a
  system input the learning classifier still sorts, a card an operator can
  still click) and is never minted again. New rows carry the `ryker` form, and
  nothing here reads environment, configuration or wire-protocol names.
  """

  # The cutover date of the rename. Rows written before it keep the names below.
  @cutover_date ~D[2026-09-13]

  # `episode_work_sessions.external_ref` of Work sessions created before the
  # cutover. `Ryker.Work.Custody` mints `ryker-work:` now; the retained rows keep
  # identifying live worker sessions, so App Home controls rendered from them
  # must still resolve.
  @work_session_prefix "responder-work:"

  # `source.ref` of host-authored system inputs (state event wake-ups, world
  # runs) recorded before the cutover. `Ryker.State.EventWaits` records `ryker`
  # now; the learning-source classifier must keep sorting the stored inputs.
  @system_source_ref "responder"

  # Prefix of every Slack action, callback and block id posted on cards before
  # the cutover. Those cards stay in Slack history; a click on one is answered
  # with an explicit "this card predates the rename" reply and an audit row,
  # never decoded as if it were a current control.
  @slack_action_prefix "responder_"

  # The slash command the Slack app registered before the cutover. Slack keeps
  # delivering it until the shipped manifest is applied; the gateway answers it
  # by naming the current command rather than decoding it.
  @slack_command "/responder"

  @spec cutover_date() :: Date.t()
  def cutover_date, do: @cutover_date

  @spec work_session_prefix() :: String.t()
  def work_session_prefix, do: @work_session_prefix

  @spec system_source_ref() :: String.t()
  def system_source_ref, do: @system_source_ref

  @spec slack_action_prefix() :: String.t()
  def slack_action_prefix, do: @slack_action_prefix

  @spec slack_command() :: String.t()
  def slack_command, do: @slack_command

  @doc "Whether a Slack action id was minted before the rename."
  @spec retired_slack_action?(term()) :: boolean()
  def retired_slack_action?(action_id),
    do: is_binary(action_id) and String.starts_with?(action_id, @slack_action_prefix)
end
