defmodule Ryker.Delivery.ChatCardConfirmationTest do
  @moduledoc """
  What a confirmed offer's Chat card says happened, read from the row the
  confirmation saved rather than from the offer the model wrote.
  """
  use Ryker.DataCase, async: true

  alias Ecto.Changeset
  alias Ryker.ControlPlane.HTML
  alias Ryker.Delivery.ChatCard
  alias Ryker.Fixtures.SavedEntities
  alias Ryker.Repo
  alias Ryker.State.Record

  # QA, 2026-09-25: after "Schedule this" or "Remember this" the button went
  # away and nothing said it had worked, and the schedule card went on saying
  # "weekday" over a schedule that ran on Mondays. The confirmed card now says
  # what was saved and how often it runs, from the schedule itself.
  test "a confirmed schedule offer says it is scheduled, how often it runs and where to find it" do
    source = SavedEntities.source!("slack:TCARDCONFIRM:C456")
    schedule = SavedEntities.schedule!(source, "Weekday open incident status", 1)

    # The schedule has since been changed to weekdays; the offer still says
    # daily at 13:00. The card follows the schedule.
    schedule =
      schedule
      |> Changeset.change(recurrence: %{"kind" => "weekdays", "time" => "09:00:00"})
      |> Repo.update!()

    offer = %{Repo.get!(Record, schedule.offer_record_id) | status: :confirmed}
    path = "/schedules/" <> URI.encode(schedule.ref, &URI.char_unreserved?/1)

    assert {:ok, card} = ChatCard.project(offer)
    assert card.action == nil

    assert card.outcome == %{
             href: path,
             link: "Open schedule",
             text: "runs every weekday at 09:00 UTC",
             tone: :on,
             word: "Scheduled"
           }

    html = HTML.lab_message_extras(%{cards: [card]}) |> IO.iodata_to_binary()
    assert html =~ ~s(<span class="state-word" data-tone="on">Scheduled</span>)
    assert html =~ "runs every weekday at 09:00 UTC"
    assert html =~ ~s(<a href="#{path}">Open schedule</a>)

    schedule |> Changeset.change(status: :deleted) |> Repo.update!()
    assert {:ok, deleted} = ChatCard.project(offer)
    assert %{tone: :off, word: "Schedule deleted", text: nil, href: ^path} = deleted.outcome
  end

  test "a confirmed memory offer says it was saved to memory and links the fact" do
    source = SavedEntities.source!("slack:TCARDMEMORY:C456")

    memory =
      SavedEntities.memory!(
        source,
        "Staging Emisar account",
        "The staging Emisar account is named acme-staging."
      )

    offer = %{Repo.get!(Record, memory.offer_record_id) | status: :confirmed}

    assert {:ok, card} = ChatCard.project(offer)
    assert %{tone: :on, word: "Saved to memory", link: "Open facts", href: href} = card.outcome
    assert href == "/memory#fact-" <> String.replace(memory.ref, ~r/[^A-Za-z0-9_-]/, "-")

    html = HTML.lab_message_extras(%{cards: [card]}) |> IO.iodata_to_binary()
    assert html =~ ~s(<span class="state-word" data-tone="on">Saved to memory</span>)
    assert html =~ ~s(<a href="#{href}">Open facts</a>)
  end

  test "an open offer has no outcome line yet" do
    source = SavedEntities.source!("slack:TCARDOPEN:C456")
    schedule = SavedEntities.schedule!(source, "Daily review", 1)
    offer = Repo.get!(Record, schedule.offer_record_id)

    assert {:ok, card} = ChatCard.project(offer)
    assert card.action == :confirm_schedule
    assert card.outcome == nil

    refute HTML.lab_message_extras(%{cards: [card]}) |> IO.iodata_to_binary() =~
             "lab-card-outcome"
  end
end
