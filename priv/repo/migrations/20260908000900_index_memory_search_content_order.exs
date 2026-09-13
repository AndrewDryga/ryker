defmodule Ryker.Repo.Migrations.IndexMemorySearchContentOrder do
  use Ecto.Migration

  def change do
    # A reply can refer to an existing subject without repeating its name. The
    # retained source relation supplies candidates, never authority to merge.
    create(
      index(
        :conversation_observations,
        [:conversation_ref, "COALESCE(thread_ref, source_message_ref)"],
        name: :conversation_observations_reply_subject
      )
    )

    # Recall counters touch updated_at. Search must traverse the independent
    # content clock, within an authorized scope, without sorting the whole store.
    create(
      index(
        :operational_memory_entries,
        [
          :workspace_ref,
          :scope_kind,
          :scope_ref,
          "COALESCE(edited_at, confirmed_at) DESC",
          "id DESC"
        ],
        name: :operational_memory_search_page,
        where: "status = 'active'"
      )
    )

    create(
      index(
        :operator_behaviors,
        [
          :workspace_ref,
          :scope_kind,
          :scope_ref,
          "COALESCE(edited_at, confirmed_at) DESC",
          "id DESC"
        ],
        name: :guidance_search_page,
        where: "status = 'active' AND kind = 'guidance'"
      )
    )
  end
end
