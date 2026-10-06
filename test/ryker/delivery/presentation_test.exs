defmodule Ryker.Delivery.PresentationTest do
  use Ryker.DataCase, async: true
  import Ecto.Query
  alias Ryker.Delivery.{PlatformActionCustody, Presentation}
  alias Ryker.Episodes
  alias Ryker.Episodes.Episode
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Records
  alias Ryker.Records.Record
  alias Ryker.Repo
  alias Ryker.Slack.ReplyRecords
  alias Ryker.Work.Custody
  alias Ryker.Work.{Final, Turn}

  @policy_digest String.duplicate("a", 64)

  test "a visible result is renderable only at its exact supported destination" do
    final = final!(:reply)

    assert :ok = Presentation.validate(episode("slack"), turn(), final)
    assert :ok = Presentation.validate(episode("github"), turn(), final)
    assert :ok = Presentation.validate(episode("control_plane"), turn(), final)
    assert :ok = Presentation.validate(episode("eval"), turn(), final)

    assert Presentation.validate(episode("webhook"), turn(), final) ==
             {:error, {:invalid_delivery_presentation, {:unsupported_transport, "webhook"}}}
  end

  test "a silent result has no platform presentation to validate" do
    assert :ok =
             Presentation.validate(episode("webhook"), turn(), final!(:none))
  end

  test "presentation refuses missing durable records and malformed calls" do
    final = final!(:reply, ["record:missing"])

    assert Presentation.validate(episode("slack"), turn(), final) ==
             {:error, :state_record_not_found}

    assert Presentation.validate(%{}, turn(), final) ==
             {:error, {:invalid_delivery_presentation, :document}}
  end

  # A reply cites the reaction it added, as the Work prompt asks, and the
  # validator accepts that ref. Presentation read it as a missing durable
  # record, and the Work executor crashed on the answer: one Slack reply sat
  # for two hours while its turn failed 23 times (2026-09-26).
  test "a reply that cites the reaction it added is presentable, with no card for the reaction" do
    claim = claim!("cited-reaction", "slack")

    assert {:ok, %{action: action}} =
             PlatformActionCustody.enqueue_in_turn(claim, %{
               conversation_ref: claim.episode.destination_conversation_ref,
               document: %{"action" => "add", "emoji_name" => "thumbsup"},
               kind: :reaction,
               source_item_ref: "1787832000.000100",
               thread_ref: "1787832000.000100",
               tool: :set_slack_reaction,
               transport: "slack"
             })

    final = final!(:reply, [action.action_ref])
    assert :ok = Presentation.validate(claim.episode, claim.turn, final)
    assert {:ok, []} = ReplyRecords.fetch(claim.episode.id, [action.action_ref])
  end

  test "audit retention does not spend Slack interactive-card capacity or force a retry" do
    claim = claim!("slack-block-limit", "slack")

    refs =
      Enum.map(1..51, fn index ->
        assert {:ok, record} =
                 Records.create(
                   Records.token(claim.turn),
                   "progress-#{index}",
                   "progress",
                   %{
                     "next_due_at" => nil,
                     "phase" => "checking-#{index}",
                     "summary" => "Completed bounded check #{index}."
                   }
                 )

        record.ref
      end)

    assert :ok = Presentation.validate(claim.episode, claim.turn, final!(:reply, refs))
    assert length(Records.retained_records(claim.episode.id)) == 51
  end

  test "Conversation Lab refuses a cited record its native card cannot safely project" do
    claim = claim!("control-plane-card", "control_plane")

    assert {:ok, record} =
             Records.create(Records.token(claim.turn), "lab-card", "memory_offer", %{
               "expires_in" => "90d",
               "kind" => "alias",
               "repository" => nil,
               "scope" => "conversation",
               "subject" => "service",
               "value" => "The API is the primary service.",
               "visibility" => "conversation"
             })

    Repo.update_all(
      from(record_row in Record, where: record_row.id == ^record.id),
      set: [payload: %{"unexpected" => "unsafe"}]
    )

    assert Presentation.validate(
             claim.episode,
             claim.turn,
             final!(:reply, [record.ref])
           ) ==
             {:error, {:invalid_delivery_presentation, {:invalid_control_plane_card, record.ref}}}
  end

  defp episode("slack") do
    %Episode{
      active_input_refs: [],
      destination_conversation_ref: "slack:TAC2C82AA8963:C456",
      destination_thread_ref: "1787832000.000100",
      destination_transport: "slack",
      execution_mode: :live,
      id: Ecto.UUID.generate()
    }
  end

  defp episode("github") do
    %Episode{
      active_input_refs: [],
      destination_conversation_ref: "github:main:repository:123",
      destination_thread_ref: "issue:42",
      destination_transport: "github",
      execution_mode: :live,
      id: Ecto.UUID.generate()
    }
  end

  defp episode(transport) do
    %Episode{
      active_input_refs: [],
      destination_conversation_ref: "#{transport}:destination",
      destination_thread_ref: nil,
      destination_transport: transport,
      execution_mode: :live,
      id: Ecto.UUID.generate()
    }
  end

  # A turn with no input of its own answers at the episode's home.
  defp turn, do: %Turn{id: Ecto.UUID.generate(), selected_input_refs: []}

  defp final!(:reply) do
    final!(:reply, [])
  end

  defp final!(:none) do
    {:ok, final} =
      Final.parse(%{
        "decision_reason" => "This duplicate source event needs no visible response.",
        "delivery" => "none",
        "message" => nil,
        "outcome" => %{
          "artifact_refs" => [],
          "record_refs" => [],
          "state" => "complete"
        }
      })

    final
  end

  defp final!(:reply, record_refs) do
    {:ok, final} =
      Final.parse(%{
        "decision_reason" => nil,
        "delivery" => "reply",
        "message" => "The requested review is complete.",
        "outcome" => %{
          "artifact_refs" => [],
          "record_refs" => record_refs,
          "state" => "complete"
        }
      })

    final
  end

  defp claim!(suffix, transport) do
    command =
      EpisodeFixtures.admit_input(%{
        destination: %{
          conversation_ref: "#{transport}:conversation:#{suffix}",
          thread_ref: "#{transport}:thread:#{suffix}",
          transport: transport
        },
        episode_id: Ecto.UUID.generate(),
        episode_key: "presentation:#{suffix}",
        native_input_id: "source:#{suffix}",
        payload: %{"text" => "Please help."},
        turn_ref: "turn:#{suffix}"
      })

    assert {:ok, transition} = Episodes.apply(command)
    assert {:ok, _session} = Custody.pin_episode(transition.episode.id, "test", @policy_digest)
    assert {:ok, claim} = Custody.claim_next("worker:#{suffix}", 60)
    claim
  end
end
