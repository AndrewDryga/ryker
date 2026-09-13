defmodule Ryker.Fixtures.AnswerMemory do
  @moduledoc "Store-contract setup; Slack delivery/admission is covered by QuestionEndToEndTest."

  alias Ryker.Admission.Decision
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.EntryChangeset
  alias Ryker.Repo
  alias Ryker.Slack.Input
  alias Ryker.State.{Records, ResponseChangeset}
  alias Ryker.Work.Custody

  def answered!(value, occurred_at) do
    id = Ecto.UUID.generate()
    workspace = "TANSWER#{String.replace(id, "-", "")}"

    destination = %{
      conversation_ref: "slack:#{workspace}:C1",
      thread_ref: "1789038000.000001",
      transport: "slack"
    }

    {:ok, transition} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          destination: destination,
          episode_id: id,
          episode_key: "answer-memory:#{id}",
          native_input_id: "answer-memory:#{id}",
          occurred_at: occurred_at,
          turn_ref: "answer-memory:#{id}"
        })
      )

    {:ok, _} = Custody.pin_episode(id, "answer-memory", String.duplicate("a", 64))
    {:ok, claim} = Custody.claim_next("answer-memory:#{id}", 60, :work)
    true = claim.episode.id == transition.episode.id

    {:ok, record} =
      Records.create(Records.token(claim.turn), "project", "input_request", %{
        "choices" => [],
        "question" => "Which GCP project hosts the production portal?",
        "remember" => %{"subject" => "GCP project", "applicability" => "Production portal"}
      })

    record = Repo.update!(Ecto.Changeset.change(record, status: :answered))

    attributes = %{
      actor: %{kind: :user, ref: "UOPERATOR"},
      channel_ref: "C1",
      content: %{"text" => value},
      event_kind: :message,
      event_ref: "answer:#{id}",
      message_ref: "1789038001.000001",
      occurred_at: occurred_at,
      revision: 1,
      thread_ref: destination.thread_ref,
      workspace_ref: workspace
    }

    {:ok, input} = Input.new(attributes)
    {:ok, %{entry: entry}} = Inbox.record(input)

    {:ok, decision} =
      Decision.parse(%{
        "action" => "continue_episode",
        "episode_ref" => "candidate:answer-memory",
        "reaction" => nil,
        "relation" => "same_work",
        "repository_source" => nil,
        "reason" => "Store-contract answer in the same episode.",
        "work_class" => "standard"
      })

    entry = Repo.update!(EntryChangeset.decide(entry, decision, "decision:#{id}", id))

    response =
      ResponseChangeset.insert(%{
        actor_ref: entry.actor_ref,
        id: Ecto.UUID.generate(),
        inbox_entry_id: entry.id,
        occurred_at: occurred_at,
        record_id: record.id,
        response_ref: entry.event_ref
      })
      |> Repo.insert!()

    %{claim: claim, record: record, entry: entry, response: response, input: attributes}
  end
end
