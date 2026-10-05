defmodule Ryker.ControlPlane.IncidentRoomsListTest do
  use Ryker.DataCase, async: true

  alias Ryker.ControlPlane.{IncidentProjection, Pages, Projection}
  alias Ryker.Fixtures.SavedEntities
  alias Ryker.Records
  alias Ryker.Slack.IncidentRoomChangeset

  @now ~U[2026-10-05 12:00:00.000000Z]

  # The directory read the newest 100 rooms and counted only those, so past a hundred the
  # count and the open count were both wrong and the older rooms were gone (2026-10-04
  # review).
  test "the room directory counts every room and pages through them, newest opened first" do
    source = SavedEntities.source!("slack:T123:source-CROOMS")

    for n <- 1..26 do
      status = if rem(n, 2) == 0, do: :closed, else: :requested
      if n in [1, 25], do: ready_room!(source, n), else: room!(source, n, status)
    end

    first = IncidentProjection.list(%{})
    assert %{total: 26, page: 1, pages: 2, open: 2} = first
    assert length(first.items) == 25
    assert hd(first.items).ref == "incident-room:list-1"

    last = IncidentProjection.list(%{"page" => "2"})
    assert [%{ref: "incident-room:list-26", status: :closed}] = last.items
    assert last.open == 2

    # A status view counts what matches it; the open count keeps only the search.
    assert %{total: 2, open: 2} = IncidentProjection.list(%{"status" => "ready"})
    assert %{total: 1, open: 1} = IncidentProjection.list(%{"q" => "Incident 25"})

    body =
      Pages.page(["incident-rooms"], %{"page" => "2"}, %{projection: Projection.callbacks()}).body
      |> LazyHTML.from_fragment()

    assert body |> LazyHTML.query(".kit-count") |> Enum.map(&squeeze(LazyHTML.text(&1))) ==
             ["26 rooms", "2 open"]

    assert body |> LazyHTML.query("nav.pagination span") |> LazyHTML.text() =~ "Page 2 of 2"
  end

  # An open room: its investigation runs as a request of its own, and its channel is set up.
  defp ready_room!(source, n) do
    investigation = SavedEntities.source!("slack:T123:CROOM#{n}")

    room!(source, n, :ready, %{
      audience_prepared_at: @now,
      episode_id: investigation.episode.id,
      handoff_message_ref: "1787832001.00010#{n}",
      root_card_fingerprint: String.duplicate("d", 64),
      root_card_ui_revision: 1,
      root_message_ref: "1787832000.00020#{n}",
      root_pinned_at: @now,
      topic_prepared_at: @now
    })
  end

  # One room of `source`'s, opened `n` minutes before @now.
  defp room!(source, n, status, fields \\ %{}) do
    {:ok, record} =
      Records.create(
        Records.token(source.turn),
        "incident-room-offer:#{n}",
        "progress",
        %{"next_due_at" => nil, "phase" => "investigating", "summary" => "Evidence."}
      )

    %{
      attempt_count: 1,
      bot_user_ref: "U-BOT",
      channel_name: "inc-#{n}",
      channel_ref: "CROOM#{n}",
      channel_state: :active,
      channel_state_changed_at: @now,
      channel_state_event_ref: "channel-state:#{n}",
      confirmation_ref: "incident-confirmation:#{n}",
      id: Ecto.UUID.generate(),
      invite_user_group_refs: [],
      invite_user_refs: [],
      policy: "incident-investigate",
      policy_digest: String.duplicate("c", 64),
      private: true,
      prompt: "Investigate.",
      reconciled_channel_state: :active,
      record_id: record.id,
      ref: "incident-room:list-#{n}",
      repository_ref: "ryker",
      requested_at: DateTime.add(@now, -n, :minute),
      requested_by_actor_ref: "U123",
      source_channel_ref: "C456",
      source_episode_id: source.episode.id,
      source_message_ref: "1787832000.000100",
      status: status,
      title: "Incident #{n}",
      topic: "Incident",
      workspace_ref: "T123"
    }
    |> Map.merge(fields)
    |> IncidentRoomChangeset.insert()
    |> Repo.insert!()
  end

  defp squeeze(text), do: text |> String.split() |> Enum.join(" ")
end
