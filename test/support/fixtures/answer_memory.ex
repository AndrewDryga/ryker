defmodule Ryker.Fixtures.AnswerMemory do
  @moduledoc "Store-contract setup; Slack delivery/admission is covered by QuestionEndToEndTest."

  alias Ryker.Admission.Decision
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Records
  alias Ryker.Records.Response
  alias Ryker.Repo
  alias Ryker.Slack.{ChannelMembership, Input}
  alias Ryker.Work.Custody

  @remember %{"subject" => "GCP project", "applicability" => "Production portal"}

  @doc """
  An answered question in a live Work turn, in a public channel Ryker is in;
  `remember: nil` asks it without the intent, and `private: true` asks it in
  a private channel.
  """
  def answered!(value, occurred_at, options \\ []) do
    id = Ecto.UUID.generate()
    workspace = "TANSWER#{String.replace(id, "-", "")}"

    Repo.insert!(%ChannelMembership{
      id: Ecto.UUID.generate(),
      workspace_ref: workspace,
      channel_ref: "C1",
      private: Keyword.get(options, :private, false),
      external_shared: false,
      generation: 1,
      status: :joined,
      joined_at: occurred_at
    })

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

    {:ok, _} = WorkSessions.pin_episode(id, "answer-memory", String.duplicate("a", 64))
    {:ok, claim} = Custody.claim_next("answer-memory:#{id}", 60, :work)
    true = claim.episode.id == transition.episode.id

    question =
      case Keyword.get(options, :remember, @remember) do
        nil -> %{}
        remember -> %{"remember" => remember}
      end
      |> Map.merge(%{
        "choices" => [],
        "question" => "Which GCP project hosts the production portal?"
      })

    {:ok, record} =
      Records.create(Records.token(claim.turn), "project", "input_request", question)

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
        "messages" => nil,
        "reactions" => nil,
        "relation" => "same_work",
        "repository" => nil,
        "repository_source" => nil,
        "reason" => "Store-contract answer in the same episode.",
        "work_class" => "standard"
      })

    entry = Repo.update!(Entry.Changeset.decide(entry, decision, "decision:#{id}", id))

    response =
      Response.Changeset.insert(%{
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
