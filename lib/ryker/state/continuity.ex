defmodule Ryker.State.Continuity do
  @moduledoc """
  Durable, derived conversation continuity.

  A model may stage a typed summary only while it owns an active Work turn. The
  summary becomes recallable in the same transaction that accepts the validated
  result. Summaries and rollups are bounded hints, never evidence or authority.

  This module is the continuity context's API for the rest of the host: Work
  custody, submissions, admission, Slack channel lifecycle and the control
  plane call it and nothing deeper. The work is split along its seams:

    * `Ryker.State.Continuity.Scope` resolves a destination's workspace,
      visibility and identity key.
    * `Ryker.State.Continuity.Handover` stages a summary during a turn and
      publishes it with the accepted result.
    * `Ryker.State.Continuity.Recall` builds the model's continuity context and
      serves the summary and rollup lanes of memory search.
    * `Ryker.State.Continuity.Compaction` folds aged summaries into rollups and
      removes a deleted Slack channel's continuity; retention calls it directly.
  """

  alias Ryker.State.Continuity.{Compaction, Handover, Recall, Scope}

  @doc "Stage a typed summary for the Work turn a state token names."
  defdelegate stage(state_token, state), to: Handover

  @doc "Publish the accepted turn's staged summary inside the accepting transaction."
  defdelegate accept_staged_in_transaction(episode, session, turn, result_ref), to: Handover

  @doc "Bind the turn's staged summary to the candidate being validated."
  defdelegate candidate_staged_in_transaction(turn, candidate_sha256, candidate_attempt),
    to: Handover

  @doc "The fingerprint of the turn's staged summary for the final preflight."
  defdelegate preflight_fingerprint_in_transaction(turn), to: Handover

  @doc "The continuity a model receives for an episode."
  defdelegate model_context(episode, repository_ref, input_texts \\ []), to: Recall

  @doc "Remove everything a deleted Slack channel left in continuity."
  defdelegate delete_slack_channel_in_transaction(workspace_ref, channel_ref), to: Compaction

  @doc "The continuity scope of an episode's destination."
  defdelegate destination_context(episode, repository_ref), to: Scope
end
