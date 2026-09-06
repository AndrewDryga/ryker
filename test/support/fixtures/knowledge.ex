defmodule Responder.Fixtures.Knowledge do
  @moduledoc false
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Repo
  alias Responder.State.{Knowledge, Observations}

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
        "expected_version" => 0
      })

    {:ok, :ok} =
      Repo.transaction(fn ->
        :ok = Observations.record_in_transaction(entry, @note, "recorded-result:#{id}")
        Knowledge.record_in_transaction(entry, proposal, [])
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
            revision: 2,
            event_kind: :delete
        })
      end)
  end
end
