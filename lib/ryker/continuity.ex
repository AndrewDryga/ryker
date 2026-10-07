defmodule Ryker.Continuity do
  @moduledoc """
  Durable, derived conversation continuity.

  A model may stage a typed summary only while it owns an active Work turn. The
  summary becomes recallable in the same transaction that accepts the validated
  result. Summaries and rollups are bounded hints, never evidence or authority.

  This module is the continuity context's API for the rest of the host: Work
  custody, submissions, admission, Slack channel lifecycle and the control
  plane call it and nothing deeper. The work is split along its seams:

    * `Ryker.Continuity.Scope` resolves a destination's workspace,
      visibility and identity key.
    * `Ryker.Continuity.Handover` stages a summary during a turn and
      publishes it with the accepted result.
    * `Ryker.Continuity.Recall` builds the model's continuity context and
      serves the summary and rollup lanes of memory search.
    * `Ryker.Continuity.Compaction` folds aged summaries into rollups and
      removes a deleted Slack channel's continuity; retention calls it directly.

  A summary published, recalled, compacted or removed is announced after the
  outermost commit (`subscribe_continuity/0`).
  """
  alias Ryker.Continuity.Compaction
  alias Ryker.Continuity.Handover
  alias Ryker.Continuity.Recall
  alias Ryker.Continuity.Scope

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

  # -- PubSub ------------------------------------------------------------------

  @doc """
  Subscribes the caller to conversation summary changes:
  `{:continuity_updated, conversation_ref}` once a summary of that
  conversation (or the repository or workspace it rolls up into) is
  published, recalled, compacted or removed, and that change has committed.
  """
  def subscribe_continuity, do: Ryker.PubSub.subscribe(continuity_topic())

  def unsubscribe_continuity, do: Ryker.PubSub.unsubscribe(continuity_topic())

  @doc """
  Internal — announces, after the outermost commit, that the summaries of
  `conversation_ref` changed. The continuity seams call it.
  """
  @spec broadcast_continuity_updated(String.t()) :: :ok
  def broadcast_continuity_updated(conversation_ref) do
    Ryker.Repo.after_commit(fn ->
      Ryker.PubSub.broadcast(continuity_topic(), {:continuity_updated, conversation_ref})
    end)
  end

  defp continuity_topic, do: "continuity"
end
