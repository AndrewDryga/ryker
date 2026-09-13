defmodule Ryker.Fixtures.Knowledge do
  @moduledoc false
  alias Ryker.Admission.Decision
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo
  alias Ryker.State.{Knowledge, LearningSources, Observations}

  @doc "Store-contract fixture, not an admission memory API or a model-result recording."
  def record_topic(entry, proposal, offered, omissions \\ []) do
    sources =
      LearningSources.merge([
        LearningSources.for_entry(entry)
        | Enum.map(offered, &LearningSources.document_sources/1)
      ])

    Knowledge.record_sources_in_transaction([entry], proposal, offered, %{
      result_ref: "fixture-knowledge:#{entry.id}",
      source_dependencies: sources,
      omissions: omissions
    })
  end

  @doc "Accept the real routing decision, then exercise the owning topic store under its frozen source context."
  def commit_topic(context, %{knowledge: proposal}, result_ref) do
    {:ok, routing} =
      Decision.parse(%{
        "action" => "ignore",
        "episode_ref" => nil,
        "reaction" => nil,
        "relation" => "unrelated",
        "repository_source" => nil,
        "reason" => "No reply is useful.",
        "work_class" => nil
      })

    Repo.transaction(fn ->
      with :ok <-
             Knowledge.lock_scope_in_transaction(
               context.input_entry,
               context.input_entry.repository_ref
             ),
           {:ok, receipt} <- Ryker.Admission.commit(context, routing, result_ref),
           :ok <- record_proposal(receipt.entry, proposal, context, result_ref) do
        receipt
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp record_proposal(_entry, nil, _context, _ref), do: :ok

  defp record_proposal(entry, proposal, context, ref) do
    Knowledge.record_sources_in_transaction([entry], proposal, context.knowledge, %{
      result_ref: ref,
      source_dependencies: context.source_dependencies,
      omissions: context.knowledge_omissions
    })
  end

  # Retained Blitz observation: draft-ai-suggestions was to be kept, not deleted.
  @note %{
    "summary" =>
      "U03EPT4RP5M wants to keep `draft-ai-suggestions` and plans to look into it at an unspecified future time.",
    "topics" => ["draft-ai-suggestions"]
  }

  def learn!(destination, repository \\ nil) do
    id = Ecto.UUID.generate()

    entry =
      struct!(
        Entry,
        Map.merge(
          Map.take(
            Map.from_struct(destination),
            [:destination_transport, :destination_conversation_ref, :destination_thread_ref]
          ),
          %{
            id: id,
            status: :decided,
            source_kind: "slack",
            source_ref: "fixture:#{id}",
            native_input_id: id,
            event_kind: :message,
            revision: 1,
            event_fingerprint: String.duplicate("a", 64),
            actor_ref: "U03EPT4RP5M",
            content: %{"text" => @note["summary"]},
            occurred_at: DateTime.utc_now(),
            execution_mode: :shadow,
            repository_ref: repository
          }
        )
      )

    proposal =
      Map.merge(@note, %{
        "topic_key" => "draft-ai-suggestions",
        "title" => "Keep draft-ai-suggestions",
        "target_ref" => nil,
        "expected_version" => 0,
        "anchors" => []
      })

    {:ok, :ok} =
      Repo.transaction(fn ->
        :ok = Observations.record_excerpt_in_transaction(entry)
        record_topic(entry, proposal, [])
      end)

    document = Enum.find(Knowledge.context(destination, repository), & &1["can_update"])
    {entry, document}
  end

  def revoke!(entry) do
    {:ok, :ok} =
      Repo.transaction(fn ->
        Observations.receive_in_transaction(%{
          entry
          | id: Ecto.UUID.generate(),
            revision: entry.revision + 1,
            event_kind: :delete
        })
      end)
  end
end
