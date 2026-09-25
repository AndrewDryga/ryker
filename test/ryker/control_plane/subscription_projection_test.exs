defmodule Ryker.ControlPlane.SubscriptionProjectionTest do
  use Ryker.DataCase, async: false

  import Ecto.Query
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.{Endpoint, Projection, SubscriptionProjection}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Slack.Input
  alias Ryker.State.{EventSubscription, EventSubscriptionChangeset, Records}
  alias Ryker.Work.Custody

  @endpoint Endpoint

  setup do
    message = "testdata/slack/hcp-terraform-planning.json" |> File.read!() |> Jason.decode!()
    id = Ecto.UUID.generate()

    {:ok, source} =
      Input.new(%{
        actor: %{kind: :bot, ref: message["bot_id"]},
        channel_ref: message["channel"],
        content: message,
        event_kind: :message,
        event_ref: "subscription-projection:#{id}",
        message_ref: message["ts"],
        occurred_at: DateTime.utc_now(),
        revision: 1,
        thread_ref: message["ts"],
        workspace_ref: "TSUBSCRIPTIONS"
      })

    {:ok, %{entry: entry}} = Inbox.record(source)

    {:ok, transition} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: id,
          episode_key: id,
          native_input_id: source.native_input_id,
          destination: source.destination,
          turn_ref: id
        })
      )

    decision = %{
      "action" => "start_episode",
      "episode_ref" => nil,
      "reaction" => nil,
      "relation" => "unrelated",
      "repository_source" => nil,
      "reason" => "Monitor the recorded run.",
      "work_class" => "standard"
    }

    Repo.update_all(from(e in Entry, where: e.id == ^entry.id),
      set: [
        episode_id: id,
        status: :decided,
        decision_action: :start_episode,
        decision_document: decision,
        decision_fingerprint: CanonicalJSON.digest(decision),
        decision_ref: "subscription-decision:#{id}"
      ]
    )

    {:ok, _} = Custody.pin_episode(id, "read-only", String.duplicate("a", 64))
    {:ok, claim} = Custody.claim_next("subscription-projection", 60, :work)
    matcher = %{"attachments" => [Map.take(hd(message["attachments"]), ~w(title title_link))]}

    {:ok, record} =
      Records.create(Records.token(claim.turn), "wait", "event_wait", %{
        "deadline_at" => nil,
        "event_matcher" => %{
          "type" => "source_event",
          "source_kind" => "slack",
          "match" => matcher,
          "on_timeout" => nil,
          "poll_after" => nil
        },
        "kind" => "source_event",
        "verification" => "Read the exact Terraform run on its next update."
      })

    subscription =
      %{
        id: Ecto.UUID.generate(),
        episode_id: id,
        record_id: record.id,
        ref: "event-subscription:#{id}",
        revision: 1,
        source_kind: "slack",
        status: :active,
        matcher: Map.put(matcher, "private_body", "never-display-this-body")
      }
      |> EventSubscriptionChangeset.insert()
      |> Repo.insert!()

    %{subscription: subscription, entry: entry, record: record, episode: transition.episode}
  end

  test "the bounded projection searches the words the page shows without exposing raw matchers",
       context do
    for query <- [
          "run-k9CpPp3nWjQrkCMG",
          "Slack channel",
          "update on run",
          context.subscription.ref,
          context.episode.key
        ] do
      assert [item] = SubscriptionProjection.list(%{"q" => query, "view" => "current"})
      assert item.title == "An update on Run run-k9CpPp3nWjQrkCMG"
      assert item.episode_title == "Run run-k9CpPp3nWjQrkCMG"
      assert item.condition == nil
      assert item.target_url =~ "https://app.terraform.io/"
      assert item.episode_href == "/timeline/#{context.episode.key}"
      assert item.place =~ "Slack channel"
      refute Map.has_key?(item, :matcher)
      refute inspect(item) =~ "never-display-this-body"
    end

    assert SubscriptionProjection.list(%{"q" => "never-display-this-body"}) == []
    assert SubscriptionProjection.list(%{"view" => "past"}) == []
    assert Repo.get!(EventSubscription, context.subscription.id) == context.subscription
  end

  test "retention and deletion remove stale source titles and matcher targets from search",
       context do
    for changes <- [
          [operational_pruned_at: DateTime.utc_now(), content: %{}],
          [operational_pruned_at: nil, event_kind: :delete, content: %{}]
        ] do
      Repo.update_all(from(e in Entry, where: e.id == ^context.entry.id), set: changes)
      assert [item] = SubscriptionProjection.list(%{})
      assert item.title == "A matching Slack update"
      assert item.target_url == nil
      assert item.place == nil
      assert item.repository == nil
      assert SubscriptionProjection.list(%{"q" => "run-k9CpPp3nWjQrkCMG"}) == []
      assert item.ref == context.subscription.ref
    end
  end

  test "a follow-up still waiting is never hidden behind newer history",
       context do
    # A busy channel can resolve 100 follow-ups while one older deployment
    # still waits. Current holds only what still waits, and the unfiltered
    # list puts it first.
    insert_resolved_history!(context)

    assert [current] = SubscriptionProjection.list(%{"view" => "current"})
    assert current.ref == context.subscription.ref

    items = SubscriptionProjection.list(%{})
    assert length(items) == 100
    assert hd(items).ref == context.subscription.ref
    assert hd(items).status == :active

    past = SubscriptionProjection.list(%{"view" => "past"})
    assert length(past) == 100
    assert Enum.all?(past, &(&1.status == :resolved))
  end

  test "exact follow-up references remain findable outside the bounded recent search window",
       context do
    Repo.update_all(from(s in EventSubscription, where: s.id == ^context.subscription.id),
      set: [
        status: :resolved,
        resolution_kind: :input,
        last_observed_at: DateTime.utc_now(),
        updated_at: DateTime.add(DateTime.utc_now(), -86_400)
      ]
    )

    insert_resolved_history!(context)
    items = SubscriptionProjection.list(%{"view" => "past"})
    assert length(items) == 100
    refute Enum.any?(items, &(&1.ref == context.subscription.ref))

    assert [exact] =
             SubscriptionProjection.list(%{"q" => context.subscription.ref, "view" => "past"})

    assert exact.ref == context.subscription.ref

    assert SubscriptionProjection.list(%{
             "q" => context.subscription.ref,
             "view" => "current"
           }) == []
  end

  defp insert_resolved_history!(context) do
    now = DateTime.utc_now()

    for index <- 1..100 do
      record = %{
        context.record
        | id: Ecto.UUID.generate(),
          ref: "record:history:#{index}",
          operation_id: "history:#{index}",
          sequence: nil
      }

      Repo.insert!(record)

      Repo.insert!(%EventSubscription{
        id: Ecto.UUID.generate(),
        episode_id: context.episode.id,
        record_id: record.id,
        ref: "event-subscription:history:#{index}",
        status: :resolved,
        revision: 1,
        source_kind: "slack",
        matcher: context.subscription.matcher,
        resolution_kind: :input,
        last_observed_at: now,
        inserted_at: now,
        updated_at: now
      })
    end
  end

  test "a live refresh keeps the search, the view and an open Details disclosure without executing work",
       context do
    observer = self()

    options = %{
      actions: %{},
      csrf_secret: String.duplicate("s", 32),
      observability: %{},
      projection:
        Map.put(Projection.callbacks(), :subscriptions, fn params ->
          result = SubscriptionProjection.list(params)
          send(observer, {:subscriptions_projected, result})
          result
        end)
    }

    start_supervised!(
      {Endpoint,
       [
         server: false,
         secret_key_base: String.duplicate("s", 64),
         pubsub_server: Ryker.ControlPlane.PubSub,
         live_view: [signing_salt: "control-plane-test"],
         check_origin: ["//localhost:4321"],
         url: [host: "localhost", port: 4321],
         control_plane: options
       ]}
    )

    {:ok, view, _} =
      live(build_conn() |> Map.put(:host, "localhost"), "/follow-ups?q=run-k9&view=current")

    assert has_element?(view, ".entity-name", "An update on Run run-k9CpPp3nWjQrkCMG")

    assert has_element?(
             view,
             "details[id='follow-up-details-#{context.subscription.ref}']:not([open])"
           )

    assert has_element?(view, "input[name=q][value=run-k9]")
    assert has_element?(view, "nav.segmented a[aria-current=page]", "Current")
    # Drain initial static and connected projection notifications before refresh.
    assert_receive {:subscriptions_projected, [_]}
    assert_receive {:subscriptions_projected, [_]}
    send(view.pid, :reconcile)
    assert_receive {:subscriptions_projected, [_]}
    assert has_element?(view, "details[id='follow-up-details-#{context.subscription.ref}']")
    assert has_element?(view, "input[name=q][value=run-k9]")
    assert Repo.get!(EventSubscription, context.subscription.id) == context.subscription

    Repo.update_all(from(s in EventSubscription, where: s.id == ^context.subscription.id),
      set: [
        poll_after: DateTime.add(DateTime.utc_now(), -180),
        deadline_at: DateTime.add(DateTime.utc_now(), 600)
      ]
    )

    send(view.pid, :control_plane_changed)
    assert_receive {:subscriptions_projected, [_]}
    assert has_element?(view, ".entity-meta", "next check overdue by 3 minutes")
    assert has_element?(view, ".entity-side .state-word", "Waiting")
  end
end
