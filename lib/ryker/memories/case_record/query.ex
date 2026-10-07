defmodule Ryker.Memories.CaseRecord.Query do
  @moduledoc "Cases kept from finished work, for every read of `episode_case_records`."
  import Ecto.Query
  alias Ryker.Memories.CaseRecord
  alias Ryker.Slack.ChannelMembership

  def all, do: from(records in CaseRecord, as: :episode_case_records)

  def by_case_ref(queryable \\ all(), case_ref),
    do: where(queryable, [episode_case_records: r], r.case_ref == ^case_ref)

  def active(queryable \\ all()),
    do: where(queryable, [episode_case_records: r], r.status == :active)

  def excluding_episode(queryable, episode_id),
    do: where(queryable, [episode_case_records: r], r.episode_id != ^episode_id)

  @doc "Active cases of `execution_mode` in `scope`'s workspace that `scope` may see."
  def recallable(scope, execution_mode) do
    all()
    |> active()
    |> where(
      [episode_case_records: r],
      r.workspace_ref == ^scope.workspace_ref and r.execution_mode == ^execution_mode
    )
    |> visible_to(scope)
  end

  # A case is seen where its work happened, and passes from one public channel
  # to another public channel of its workspace, as notes and topics do. Matching
  # by workspace alone took work in a DM or a private channel into every public
  # and Slack Connect channel (2026-10-04 review).
  defp visible_to(queryable, %{transport: "slack", visibility: :public} = scope) do
    public = ChannelMembership.Query.public_conversation_refs(scope.workspace_ref)

    where(
      queryable,
      [episode_case_records: r],
      r.conversation_ref == ^scope.conversation_ref or r.conversation_ref in subquery(public)
    )
  end

  defp visible_to(queryable, scope),
    do: where(queryable, [episode_case_records: r], r.conversation_ref == ^scope.conversation_ref)

  @doc "Cases whose words match `terms`, a `to_tsquery` expression, the best matches first."
  def matching_terms(queryable, terms) do
    queryable
    |> where(
      [episode_case_records: r],
      fragment("to_tsvector('english', ?) @@ to_tsquery('english', ?)", r.search_text, ^terms)
    )
    |> order_by([episode_case_records: r],
      desc:
        fragment(
          "ts_rank_cd(to_tsvector('english', ?), to_tsquery('english', ?), 32)",
          r.search_text,
          ^terms
        ),
      desc: r.closed_at
    )
  end

  @doc "Cases within the scope a search names: this channel, the repository or anywhere."
  def within_scope(queryable, context, "current_channel") do
    where(queryable, [episode_case_records: r], r.conversation_ref == ^context.conversation_ref)
  end

  def within_scope(queryable, %{repository_ref: repository}, "repository")
      when is_binary(repository),
      do: where(queryable, [episode_case_records: r], r.repository_ref == ^repository)

  def within_scope(queryable, _context, scope) when scope in ["workspace", "global"],
    do: queryable

  def within_scope(queryable, _context, _scope), do: where(queryable, false)

  @doc "The fields a memory search reads from a case (`Ryker.Memories.SearchPage.Query`)."
  def search_fields do
    %{
      text: dynamic([episode_case_records: r], r.search_text),
      changed: dynamic([episode_case_records: r], r.updated_at),
      source: dynamic([episode_case_records: r], r.closed_at)
    }
  end

  @doc "Cases that keep message `native_input_id` among their sources."
  def citing_message(native_input_id),
    do: where(all(), [episode_case_records: r], ^native_input_id in r.source_refs)

  @doc "Cases of work in a conversation, or built from any of its messages."
  def from_conversation(transport, conversation_ref) do
    where(
      all(),
      [episode_case_records: r],
      (r.transport == ^transport and r.conversation_ref == ^conversation_ref) or
        fragment("? @> ARRAY[?]::text[]", r.conversation_refs, ^conversation_ref)
    )
  end

  def ordered_by_case_ref(queryable),
    do: order_by(queryable, [episode_case_records: r], asc: r.case_ref)

  def limit_to(queryable, count), do: limit(queryable, ^count)
  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
