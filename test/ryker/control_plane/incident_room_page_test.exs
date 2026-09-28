defmodule Ryker.ControlPlane.IncidentRoomPageTest do
  @moduledoc """
  One incident room's own page, rendered through the projection from the room
  the local demo holds: "Checkout pods fail readiness after deploy", its
  evidence and its progress, harvested from the Compose database on
  2026-09-25 with every time and payload as it was stored.

  Andrew, opening that room: "this page is not very helpful and not designed
  well, just a bunch of text that is hard to read all in one go." It was seven
  labels and values in one column, the latest update as a loose sentence, the
  room's history as bare names over the word "yesterday", and the alert
  channel's raw ID in the middle of the page. A person opening a room during an
  incident needs, in this order: where the room stands, what Ryker says now,
  what it found, what happened to the room, and only then the references.
  """
  use Ryker.DataCase, async: false

  import Ecto.Query

  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{Components, IncidentProjection, IncidentRoomsPage}
  alias Ryker.Episodes.Episode
  alias Ryker.Fixtures.{ChannelEnvironments, SavedEntities}
  alias Ryker.Records
  alias Ryker.Records.Record
  alias Ryker.Slack.{IncidentRoom, IncidentRoomChangeset, IncidentRoomLifecycleEventChangeset}

  # The page is read the morning after the room opened.
  @now ~U[2026-09-25 10:00:00Z]

  @evidence %{
    "claim" => "Kubernetes readiness probe behavior",
    "claim_id" => "citation:ca25e597aef61dbb46e7c1184e55cac2",
    "confidence" => nil,
    "dimensions" => %{},
    "freshness" => nil,
    "health_effect" => nil,
    "observation" =>
      "Readiness failures stop matching Service traffic without restarting the container. Probes repeat throughout its lifecycle; startup probes gate readiness/liveness checks. Initialization and dependency availability can affect readiness; timeoutSeconds defaults to one second.",
    "observed_at" => nil,
    "relation" => "supports",
    "scope_note" => nil,
    "source_id" => "turn0view0",
    "source_name" => "turn0view0",
    "source_type" => "other",
    "supersedes" => [],
    "target" => "Kubernetes readiness probe behavior"
  }

  @progress %{
    "next_due_at" => nil,
    "phase" => "investigating",
    "summary" =>
      "Readiness probes on checkout-api fail after each deploy; new pods never become ready."
  }

  # The longest finding a restored production database holds (2026-09-02).
  @long_finding "Terraform apply succeeded. Post-apply observations at 23:38–23:40 UTC show the portal MIG stable at deployed target 2 with version target reached, both portal backends healthy, and Cloud SQL RUNNABLE. Plan replaces the portal template and updates its MIG/container_image output; no database resources change. Application comparison c57ac8f62e8d63e9a5f5a777430efd4805f7ea7f to 329b4b12dc756bbc31c2e6c9e6c33bbad1bff0f7 fixes sandbox bridge installation guidance and checks. Verification is post-apply, not pre-deployment readiness or full application testing. Runtime image digest/embedded revision, backup completion, hidden attribute values and two omitted drift entries remain unverified."

  # The worker's own words when it closes a room whose channel Slack deleted
  # after telling the alert thread (IncidentRoomWorker.deletion_detail/1).
  @closed_note "Slack deleted the room's channel, so Ryker closed the room and said so in the alert thread it was opened from."

  test "a room's page says where it stands, what Ryker says now, what it found and what happened to the room, in that order" do
    %{room: room, source: source, progress: progress} = demo_room!()
    document = page(room.ref)

    # Where the room stands: its state, when it opened and its channel, on one line.
    status = LazyHTML.query(document, "#incident-room-status")
    assert text(status, ".state-word") == "Open"
    assert text(status, "time") == "opened yesterday at 08:01"

    assert text(status, "a[href='/channels/T0DEMOWORK/C0DEMOROOM1']") ==
             "#inc-checkout-readiness-probes"

    # Its facts in words, two to a line; the alert thread is a way back to the
    # conversation the room was opened from, never its channel's raw ID.
    assert facts(document, "#incident-room-facts") == [
             {"Channel", "#inc-checkout-readiness-probes"},
             {"Who can join", "Anyone in the workspace"},
             {"Opened from", "The alert thread"},
             {"Repository", "acme/checkout-api"},
             {"Opened", "Yesterday at 08:01"},
             {"Last change", "Yesterday at 08:48"}
           ]

    assert text(document, "#incident-room-facts a[href='#{timeline(source.episode.key)}']") ==
             "The alert thread"

    assert LazyHTML.query(document, ".incident-room-facts") |> LazyHTML.attribute("class") == [
             "kit-facts incident-room-facts"
           ]

    # Now: Ryker's latest update, its stage as the state word.
    now = LazyHTML.query(document, "#now")
    assert text(now, "h2") == "Now"
    assert text(now, ".state-word") == "Investigating"
    assert text(now, ".incident-room-now-text") == @progress["summary"]
    assert text(now, "time") == "updated yesterday at 08:48"
    assert text(now, ".incident-room-now-note") == nil

    # Investigation: what Ryker recorded, newest first, each kind with its own
    # tile, the kind as the word and the clock under the day's heading.
    records = rows(document, "#investigation")

    assert Enum.map(records, & &1.name) == [
             "Investigating",
             "Kubernetes readiness probe behavior"
           ]

    assert Enum.map(records, & &1.text) == [@progress["summary"], @evidence["observation"]]
    assert Enum.map(records, & &1.state) == ["Progress", "Evidence"]
    assert Enum.map(records, & &1.icon) == [icon(:activity), icon(:search)]
    assert Enum.map(records, & &1.at) == ["08:48", "08:32"]
    assert Enum.map(records, & &1.group) == ["Yesterday", nil]
    assert Enum.map(records, & &1.more) == [false, false]

    assert text(
             document,
             "#investigation .section-actions a[href='#{timeline(source.episode.key)}']"
           ) ==
             "Open the timeline"

    # Room history: what happened to the room and its channel, oldest first.
    history = rows(document, "#room-history")

    assert Enum.map(history, & &1.name) == [
             "Room requested",
             "Channel created",
             "People invited",
             "Room ready"
           ]

    assert Enum.map(history, & &1.at) == ["08:01", "08:01", "08:02", "08:32"]
    assert Enum.map(history, & &1.group) == ["Yesterday", nil, nil, nil]
    assert Enum.map(history, & &1.meta) == [nil, nil, "1 person", nil]
    assert Enum.all?(history, &is_binary(&1.icon))

    # In that order, with the references last.
    assert document
           |> LazyHTML.query(".incident-room-view > [id]")
           |> LazyHTML.attribute("id") == [
             "incident-room-status",
             "incident-room-facts",
             "now",
             "investigation",
             "room-history",
             "incident-room-details"
           ]

    # References wait in one closed Details, as facts, and nowhere else.
    details = LazyHTML.query(document, "details#incident-room-details:not([open])")
    references = facts(details, ".kit-facts")
    assert {"Room ID", "incident-room:demo-checkout-readiness"} in references
    assert {"Slack workspace ID", "T0DEMOWORK"} in references
    assert {"Channel ID", "C0DEMOROOM1"} in references
    assert {"Opened from channel ID", "C0DEMOALERTS"} in references
    assert {"Offer record ID", progress.ref} in references
    assert {"Investigation request ID", source.episode.key} in references

    outside = document |> LazyHTML.query(".incident-room-view > :not(details)") |> LazyHTML.text()

    for reference <- [
          room.ref,
          "T0DEMOWORK",
          "C0DEMOROOM1",
          "C0DEMOALERTS",
          "U0ANDREW",
          "record:",
          source.episode.key
        ] do
      refute outside =~ reference, "#{reference} is outside Details"
    end

    refute outside =~ ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/
  end

  test "a long record opens in place from three lines, and a short one is whole" do
    %{room: room, source: source, evidence: evidence} = demo_room!()

    {:ok, finding} =
      Records.create(Records.token(source.turn), "demo-finding", "finding", %{
        "cause_evidence" => [evidence.ref],
        "reason" => nil,
        "scope" => "Dryga/emisar run-RZeSjaFKSHETW3WG",
        "status" => "explained",
        "what" => @long_finding
      })

    at!(finding, ~U[2026-09-24 08:52:10.000000Z])

    [long, progress, short] = rows(page(room.ref), "#investigation")

    assert {long.name, long.state, long.icon} == {"Explained", "Finding", icon(:incident)}
    assert long.text =~ "Terraform apply succeeded."
    assert long.text =~ "two omitted drift entries remain unverified."
    assert long.more

    refute progress.more
    refute short.more
  end

  # The page read the first two hundred records oldest first, so a long
  # investigation's page showed the update it gave in its first hour as the
  # latest and never listed anything it recorded after that.
  test "a long investigation still leads with its newest update" do
    %{room: room, source: source} = demo_room!()
    later = ~U[2026-09-24 09:00:00.000000Z]

    Repo.insert_all(
      Record,
      for index <- 1..200 do
        record(source, "evidence", "later-#{index}", @evidence, DateTime.add(later, index))
      end
    )

    Repo.insert_all(Record, [
      record(
        source,
        "progress",
        "newest-progress",
        %{
          "next_due_at" => nil,
          "phase" => "mitigating",
          "summary" => "The probe timeout is raised; new pods become ready."
        },
        DateTime.add(later, 3_600)
      )
    ])

    document = page(room.ref)
    assert text(document, "#now .state-word") == "Mitigating"

    assert text(document, "#now .incident-room-now-text") ==
             "The probe timeout is raised; new pods become ready."

    assert [%{name: "Mitigating", at: "10:00"} | _older] = rows(document, "#investigation")
  end

  test "a room whose channel was archived says the investigation is paused until the channel is back" do
    %{room: room} = demo_room!()
    archived_at = ~U[2026-09-25 09:15:00.000000Z]
    lifecycle!(room, :archived, archived_at)

    Repo.update_all(from(saved in IncidentRoom, where: saved.id == ^room.id),
      set: [
        channel_state: :archived,
        channel_state_changed_at: archived_at,
        channel_state_event_ref: "incident-lifecycle:archived",
        reconciled_channel_state: :archived
      ]
    )

    # The sentence under the title said "Ryker works on the incident there"
    # about a channel nobody could post in.
    assert description(room.ref) ==
             "The room's channel is archived in Slack, so Ryker's work in it is paused."

    document = page(room.ref)
    assert text(document, "#now .state-word") == "Paused"
    assert text(document, "#now .incident-room-now-text") == @progress["summary"]

    assert text(document, "#now .incident-room-now-note") ==
             "The channel is archived, so Ryker paused the investigation; its reply waits until someone restores the channel in Slack."

    assert {"Channel", "#inc-checkout-readiness-probes · archived"} in facts(
             document,
             "#incident-room-facts"
           )

    # The archive replaced when the channel was created, so that one keeps its
    # place after the request without a time.
    history = rows(document, "#room-history")

    assert Enum.map(history, &{&1.name, &1.at, &1.group}) == [
             {"Room requested", "08:01", "Yesterday"},
             {"Channel created", nil, nil},
             {"People invited", "08:02", nil},
             {"Room ready", "08:32", nil},
             {"Channel archived", "09:15", "Today"}
           ]
  end

  # Ryker left the channel, or Slack stopped letting it in. Its replies wait
  # for the channel, and the sentence under the title still said Ryker worked
  # there with the team.
  test "a room whose channel Ryker cannot reach says its work there is paused" do
    %{room: room} = demo_room!()
    left_at = ~U[2026-09-25 09:15:00.000000Z]
    lifecycle!(room, :left, left_at)

    Repo.update_all(from(saved in IncidentRoom, where: saved.id == ^room.id),
      set: [
        channel_state: :unavailable,
        channel_state_changed_at: left_at,
        channel_state_event_ref: "incident-lifecycle:left",
        reconciled_channel_state: :unavailable
      ]
    )

    assert description(room.ref) ==
             "Ryker cannot reach the room's channel in Slack, so its work in it is paused."

    document = page(room.ref)
    assert text(document, "#incident-room-status .state-word") == "Open"
    assert text(document, "#now .state-word") == "Paused"

    assert text(document, "#now .incident-room-now-note") ==
             "Ryker cannot reach the channel, so it paused the investigation; its reply waits until Ryker can post there again."

    assert {"Channel", "#inc-checkout-readiness-probes · Ryker cannot reach it"} in facts(
             document,
             "#incident-room-facts"
           )

    assert document |> rows("#room-history") |> List.last() |> Map.take([:name, :at, :group]) ==
             %{name: "Ryker left the channel", at: "09:15", group: "Today"}
  end

  test "a closed room says so and where Ryker's note went" do
    %{room: room} = demo_room!()
    deleted_at = ~U[2026-09-25 09:20:00.000000Z]
    closed_at = ~U[2026-09-25 09:21:30.000000Z]
    lifecycle!(room, :deleted, deleted_at)

    Repo.update_all(from(saved in IncidentRoom, where: saved.id == ^room.id),
      set: [
        channel_state: :deleted,
        channel_state_changed_at: deleted_at,
        channel_state_event_ref: "incident-lifecycle:deleted",
        last_error_code: "incident_room_deleted",
        last_error_detail: @closed_note,
        reconciled_channel_state: :deleted,
        status: :closed,
        updated_at: closed_at
      ]
    )

    document = page(room.ref)
    assert text(document, "#incident-room-status .state-word") == "Closed"
    assert text(document, "#now .state-word") == "Closed"
    assert text(document, "#now .incident-room-now-note") == @closed_note

    assert document |> rows("#room-history") |> Enum.take(-2) |> Enum.map(&{&1.name, &1.at}) ==
             [{"Channel deleted", "09:20"}, {"Room closed", "09:21"}]
  end

  # A room's saved error is the Slack or worker failure behind it, which only
  # the Failures page explains; the one thing the page reads from that column
  # is the note Ryker wrote when it closed a room whose channel was deleted.
  test "a room whose setup stopped points to what stopped it and never prints its saved error" do
    source = SavedEntities.source!("slack:T0DEMOWORK:C0DEMOALERTS")

    {:ok, offer} =
      Records.create(Records.token(source.turn), "incident-room-offer", "progress", @progress)

    room =
      room_attributes(source, offer)
      |> Map.merge(%{
        audience_prepared_at: nil,
        channel_ref: nil,
        channel_state: :pending,
        channel_state_changed_at: nil,
        episode_id: nil,
        handoff_message_ref: nil,
        last_error_code: "incident_audience_member_invalid",
        last_error_detail: "private-invite-failure-detail",
        reconciled_channel_state: :pending,
        root_card_fingerprint: nil,
        root_card_ui_revision: 0,
        root_message_ref: nil,
        root_pinned_at: nil,
        status: :blocked,
        topic_prepared_at: nil
      })
      |> IncidentRoomChangeset.insert()
      |> Repo.insert!()

    stopped_at = ~U[2026-09-24 08:03:12.000000Z]

    Repo.update_all(from(saved in IncidentRoom, where: saved.id == ^room.id),
      set: [updated_at: stopped_at]
    )

    document = page(room.ref)
    assert text(document, "#incident-room-status .state-word") == "Needs attention"

    assert text(
             document,
             "#incident-room-status a[href='/failures/slack_incident/incident-room%3Ademo-checkout-readiness']"
           ) == "See what stopped"

    assert {"Channel", "Not created yet"} in facts(document, "#incident-room-facts")
    assert text(document, "#now .kit-empty-title") == "No update yet"

    assert text(document, "#investigation .kit-empty-title") ==
             "The investigation has not started"

    # When setup stopped is the room's last step, not when it was requested.
    assert Enum.map(rows(document, "#room-history"), &{&1.name, &1.at}) == [
             {"Room requested", "08:01"},
             {"Setup stopped", "08:03"}
           ]

    assert {"Last change", "Yesterday at 08:03"} in facts(document, "#incident-room-facts")
    refute LazyHTML.to_html(document) =~ "private-invite-failure-detail"
  end

  # A room works where the conversation it was opened from worked: an
  # environment (its Emisar account and repositories) and the repository its
  # code changes go to. The page named only the repository, so a room opened in
  # Production read the same as one opened in Staging.
  test "a room opened in an environment names the environment and the repository in one fact" do
    ChannelEnvironments.environment!("production")
    %{room: room} = demo_room!(%{environment_ref: "production"})
    room_facts = facts(page(room.ref), "#incident-room-facts")

    assert {"Environment", "Production · acme/checkout-api"} in room_facts
    refute Enum.any?(room_facts, &match?({"Repository", _value}, &1))
    assert length(room_facts) == 6
  end

  defp page(ref) do
    assert {:ok, snapshot} = IncidentProjection.fetch(ref)

    snapshot
    |> IncidentRoomsPage.detail(@now)
    |> IO.iodata_to_binary()
    |> LazyHTML.from_fragment()
  end

  defp description(ref) do
    assert {:ok, snapshot} = IncidentProjection.fetch(ref)
    IncidentRoomsPage.summary(snapshot.room)
  end

  defp rows(document, section) do
    document
    |> LazyHTML.query(section <> " .entity-row")
    |> Enum.map(fn row ->
      %{
        at: text(row, ".entity-at"),
        group: text(row, ".entity-group"),
        icon:
          row |> LazyHTML.query(".entity-icon path") |> LazyHTML.attribute("d") |> List.first(),
        meta: text(row, ".entity-meta"),
        more:
          LazyHTML.query(row, "details.incident-room-more:not([open]) summary") |> Enum.any?(),
        name: text(row, ".entity-name"),
        state: text(row, ".entity-side .state-word"),
        text: text(row, ".entity-text")
      }
    end)
  end

  defp facts(document, selector) do
    document
    |> LazyHTML.query(selector <> " > div")
    |> Enum.map(&{text(&1, "dt"), text(&1, "dd")})
  end

  defp text(document, selector) do
    case document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim() do
      "" -> nil
      text -> String.replace(text, ~r/\s+/, " ")
    end
  end

  defp icon(name) do
    %{__changed__: nil, name: name}
    |> Components.icon()
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("path")
    |> LazyHTML.attribute("d")
    |> List.first()
  end

  defp timeline(key), do: "/timeline/" <> URI.encode(key, &URI.char_unreserved?/1)

  # The demo room as the Compose database holds it: opened from the alert
  # thread in #demo-alerts, investigated in that same request, with the
  # evidence and the progress it recorded.
  defp demo_room!(overrides \\ %{}) do
    source = SavedEntities.source!("slack:T0DEMOWORK:C0DEMOALERTS")
    token = Records.token(source.turn)
    {:ok, evidence} = Records.create(token, "demo-evidence", "evidence", @evidence)
    {:ok, progress} = Records.create(token, "incident-room-offer", "progress", @progress)
    at!(evidence, ~U[2026-09-24 08:32:55.973370Z])
    at!(progress, ~U[2026-09-24 08:48:41.555258Z])

    Repo.update_all(from(episode in Episode, where: episode.id == ^source.episode.id),
      set: [inserted_at: ~U[2026-09-24 08:32:15.454880Z]]
    )

    room =
      source
      |> room_attributes(progress)
      |> Map.merge(overrides)
      |> IncidentRoomChangeset.insert()
      |> Repo.insert!()

    Repo.update_all(from(saved in IncidentRoom, where: saved.id == ^room.id),
      set: [
        inserted_at: ~U[2026-09-24 08:48:41.570821Z],
        updated_at: ~U[2026-09-24 08:48:41.570821Z]
      ]
    )

    %{evidence: evidence, progress: progress, room: room, source: source}
  end

  defp room_attributes(source, offer) do
    %{
      attempt_count: 1,
      audience_prepared_at: ~U[2026-09-24 08:02:01.568655Z],
      bot_user_ref: "U0RYKERBOT",
      channel_checked_at: ~U[2026-09-24 08:46:41.568655Z],
      channel_name: "inc-checkout-readiness-probes",
      channel_ref: "C0DEMOROOM1",
      channel_state: :active,
      channel_state_changed_at: ~U[2026-09-24 08:01:53.568655Z],
      confirmation_ref: "incident-confirmation:demo-room",
      episode_id: source.episode.id,
      handoff_message_ref: "1790001234.000200",
      id: Ecto.UUID.generate(),
      invite_user_group_refs: [],
      invite_user_refs: ["U0ANDREW"],
      policy: "ryker-incident",
      policy_digest: String.duplicate("c", 64),
      private: false,
      prompt:
        "Readiness probes on checkout-api fail after each deploy and new pods never become ready. Find the cause and propose a fix.",
      reconciled_channel_state: :active,
      record_id: offer.id,
      ref: "incident-room:demo-checkout-readiness",
      repository_ref: "acme/checkout-api",
      requested_at: ~U[2026-09-24 08:01:41.568655Z],
      requested_by_actor_ref: "U0ANDREW",
      root_card_fingerprint: String.duplicate("f", 64),
      root_card_ui_revision: 1,
      root_message_ref: "1790001234.000100",
      root_pinned_at: ~U[2026-09-24 08:02:06.568655Z],
      source_channel_ref: "C0DEMOALERTS",
      source_episode_id: source.episode.id,
      source_message_ref: "1790001200.000100",
      status: :ready,
      title: "Checkout pods fail readiness after deploy",
      topic: "Checkout pods fail readiness after deploy · investigating",
      topic_prepared_at: ~U[2026-09-24 08:02:03.568655Z],
      workspace_ref: "T0DEMOWORK"
    }
  end

  defp record(source, kind, operation, payload, at) do
    %{
      episode_id: source.episode.id,
      id: Ecto.UUID.generate(),
      inserted_at: at,
      kind: kind,
      operation_id: operation,
      payload: payload,
      payload_fingerprint: String.duplicate("e", 64),
      ref: "record:#{kind}:#{operation}",
      status: :open,
      turn_id: source.turn.id,
      updated_at: at
    }
  end

  defp at!(%Record{id: id}, at) do
    Repo.update_all(from(record in Record, where: record.id == ^id),
      set: [inserted_at: at, updated_at: at]
    )
  end

  defp lifecycle!(room, kind, at) do
    %{
      channel_ref: room.channel_ref,
      event_fingerprint: String.duplicate("d", 64),
      event_ref: "incident-lifecycle:#{kind}",
      id: Ecto.UUID.generate(),
      kind: kind,
      occurred_at: at,
      room_id: room.id,
      workspace_ref: room.workspace_ref
    }
    |> IncidentRoomLifecycleEventChangeset.insert()
    |> Repo.insert!()
  end
end
