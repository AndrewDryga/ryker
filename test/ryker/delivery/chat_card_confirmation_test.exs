defmodule Ryker.Delivery.ChatCardConfirmationTest do
  @moduledoc """
  What a confirmed offer's Chat card says happened, read from the row the
  confirmation saved rather than from the offer the model wrote.
  """
  use Ryker.DataCase, async: true

  alias Ecto.Changeset
  alias Ryker.ControlPlane.{Assets, HTML}
  alias Ryker.Delivery.ChatCard
  alias Ryker.Fixtures.SavedEntities
  alias Ryker.Records.Record
  alias Ryker.Repo

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

    assert card.outcome == %{href: path, link: "Open schedule", tone: :on, word: "Scheduled"}

    # Andrew, 2026-10-01, of "● Scheduled · runs once on 2 Oct 2026 at 09:00 UTC · Open
    # schedule" under "How often: Once on 2 Oct 2026 at 09:00 UTC": "we need a more clean
    # confirmed state, this one is messy". How often it runs is said once, from the schedule.
    assert {"How often", "Every weekday at 09:00 UTC"} in card.details

    html = HTML.lab_message_extras(%{cards: [card]}) |> IO.iodata_to_binary()

    assert html =~
             ~s(<div class="lab-card-outcome" data-tone="on"><span class="lab-card-outcome-state">Scheduled</span><a class="lab-card-outcome-link" href="#{path}">Open schedule</a></div>)

    refute html =~ "runs every weekday"

    schedule |> Changeset.change(status: :deleted) |> Repo.update!()
    assert {:ok, deleted} = ChatCard.project(offer)
    assert %{tone: :off, word: "Schedule deleted", href: ^path} = deleted.outcome
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

    assert html =~
             ~s(<div class="lab-card-outcome" data-tone="on"><span class="lab-card-outcome-state">Saved to memory</span><a class="lab-card-outcome-link" href="#{href}">Open facts</a></div>)
  end

  # Andrew, 2026-10-01, of "● Saved to memory · Open facts": "Text is not vertically aligned, no
  # vertical rhythm, and it's small compared to rest of card". The confirmed line is one row at
  # the card's own size, its dot, word and link on one centre line.
  test "a confirmed card's footer is one row at the card's text size" do
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body

    assert [_, row] =
             Regex.run(~r/\.chat-message-extras \.lab-card \.lab-card-outcome \{([^}]+)\}/, css)

    assert row =~ "display:flex"
    assert row =~ "align-items:center"
    assert row =~ "font-size:14px"
    assert row =~ "line-height:20px"
    assert row =~ "margin:16px 0 0"
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
