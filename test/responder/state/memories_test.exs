defmodule Responder.State.MemoriesTest do
  use Responder.DataCase, async: false

  import Ecto.Query

  alias Responder.Episodes
  alias Responder.Fixtures.DatabaseClock
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures

  alias Responder.Slack.{
    AppHomeEditor,
    AppHomeProjection,
    ChannelConfigurations,
    ChannelMembership
  }

  alias Responder.State.{
    Behavior,
    BehaviorChangeset,
    Behaviors,
    Memories,
    MemoryEntry,
    MemoryReviewItem,
    MemorySearchPage,
    Record,
    Records
  }

  alias Responder.Work.{Custody, DeliveryReceipt, Result, Submission, Turn}

  @now ~U[2026-08-28 12:00:00.000000Z]

  defmodule ModalAPI do
    def open_view(observer, trigger_ref, view) do
      send(observer, {:opened_memory_modal, trigger_ref, view})
      :ok
    end
  end

  test "confirmed facts remain searchable when the database clock trails the host" do
    # The cursor's database cutoff hid fresh confirmations stamped by Ecto's
    # ahead-of-database host clock. Historical confirmation and expiry are distinct.
    fixture = delivered_offers!("database-clock-fact")
    database_time = DatabaseClock.behind_host!()
    assert {:ok, confirmed} = Memories.confirm(confirmation(fixture, fixture.first, "clock"))

    context = %{
      conversation_ref: "slack:T123:C456",
      repository: nil,
      workspace_ref: "slack:T123"
    }

    assert [match] = Memories.search(context, "responder", "current_channel", 20)
    assert match["memory_ref"] == confirmed.memory.ref
    assert confirmed.memory.inserted_at == database_time
    assert confirmed.memory.updated_at == database_time
    assert confirmed.memory.confirmed_at == @now
    assert confirmed.memory.expires_at == DateTime.add(@now, 90 * 86_400, :second)

    page = MemorySearchPage.first("responder", "current_channel")

    assert :done =
             Memories.search_page(context, %{page | cutoff: DateTime.add(database_time, -1)})
  end

  test "operator fact edits use database time without entering an older search snapshot" do
    fixture = delivered_offers!("database-clock-edit")
    assert {:ok, confirmed} = Memories.confirm(confirmation(fixture, fixture.first, "edit-clock"))
    database_time = DatabaseClock.behind_host!()
    old = DateTime.add(database_time, -120, :second)
    Repo.update_all(MemoryEntry, set: [inserted_at: old, updated_at: old])
    assert {:ok, %{created: 1}} = Memories.refresh_reviews("slack:T123", 60)
    [review] = Memories.list_reviews("slack:T123")

    assert {:ok, _} =
             Memories.resolve_review(
               review["review_ref"],
               :edit,
               "slack:user:operator",
               "slack:T123",
               %{"subject" => "primary_repository", "value" => "responder-elixir"}
             )

    context = %{
      conversation_ref: "slack:T123:C456",
      repository: nil,
      workspace_ref: "slack:T123"
    }

    page = MemorySearchPage.first("responder-elixir", "current_channel")

    assert :done =
             Memories.search_page(context, %{page | cutoff: DateTime.add(database_time, -1)})

    edited = Repo.get!(MemoryEntry, confirmed.memory.id)
    assert edited.edited_at == database_time
    assert edited.inserted_at == old
    assert edited.confirmed_at == confirmed.memory.confirmed_at
    assert edited.expires_at == confirmed.memory.expires_at
    assert {:ok, match, _position} = Memories.search_page(context, page)
    assert match["memory_ref"] == confirmed.memory.ref
  end

  test "confirmed operational memory is scoped, provenance-bearing, replaceable, and forgettable" do
    fixture = delivered_offers!("lifecycle")

    assert {:ok, first} =
             Memories.confirm(confirmation(fixture, fixture.first, "first"))

    assert first.status == :confirmed
    assert first.memory.kind == :repository_binding
    assert first.memory.scope_kind == :conversation
    assert first.memory.scope_ref == "slack:T123:C456"
    assert first.memory.payload["value"] == "responder"

    context = %{
      conversation_ref: "slack:T123:C456",
      repository: nil,
      workspace_ref: "slack:T123"
    }

    assert [recalled] = Memories.recall(context)
    assert recalled["memory_ref"] == first.memory.ref
    assert recalled["value"] == "responder"
    assert recalled["source"]["message_ref"] == fixture.receipt["message_ref"]

    refute inspect(recalled) =~ "confirmation_ref"
    assert Memories.recall(%{context | conversation_ref: "slack:T123:C999"}) == []

    first_recalled = Repo.get!(MemoryEntry, first.memory.id)
    assert first_recalled.recall_count == 1
    assert %DateTime{} = first_recalled.last_recalled_at

    assert {:ok, replacement} =
             Memories.confirm(confirmation(fixture, fixture.replacement, "replacement"))

    assert replacement.memory.payload["value"] == "responder-next"

    superseded = Repo.get!(MemoryEntry, first.memory.id)
    assert superseded.status == :superseded
    assert superseded.payload == %{"replaced_payload_sha256" => first.memory.payload_fingerprint}
    refute inspect(superseded.payload) =~ "responder"
    assert Memories.forget(first.memory.ref) == {:error, :memory_terminal}

    assert [latest] = Memories.recall(context)
    assert latest["memory_ref"] == replacement.memory.ref
    assert latest["value"] == "responder-next"

    assert Memories.forget(replacement.memory.ref, "slack:T999") ==
             {:error, :memory_workspace_mismatch}

    assert Repo.get!(MemoryEntry, replacement.memory.id).status == :active

    assert {:ok, forgotten} = Memories.forget(replacement.memory.ref, "slack:T123")
    assert forgotten.status == :deleted
    assert forgotten.payload["forgotten_payload_sha256"] == replacement.memory.payload_fingerprint
    refute inspect(forgotten.payload) =~ "responder-next"
    assert Memories.recall(context) == []

    assert {:ok, duplicate_forget} = Memories.forget(replacement.memory.ref, "slack:T123")
    assert duplicate_forget.id == forgotten.id
  end

  test "explicit workspace visibility recalls across conversations while crossed controls fail closed" do
    fixture = delivered_offers!("visibility")

    assert {:ok, workspace} =
             Memories.confirm(confirmation(fixture, fixture.workspace, "workspace"))

    assert workspace.memory.visibility == :workspace

    assert [entry] =
             Memories.recall(%{
               conversation_ref: "slack:T123:C999",
               repository: nil,
               workspace_ref: "slack:T123"
             })

    assert entry["subject"] == "checkout_service"
    assert entry["value"] == "The checkout API is owned by Payments."

    crossed =
      fixture
      |> confirmation(fixture.first, "crossed")
      |> put_in([:target, :message_ref], "1787832999.999999")

    assert Memories.confirm(crossed) == {:error, :memory_offer_delivery_mismatch}

    Repo.update_all(
      from(record in Record, where: record.id == ^fixture.first.id),
      set: [status: :dismissed]
    )

    assert Memories.confirm(confirmation(fixture, fixture.first, "stale")) ==
             {:error, :memory_offer_stale}
  end

  test "a memory offer delivered to a joined input's origin thread can be confirmed from that thread" do
    # Found live 2026-09-11: routing delivered a correction card to the joined
    # root's thread and the Save press was refused as "no longer current"; a
    # human sees the same.
    fixture = delivered_offers!("routed", "1787832500.000700")

    assert fixture.episode.destination_thread_ref == "1787832000.000100"
    assert fixture.receipt["thread_ref"] == "1787832500.000700"

    assert {:ok, confirmed} = Memories.confirm(confirmation(fixture, fixture.first, "routed"))
    assert confirmed.status == :confirmed
    assert confirmed.memory.payload["value"] == "responder"

    # A fact's source is the card it was saved from, so the recorded thread has
    # to be the one holding the recorded message.
    assert confirmed.memory.source_thread_ref == "1787832500.000700"
    assert confirmed.memory.source_message_ref == fixture.receipt["message_ref"]

    # The card is still only confirmable where it was delivered.
    elsewhere =
      fixture
      |> confirmation(fixture.workspace, "routed-elsewhere")
      |> put_in([:target, :thread_ref], fixture.episode.destination_thread_ref)

    assert Memories.confirm(elsewhere) == {:error, :memory_offer_delivery_mismatch}
  end

  test "memory listing, expiry, and forget controls never widen scope" do
    fixture = delivered_offers!("bounded")
    assert {:ok, confirmed} = Memories.confirm(confirmation(fixture, fixture.first, "bounded"))

    assert [listed] = Memories.list("slack:T123")
    assert listed.ref == confirmed.memory.ref
    assert [active] = Memories.list("slack:T123", status: :active)
    assert active.ref == confirmed.memory.ref
    assert Memories.list("", status: :active) == []
    assert Memories.list("slack:T123", status: :unknown) == []
    assert Memories.list("slack:T123", extra: true) == []
    assert Memories.list("slack:T123", :not_options) == []

    assert Memories.recall(:invalid, 20) == []
    assert Memories.recall(%{}, 20) == []
    assert Memories.recall(%{}, 0) == []
    assert Memories.model_context(%{}, nil) == []

    Repo.update_all(
      from(entry in MemoryEntry, where: entry.id == ^confirmed.memory.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    context = %{
      conversation_ref: "slack:T123:C456",
      repository: nil,
      workspace_ref: "slack:T123"
    }

    assert Memories.recall(context) == []
    assert Repo.get!(MemoryEntry, confirmed.memory.id).status == :active
    assert {:ok, deleted} = Memories.forget(confirmed.memory.ref)
    assert deleted.status == :deleted
    assert Memories.forget("missing-memory") == {:error, :memory_not_found}
    assert {:error, _reason} = Memories.forget("")
  end

  test "App Home memory count does not disclose conversation-private entries" do
    fixture = delivered_offers!("home-count-privacy")
    assert {:ok, private} = Memories.confirm(confirmation(fixture, fixture.first, "private"))

    assert {:ok, workspace} =
             Memories.confirm(confirmation(fixture, fixture.workspace, "workspace"))

    snapshot = AppHomeProjection.snapshot("T123", "U123", MapSet.new(["C456"]))

    assert snapshot.counts.active_memory == 1
    assert Enum.any?(snapshot.memories, &(&1.ref == workspace.memory.ref))
    refute Enum.any?(snapshot.memories, &(&1.ref == private.memory.ref))
  end

  test "malformed memory confirmations fail before durable state changes" do
    assert {:error, _reason} = Memories.confirm(%{})
    assert {:error, _reason} = Memories.confirm(actor_ref: "a", actor_ref: "b")

    invalid_target = %{
      actor_ref: "slack:user:U123",
      confirmation_ref: "interaction:invalid",
      occurred_at: "not-a-time",
      record_ref: "record:missing",
      target: %{}
    }

    assert {:error, _reason} = Memories.confirm(invalid_target)
  end

  test "memory review APIs reject malformed requests and out-of-transaction maintenance" do
    assert Memories.search(:invalid, "query", "workspace", 20) == []
    assert Memories.search(%{}, "query", "workspace", 20) == []
    assert Memories.search(%{}, "query", "workspace", 0) == []

    assert Memories.refresh_reviews("slack:T123", 0) ==
             {:error, {:invalid_memory_review, :stale_seconds}}

    assert Memories.refresh_all_reviews_in_transaction(86_400) ==
             {:error, :memory_review_transaction_required}

    assert Memories.refresh_all_reviews_in_transaction(0) ==
             {:error, {:invalid_memory_review, :stale_seconds}}

    assert Memories.dismiss_invalid_reviews_in_transaction() ==
             {:error, :memory_review_transaction_required}

    assert Memories.list_reviews("", limit: 20) == []
    assert Memories.list_reviews("slack:T123", :invalid) == []
    assert Memories.home_reviews("", "slack:user:U123") == %{items: [], total: 0}
    assert Memories.home_review_count("", "slack:user:U123") == 0
    assert Memories.pending_reviews(0) == []
    assert Memories.fetch_review("") == :error
    assert Memories.fetch_review("memory-review:missing") == :error

    assert Memories.fetch_home_review("", "slack:T123", "slack:user:U123") ==
             {:error, :memory_review_not_found}

    assert Memories.resolve_review(
             "memory-review:missing",
             :invalid,
             "slack:user:U123",
             "slack:T123"
           ) == {:error, {:invalid_memory_review, :action}}

    assert Memories.resolve_review(
             "memory-review:missing",
             :edit,
             "slack:user:U123",
             "slack:T123"
           ) == {:error, {:invalid_memory_review, :replacement}}

    assert Memories.resolve_review(
             "memory-review:missing",
             :keep,
             "slack:user:U123",
             "slack:T123"
           ) == {:error, :memory_review_not_found}

    assert Memories.resolve_review(
             "memory-review:missing",
             :keep,
             "slack:user:U123",
             "slack:T123",
             %{}
           ) == {:error, {:invalid_memory_review, :replacement}}

    assert Memories.delete_slack_channel_in_transaction("T123", "C456") ==
             {:error, :memory_review_transaction_required}

    assert Memories.delete_slack_channel_in_transaction(nil, nil) ==
             {:error, {:invalid_memory_review, :conversation}}
  end

  test "memory review keep edit merge and forget are scoped and idempotently audited" do
    fixture = delivered_offers!("reviews")

    assert {:ok, first} = Memories.confirm(confirmation(fixture, fixture.first, "review-first"))

    assert {:ok, guidance} =
             Behaviors.confirm(confirmation(fixture, fixture.guidance, "review-guidance"))

    assert {:ok, guidance_duplicate} =
             Behaviors.confirm(
               confirmation(fixture, fixture.guidance_duplicate, "review-guidance-duplicate")
             )

    old = DateTime.add(DateTime.utc_now(), -3_600, :second)

    Repo.update_all(MemoryEntry,
      set: [last_recalled_at: nil, last_reviewed_at: nil, updated_at: old]
    )

    Repo.update_all(Behavior,
      set: [last_used_at: nil, last_reviewed_at: nil, updated_at: old]
    )

    assert {:ok, %{created: 4}} = Memories.refresh_reviews("slack:T123", 60)
    assert {:ok, %{created: 0}} = Memories.refresh_reviews("slack:T123", 60)

    reviews = Memories.list_reviews("slack:T123", limit: 10)
    assert length(reviews) == 4
    assert duplicate_review = Enum.find(reviews, &(&1["kind"] == "duplicate"))

    assert Enum.all?(duplicate_review["entries"], &(&1["source_type"] == "guidance"))

    assert Enum.all?(duplicate_review["entries"], fn entry ->
             entry["scope"] == "workspace" and entry["scope_ref"] == "slack:T123" and
               entry["visibility"] == "workspace"
           end)

    assert Enum.map(duplicate_review["entries"], & &1["value"]) ==
             List.duplicate("Always lead with the outcome.", 2)

    stale_first =
      Enum.find(reviews, fn review ->
        review["kind"] == "stale" and
          Enum.any?(review["entries"], &(&1["memory_ref"] == first.memory.ref))
      end)

    assert {:ok, kept} =
             Memories.resolve_review(
               stale_first["review_ref"],
               :keep,
               "slack:user:operator",
               "slack:T123"
             )

    assert kept.review["status"] == "kept"

    Repo.update_all(from(entry in Behavior, where: entry.id == ^guidance.behavior.id),
      set: [updated_at: DateTime.add(old, 1, :second)]
    )

    Repo.update_all(from(entry in Behavior, where: entry.id == ^guidance_duplicate.behavior.id),
      set: [updated_at: DateTime.add(old, 2, :second)]
    )

    assert {:ok, merged} =
             Memories.resolve_review(
               duplicate_review["review_ref"],
               :merge,
               "slack:user:operator",
               "slack:T123"
             )

    assert merged.status == :resolved
    assert merged.review["status"] == "applied"

    duplicate_entries = [guidance.behavior.id, guidance_duplicate.behavior.id]

    assert Repo.aggregate(
             from(entry in Behavior,
               where: entry.id in ^duplicate_entries and entry.status == :active
             ),
             :count
           ) == 1

    assert Repo.get!(Behavior, guidance.behavior.id).status == :superseded
    assert Repo.get!(Behavior, guidance_duplicate.behavior.id).status == :active

    assert {:ok, %{status: :duplicate}} =
             Memories.resolve_review(
               duplicate_review["review_ref"],
               :merge,
               "slack:user:operator",
               "slack:T123"
             )

    assert {:error, :memory_review_conflict} =
             Memories.resolve_review(
               duplicate_review["review_ref"],
               :keep,
               "slack:user:operator",
               "slack:T123"
             )

    Repo.update_all(
      from(entry in MemoryEntry, where: entry.id == ^first.memory.id),
      set: [
        last_recalled_at: nil,
        last_reviewed_at: DateTime.add(old, 1, :second),
        updated_at: DateTime.add(old, 1, :second)
      ]
    )

    assert {:ok, %{created: 1}} = Memories.refresh_reviews("slack:T123", 60)

    stale_first =
      Memories.list_reviews("slack:T123", limit: 10)
      |> Enum.find(fn review ->
        Enum.any?(review["entries"], &(&1["memory_ref"] == first.memory.ref))
      end)

    assert {:ok, edited} =
             Memories.resolve_review(
               stale_first["review_ref"],
               :edit,
               "slack:user:operator",
               "slack:T123",
               %{"subject" => "primary_codebase", "value" => "responder-elixir"}
             )

    assert edited.review["status"] == "applied"
    edited_memory = Repo.get!(MemoryEntry, first.memory.id)
    assert edited_memory.subject == "primary_codebase"
    assert edited_memory.payload["subject"] == "primary_codebase"
    assert edited_memory.payload["value"] == "responder-elixir"
    assert edited_memory.edited_by_actor_ref == "slack:user:operator"
    assert edited_memory.edit_review_ref == stale_first["review_ref"]
    assert %DateTime{} = edited_memory.last_reviewed_at

    assert [edited_document] =
             Memories.search(
               %{
                 conversation_ref: "slack:T123:C456",
                 repository: nil,
                 workspace_ref: "slack:T123"
               },
               "responder-elixir",
               "current_channel",
               20
             )

    assert edited_document["edit"]["actor_ref"] == "slack:user:operator"
    assert edited_document["edit"]["review_ref"] == stale_first["review_ref"]

    edit_audit = Repo.get_by!(MemoryReviewItem, ref: stale_first["review_ref"])
    assert %{"replacement_payload_sha256" => replacement_digest} = edit_audit.replacement
    assert byte_size(replacement_digest) == 64
    refute inspect(edit_audit.replacement) =~ "responder-elixir"

    Repo.update_all(
      from(entry in MemoryEntry, where: entry.id == ^first.memory.id),
      set: [
        last_recalled_at: nil,
        last_reviewed_at: DateTime.add(old, 2, :second),
        updated_at: DateTime.add(old, 2, :second)
      ]
    )

    assert {:ok, %{created: 1}} = Memories.refresh_reviews("slack:T123", 60)

    forget_review =
      Memories.list_reviews("slack:T123", limit: 10)
      |> Enum.find(fn review ->
        Enum.any?(review["entries"], &(&1["memory_ref"] == first.memory.ref))
      end)

    assert {:ok, forgotten} =
             Memories.resolve_review(
               forget_review["review_ref"],
               :forget,
               "slack:user:operator",
               "slack:T123"
             )

    assert forgotten.review["status"] == "applied"

    assert Repo.aggregate(
             from(review in MemoryReviewItem, where: review.status == :pending),
             :count
           ) == 0

    assert Memories.list_reviews("slack:T999", limit: 10) == []

    assert {:error, :memory_review_workspace_mismatch} =
             Memories.resolve_review(
               forget_review["review_ref"],
               :forget,
               "slack:user:operator",
               "slack:T999"
             )
  end

  test "a changed review source rejects the stale confirmation" do
    fixture = delivered_offers!("stale-review")
    assert {:ok, confirmed} = Memories.confirm(confirmation(fixture, fixture.first, "stale"))
    old = DateTime.add(DateTime.utc_now(), -3_600, :second)

    Repo.update_all(from(entry in MemoryEntry, where: entry.id == ^confirmed.memory.id),
      set: [updated_at: old]
    )

    assert {:ok, %{created: 1}} = Memories.refresh_reviews("slack:T123", 60)
    [review] = Memories.list_reviews("slack:T123", limit: 10)

    Repo.update_all(from(entry in MemoryEntry, where: entry.id == ^confirmed.memory.id),
      set: [last_recalled_at: DateTime.utc_now()]
    )

    assert Memories.resolve_review(
             review["review_ref"],
             :forget,
             "slack:user:operator",
             "slack:T123"
           ) == {:error, :memory_review_stale}

    assert Repo.get!(MemoryEntry, confirmed.memory.id).status == :active
  end

  test "Slack App Home omits and cannot resolve channel-only reviews" do
    fixture = delivered_offers!("home-privacy")

    assert {:ok, conversation} =
             Memories.confirm(confirmation(fixture, fixture.first, "home-conversation"))

    assert {:ok, workspace} =
             Memories.confirm(confirmation(fixture, fixture.workspace, "home-workspace"))

    old = DateTime.add(DateTime.utc_now(), -3_600, :second)
    Repo.update_all(MemoryEntry, set: [updated_at: old])

    assert {:ok, %{created: 2}} = Memories.refresh_reviews("slack:T123", 60)

    hidden_review_ids =
      Enum.map(1..101, fn index ->
        id = Ecto.UUID.generate()

        Repo.insert!(%MemoryReviewItem{
          entry_refs: [conversation.memory.ref],
          id: id,
          kind: :stale,
          reason: "Hidden channel review #{index}",
          ref: "memory-review:hidden:#{id}",
          source_digest: Responder.CanonicalJSON.digest(%{"hidden_review" => index}),
          status: :pending,
          workspace_ref: "slack:T123"
        })

        id
      end)

    Repo.update_all(
      from(review in MemoryReviewItem, where: review.id in ^hidden_review_ids),
      set: [inserted_at: DateTime.add(old, -1, :second), updated_at: old]
    )

    assert %{items: [visible], total: 1} =
             Memories.home_reviews("slack:T123", "slack:user:U123", limit: 5)

    assert [^visible] =
             Memories.list_home_reviews("slack:T123", "slack:user:U123", limit: 5)

    assert get_in(visible, ["entries", Access.at(0), "memory_ref"]) == workspace.memory.ref
    assert Memories.home_review_count("slack:T123", "slack:user:U123") == 1

    assert {:ok, fetched} =
             Memories.fetch_home_review(
               visible["review_ref"],
               "slack:T123",
               "slack:user:U123"
             )

    assert fetched["review_ref"] == visible["review_ref"]

    assert :ok =
             AppHomeEditor.open_memory_review(
               ModalAPI,
               self(),
               visible["review_ref"],
               "trigger.home-memory",
               "slack:user:U123",
               "slack:T123"
             )

    assert_received {:opened_memory_modal, "trigger.home-memory", %{"type" => "modal"}}

    hidden =
      Memories.list_reviews("slack:T123", limit: 5)
      |> Enum.find(fn review ->
        get_in(review, ["entries", Access.at(0), "memory_ref"]) == conversation.memory.ref
      end)

    assert Memories.fetch_home_review(
             hidden["review_ref"],
             "slack:T123",
             "slack:user:U123"
           ) == {:error, :memory_review_not_found}

    assert AppHomeEditor.open_memory_review(
             ModalAPI,
             self(),
             hidden["review_ref"],
             "trigger.hidden-memory",
             "slack:user:U123",
             "slack:T123"
           ) == {:error, :memory_review_not_found}

    assert Memories.resolve_home_review(
             hidden["review_ref"],
             :forget,
             "slack:user:U123",
             "slack:T123"
           ) == {:error, :memory_review_unauthorized}

    assert Memories.forget_home(
             conversation.memory.ref,
             "slack:user:U123",
             "slack:T123"
           ) == {:error, :memory_unauthorized}

    assert Repo.get!(MemoryEntry, conversation.memory.id).status == :active

    edited_subject = String.duplicate("é", 120)
    edited_value = String.duplicate("🙂", 4_000)

    assert {:ok, %{status: :resolved}} =
             Memories.resolve_home_review(
               visible["review_ref"],
               :edit,
               "slack:user:U123",
               "slack:T123",
               %{"subject" => edited_subject, "value" => edited_value}
             )

    edited_workspace = Repo.get!(MemoryEntry, workspace.memory.id)
    assert edited_workspace.subject == edited_subject
    assert edited_workspace.payload["value"] == edited_value

    assert Memories.forget_home(
             "memory:missing",
             "slack:user:U123",
             "slack:T123"
           ) == {:error, :memory_not_found}

    assert Memories.forget_home(
             workspace.memory.ref,
             "slack:user:U123",
             "slack:T999"
           ) == {:error, :memory_workspace_mismatch}

    assert {:ok, forgotten_workspace} =
             Memories.forget_home(
               workspace.memory.ref,
               "slack:user:U123",
               "slack:T123"
             )

    assert forgotten_workspace.status == :deleted
  end

  test "wide offers cannot be confirmed after a channel becomes private or externally shared" do
    fixture = delivered_offers!("changed-channel-visibility")

    catalog = %{default_repository: "responder", repository_refs: ["responder"]}

    assert {:ok, [_private]} =
             ChannelConfigurations.reconcile_joined(
               "T123",
               [%{channel_ref: "C456", external_shared: false, private: true}],
               catalog
             )

    assert Memories.confirm(confirmation(fixture, fixture.workspace, "now-private")) ==
             {:error, :slack_channel_not_public}

    assert {:ok, [_external]} =
             ChannelConfigurations.reconcile_joined(
               "T123",
               [%{channel_ref: "C456", external_shared: true, private: false}],
               catalog
             )

    assert Behaviors.confirm(confirmation(fixture, fixture.guidance, "now-external")) ==
             {:error, :slack_channel_not_public}
  end

  test "Slack channel deletion redacts channel-scoped memory and behavior and closes reviews" do
    fixture = delivered_offers!("channel-deletion")
    assert {:ok, confirmed} = Memories.confirm(confirmation(fixture, fixture.first, "delete"))
    behavior = insert_conversation_behavior!(fixture.guidance)

    old = DateTime.add(DateTime.utc_now(), -3_600, :second)
    Repo.update_all(MemoryEntry, set: [updated_at: old])
    Repo.update_all(Behavior, set: [updated_at: old])
    assert {:ok, %{created: 2}} = Memories.refresh_reviews("slack:T123", 60)

    Repo.delete_all(
      from(membership in ChannelMembership,
        where: membership.workspace_ref == "T123" and membership.channel_ref == "C456"
      )
    )

    assert {:ok, _deleted} =
             ChannelConfigurations.observe_membership(
               %{
                 actor_ref: nil,
                 channel_ref: "C456",
                 event_ref: "event:delete-memory-state",
                 kind: :deleted,
                 occurred_at: DateTime.add(@now, 1, :second),
                 workspace_ref: "T123"
               },
               %{default_repository: "responder", repository_refs: ["responder"]}
             )

    deleted_memory = Repo.get!(MemoryEntry, confirmed.memory.id)
    assert deleted_memory.status == :deleted
    assert Map.has_key?(deleted_memory.payload, "channel_deleted_payload_sha256")

    deleted_behavior = Repo.get!(Behavior, behavior.id)
    assert deleted_behavior.status == :deleted
    assert Map.has_key?(deleted_behavior.payload, "channel_deleted_payload_sha256")

    assert Repo.aggregate(
             from(review in MemoryReviewItem, where: review.status == :pending),
             :count
           ) == 0

    assert Memories.confirm(confirmation(fixture, fixture.workspace, "after-delete")) ==
             {:error, :slack_channel_deleted}

    assert Behaviors.confirm(confirmation(fixture, fixture.guidance, "after-delete")) ==
             {:error, :slack_channel_deleted}
  end

  test "equal fact values under different subjects are not destructive duplicates" do
    fixture = delivered_offers!("distinct-facts")
    assert {:ok, _workspace} = Memories.confirm(confirmation(fixture, fixture.workspace, "one"))
    assert {:ok, _duplicate} = Memories.confirm(confirmation(fixture, fixture.duplicate, "two"))

    assert {:ok, %{created: 0}} = Memories.refresh_reviews("slack:T123", 86_400)
    assert Memories.list_reviews("slack:T123", limit: 10) == []
  end

  test "keeping duplicate guidance suppresses the unchanged group and search counts only matches" do
    fixture = delivered_offers!("guidance-keep")
    assert {:ok, first} = Behaviors.confirm(confirmation(fixture, fixture.guidance, "first"))

    assert {:ok, second} =
             Behaviors.confirm(confirmation(fixture, fixture.guidance_duplicate, "second"))

    assert {:ok, %{created: 1}} = Memories.refresh_reviews("slack:T123", 86_400)
    [review] = Memories.list_reviews("slack:T123", limit: 10)

    assert {:ok, %{status: :resolved}} =
             Memories.resolve_review(
               review["review_ref"],
               :keep,
               "slack:user:operator",
               "slack:T123"
             )

    assert {:ok, %{created: 0}} = Memories.refresh_reviews("slack:T123", 86_400)
    assert Memories.list_reviews("slack:T123", limit: 10) == []

    context = %{
      conversation_ref: "slack:T123:C456",
      operator_ref: "slack:user:operator",
      repository: nil,
      workspace_ref: "slack:T123"
    }

    assert Behaviors.search_guidance(context, "does-not-match", "workspace", 20) == []
    assert Repo.get!(Behavior, first.behavior.id).use_count == 0
    assert Repo.get!(Behavior, second.behavior.id).use_count == 0

    assert [match, _other] =
             Behaviors.search_guidance(context, "lead with the outcome", "workspace", 20)

    assert match["kind"] == "guidance"
    assert Repo.get!(Behavior, first.behavior.id).use_count == 1
    assert Repo.get!(Behavior, second.behavior.id).use_count == 1
  end

  test "fact search does not count a nonmatching candidate as recalled" do
    fixture = delivered_offers!("fact-search")
    assert {:ok, confirmed} = Memories.confirm(confirmation(fixture, fixture.first, "fact"))

    context = %{
      conversation_ref: "slack:T123:C456",
      repository: nil,
      workspace_ref: "slack:T123"
    }

    assert Memories.search(context, "missing", "current_channel", 20) == []
    assert Repo.get!(MemoryEntry, confirmed.memory.id).recall_count == 0

    assert [match] = Memories.search(context, "responder", "current_channel", 20)
    assert match["memory_ref"] == confirmed.memory.ref
    assert Repo.get!(MemoryEntry, confirmed.memory.id).recall_count == 1
  end

  defp delivered_offers!(suffix, delivery_thread_ref \\ "1787832000.000100") do
    Repo.insert!(%ChannelMembership{
      channel_ref: "C456",
      external_shared: false,
      generation: 1,
      id: Ecto.UUID.generate(),
      joined_at: @now,
      private: false,
      status: :joined,
      workspace_ref: "T123"
    })

    episode_id = Ecto.UUID.generate()

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: %{
                   conversation_ref: "slack:T123:C456",
                   thread_ref: "1787832000.000100",
                   transport: "slack"
                 },
                 episode_id: episode_id,
                 episode_key: "memory-offer:#{suffix}:#{episode_id}",
                 native_input_id: "slack-message:memory:#{suffix}:#{episode_id}",
                 occurred_at: @now,
                 turn_ref: "turn:memory:#{suffix}:#{episode_id}"
               })
             )

    assert {:ok, _session} =
             Custody.pin_episode(episode_id, "responder-read", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("worker:memory:#{suffix}", 60, :work)

    assert {:ok, first} =
             Records.create(Records.token(claim.turn), "first", "memory_offer", %{
               "expires_in" => "90d",
               "kind" => "repository_binding",
               "repository" => nil,
               "scope" => "conversation",
               "subject" => "primary_repository",
               "value" => "responder",
               "visibility" => "conversation"
             })

    assert {:ok, replacement} =
             Records.create(Records.token(claim.turn), "replacement", "memory_offer", %{
               "expires_in" => "90d",
               "kind" => "repository_binding",
               "repository" => nil,
               "scope" => "conversation",
               "subject" => "primary_repository",
               "value" => "responder-next",
               "visibility" => "conversation"
             })

    assert {:ok, workspace} =
             Records.create(Records.token(claim.turn), "workspace", "memory_offer", %{
               "expires_in" => "30d",
               "kind" => "entity_relationship",
               "repository" => nil,
               "scope" => "workspace",
               "subject" => "checkout_service",
               "value" => "The checkout API is owned by Payments.",
               "visibility" => "workspace"
             })

    assert {:ok, duplicate} =
             Records.create(Records.token(claim.turn), "duplicate", "memory_offer", %{
               "expires_in" => "30d",
               "kind" => "entity_relationship",
               "repository" => nil,
               "scope" => "workspace",
               "subject" => "payments_checkout_owner",
               "value" => "The checkout API is owned by Payments.",
               "visibility" => "workspace"
             })

    assert {:ok, guidance} =
             Records.create(Records.token(claim.turn), "guidance", "guidance_offer", %{
               "expires_in" => "30d",
               "repository" => nil,
               "scope" => "workspace",
               "subject" => "outcome_first",
               "summary" => "Lead with the outcome",
               "text" => "Always lead with the outcome.",
               "visibility" => "workspace"
             })

    assert {:ok, guidance_duplicate} =
             Records.create(
               Records.token(claim.turn),
               "guidance-duplicate",
               "guidance_offer",
               %{
                 "expires_in" => "30d",
                 "repository" => nil,
                 "scope" => "workspace",
                 "subject" => "answer_order",
                 "summary" => "Lead with the outcome",
                 "text" => "Always lead with the outcome.",
                 "visibility" => "workspace"
               }
             )

    bind_and_deliver!(
      claim,
      transition.episode,
      suffix,
      [
        first,
        replacement,
        workspace,
        duplicate,
        guidance,
        guidance_duplicate
      ],
      delivery_thread_ref
    )
    |> Map.merge(%{
      duplicate: duplicate,
      first: first,
      guidance: guidance,
      guidance_duplicate: guidance_duplicate,
      replacement: replacement,
      workspace: workspace
    })
  end

  defp insert_conversation_behavior!(offer) do
    id = Ecto.UUID.generate()

    %{
      confirmation_ref: "confirmation:channel-deletion",
      confirmed_at: @now,
      confirmed_by_actor_ref: "slack:user:U123",
      expires_at: DateTime.add(DateTime.utc_now(), 86_400, :second),
      id: id,
      identity_key: "channel-deletion-guidance",
      kind: :guidance,
      offer_record_id: offer.id,
      payload: %{
        "expires_in" => "30d",
        "repository" => nil,
        "scope" => "conversation",
        "subject" => "channel-deletion-guidance",
        "summary" => "Delete this channel guidance",
        "text" => "Delete this channel guidance",
        "visibility" => "conversation"
      },
      ref: "behavior:#{id}",
      revision: 1,
      scope_kind: :conversation,
      scope_ref: "slack:T123:C456",
      source_conversation_ref: "slack:T123:C456",
      source_message_ref: "1787832001.000200",
      source_thread_ref: "1787832000.000100",
      source_transport: "slack",
      status: :active,
      workspace_ref: "slack:T123"
    }
    |> BehaviorChangeset.insert()
    |> Repo.insert!()
  end

  defp bind_and_deliver!(claim, episode, suffix, records, delivery_thread_ref) do
    assert {:ok, submission} =
             Submission.new(
               %{"episode_id" => episode.id},
               "Offer the exact memory mappings for confirmation.",
               %{"type" => "object"},
               "work-final-v1"
             )

    assert {:ok, _turn} =
             Custody.freeze_submission(
               episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    assert {:ok, session} =
             Custody.bind_session(
               episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:memory:#{suffix}"
             )

    assert {:ok, turn} =
             Custody.bind_turn(
               episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:memory:#{suffix}"
             )

    candidate =
      ~s({"delivery":"reply","message":"I can remember those mappings after confirmation."})

    sha256 = digest(candidate)

    assert {:ok, _turn} =
             Custody.stage_candidate(
               episode.id,
               turn.turn_ref,
               claim.lease_ref,
               nil,
               nil,
               candidate,
               sha256,
               1
             )

    assert {:ok, result} =
             Result.new(:reply, %{
               "decision_reason" => nil,
               "delivery" => "reply",
               "message" => "I can remember those mappings after confirmation.",
               "outcome" => %{
                 "artifact_refs" => [],
                 "record_refs" => Enum.map(records, & &1.ref),
                 "state" => "complete"
               }
             })

    assert {:ok, _turn} =
             Custody.prepare_validation(
               episode.id,
               turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               :accept,
               result
             )

    assert {:ok, accepted} =
             Custody.accept_result(
               episode.id,
               episode.key,
               turn.turn_ref,
               claim.lease_ref,
               sha256,
               1,
               "validation-receipt:memory:#{suffix}"
             )

    assert {:ok, delivery_claim} =
             Custody.claim_next("delivery:memory:#{suffix}", 60, :delivery)

    # Where this turn's reply goes, exactly as `Custody.reply_target/2` freezes
    # it at acceptance: the answering input's own origin, which routing can join
    # into this episode from a thread other than its bound home.
    Repo.get_by!(Turn, episode_id: episode.id, turn_ref: turn.turn_ref)
    |> Ecto.Changeset.change(
      delivery_target: %{
        "conversation_ref" => "slack:T123:C456",
        "thread_ref" => delivery_thread_ref,
        "transport" => "slack"
      }
    )
    |> Repo.update!()

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               accepted.turn.delivery_ref,
               "slack",
               "slack:T123:C456",
               delivery_thread_ref,
               "1787832001.000200"
             )

    assert {:ok, settled} =
             Custody.confirm_delivery(
               episode.id,
               episode.key,
               turn.turn_ref,
               delivery_claim.lease_ref,
               receipt
             )

    %{episode: settled.episode, receipt: receipt}
  end

  defp confirmation(fixture, record, suffix) do
    %{
      actor_ref: "slack:user:U123",
      confirmation_ref: "interaction:#{suffix}",
      occurred_at: @now,
      record_ref: record.ref,
      target: %{
        conversation_ref: fixture.receipt["conversation_ref"],
        message_ref: fixture.receipt["message_ref"],
        thread_ref: fixture.receipt["thread_ref"],
        transport: fixture.receipt["transport"]
      }
    }
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
