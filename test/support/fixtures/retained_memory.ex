defmodule Ryker.Fixtures.RetainedMemory do
  @moduledoc "A summary or rollup with the sources a retention test gives it."
  alias Ryker.CanonicalJSON
  alias Ryker.Continuity.ConversationRollup
  alias Ryker.Continuity.ConversationSummary
  alias Ryker.Repo

  @doc "A `schema` row in `source`'s conversation resting on `dependencies`; nil stores SQL NULL."
  def retained!(schema, dependencies, source) do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now()
    state = %{"situation" => "Retained structural fixture for source-history expiry."}

    attributes = %{
      id: id,
      workspace_ref: source.workspace_ref,
      visibility: source.visibility,
      repository_ref: source.repository_ref,
      state: state,
      state_fingerprint: CanonicalJSON.digest(state),
      source_dependencies: dependencies || []
    }

    specific =
      case schema do
        ConversationSummary ->
          %{
            ref: "continuity:#{id}",
            identity_key: CanonicalJSON.digest(id),
            transport: source.transport,
            conversation_ref: source.conversation_ref,
            source_result_ref: "result:#{id}"
          }

        ConversationRollup ->
          %{
            ref: "continuity-rollup:#{id}",
            scope_kind: :conversation,
            scope_ref: source.conversation_ref,
            period_start: DateTime.add(now, -86_400, :second),
            period_end: now,
            expires_at: DateTime.add(now, 86_400, :second),
            source_refs: ["continuity:#{id}"],
            source_scopes: [],
            source_count: 1
          }
      end

    saved = schema |> struct!(Map.merge(attributes, specific)) |> Repo.insert!()

    # The schema defaults to []; retain actual SQL NULL when that is the case
    # under test rather than accidentally testing an empty array twice.
    if is_nil(dependencies),
      do: Repo.update!(Ecto.Changeset.change(saved, source_dependencies: nil)),
      else: saved
  end
end
