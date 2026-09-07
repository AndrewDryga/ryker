defmodule Responder.Fixtures.Learning do
  @moduledoc false
  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Repo
  alias Responder.State.Observations

  def inputs! do
    "testdata/learning/retained-haproxy-lifecycle.json"
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("inputs")
    |> Enum.map(&persist!/1)
  end

  defp persist!(raw) do
    at = raw["occurred_at"] |> NaiveDateTime.from_iso8601!() |> DateTime.from_naive!("Etc/UTC")
    id = raw["source_input_id"]

    {:ok, %{episode: episode}} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: id,
          episode_key: "ingress-input:#{id}",
          native_input_id: raw["native_input_id"],
          revision: raw["revision"],
          occurred_at: at,
          turn_ref: "ingress-turn:#{id}",
          payload: raw["content"],
          destination: %{
            transport: raw["destination_transport"],
            conversation_ref: raw["destination_conversation_ref"],
            thread_ref: raw["destination_thread_ref"]
          }
        })
      )

    fields =
      ~w(dedupe_key event_ref event_fingerprint source_kind source_ref native_input_id source_item_ref actor_ref revision content source_capabilities destination_transport destination_conversation_ref destination_thread_ref repository_ref work_policy work_policy_digest decision_ref decision_fingerprint decision_document)a

    attrs = Map.new(fields, &{&1, raw[Atom.to_string(&1)]})

    entry =
      Repo.insert!(
        struct!(
          Entry,
          Map.merge(attrs, %{
            id: id,
            status: :decided,
            event_kind: :message,
            actor_kind: :bot,
            occurred_at: at,
            occurred_at_source: :source,
            execution_mode: :shadow,
            decision_action: :start_episode,
            episode_id: episode.id
          })
        )
      )

    {:ok, :ok} = Repo.transaction(fn -> Observations.receive_in_transaction(entry) end)
    entry
  end
end
