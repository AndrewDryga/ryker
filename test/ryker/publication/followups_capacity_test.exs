defmodule Ryker.Publication.FollowupsCapacityTest do
  # A hundred and one published tasks take seven seconds here and over a minute
  # on CI's runner beside the async suite: this test timed out there on three
  # pushes on 2026-09-30, twice taking a Lab claim that ran beside it past its
  # fifteen-second query limit. It runs with the serial tests instead.
  use Ryker.DataCase, async: false

  import Ecto.Query

  alias Ryker.Fixtures.Publication, as: PublicationFixture
  alias Ryker.Ingress.Input
  alias Ryker.Publication.{Followup, Followups, LifecycleEvent, Publication}

  @now ~U[2026-08-28 12:10:00.000000Z]

  @tag timeout: 240_000
  test "typed lifecycle correlation is not capped at one hundred active publications" do
    publications =
      for index <- 1..101 do
        PublicationFixture.published!("lifecycle-cap-#{index}",
          pull_request_number: 1_000 + index
        ).publication
      end

    ids = Enum.map(publications, & &1.id)
    branch_ref = "refs/heads/release/all-active"

    Repo.update_all(
      from(publication in Publication, where: publication.id in ^ids),
      set: [branch_ref: branch_ref]
    )

    Repo.update_all(
      from(followup in Followup, where: followup.publication_id in ^ids),
      set: [merge_sha: String.duplicate("a", 40), pr_state: "merged"]
    )

    assert Followups.observe_input(
             typed_lifecycle_input(["release/all-active"], "deployment", "pending")
           ) == {:ok, 101}

    assert Repo.aggregate(
             from(event in LifecycleEvent,
               where: event.publication_id in ^ids and event.kind == "deployment"
             ),
             :count
           ) == 101
  end

  defp typed_lifecycle_input(references, kind, state) do
    {:ok, input} =
      Input.new(%{
        actor: %{kind: :system, ref: "webhook-route:deployments"},
        content: %{
          "event_type" => "responder.publication_lifecycle.v1",
          "payload" => %{
            "environment" => "production",
            "kind" => kind,
            "references" => references,
            "repository" => "ryker",
            "run_ref" => "deployment-run:#{Ecto.UUID.generate()}",
            "state" => state,
            "target" => "ryker"
          }
        },
        destination: %{
          conversation_ref: "slack:T123:C-deployments",
          thread_ref: "deployment-thread",
          transport: "slack"
        },
        event_kind: :event,
        event_ref: "lifecycle:capacity:#{Ecto.UUID.generate()}",
        native_input_id: "lifecycle-item:capacity:#{Ecto.UUID.generate()}",
        occurred_at: @now,
        occurred_at_source: :source,
        revision: 1,
        source: %{kind: "webhook", ref: "deployments"},
        source_capabilities: %{
          "publication_lifecycle" => %{
            "environments" => ["production"],
            "kinds" => ["deployment", "terraform"],
            "repositories" => ["ryker"],
            "targets" => ["ryker"]
          }
        },
        source_item_ref: nil
      })

    input
  end
end
