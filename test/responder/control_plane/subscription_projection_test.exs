defmodule Responder.ControlPlane.SubscriptionProjectionTest do
  use Responder.DataCase, async: false

  import Ecto.Query
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Responder.CanonicalJSON
  alias Responder.ControlPlane.{Endpoint, OperatorProjection, Projection}
  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Ingress.Inbox
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Slack.Input
  alias Responder.State.{EventSubscription, EventSubscriptionChangeset, Records}
  alias Responder.Work.Custody

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

  test "the bounded projection searches readable source and target labels without exposing raw matchers",
       context do
    for query <- [
          "run-k9CpPp3nWjQrkCMG",
          "Slack channel",
          "matching Slack",
          context.subscription.ref,
          context.episode.key
        ] do
      assert [item] = OperatorProjection.subscriptions(%{"q" => query, "status" => "active"})
      assert item.title == "Run run-k9CpPp3nWjQrkCMG"
      assert item.episode_title == item.title
      assert item.condition == "Next matching Slack update"
      assert item.target_url =~ "https://app.terraform.io/"
      assert item.episode_href == "/timeline/#{context.episode.key}"
      refute Map.has_key?(item, :matcher)
      refute inspect(item) =~ "never-display-this-body"
    end

    assert OperatorProjection.subscriptions(%{"q" => "never-display-this-body"}) == []
    assert OperatorProjection.subscriptions(%{"status" => "resolved"}) == []
    assert Repo.get!(EventSubscription, context.subscription.id) == context.subscription
  end

  test "retention and deletion remove stale source titles and matcher targets from search",
       context do
    for changes <- [
          [operational_pruned_at: DateTime.utc_now(), content: %{}],
          [operational_pruned_at: nil, event_kind: :delete, content: %{}]
        ] do
      Repo.update_all(from(e in Entry, where: e.id == ^context.entry.id), set: changes)
      assert [item] = OperatorProjection.subscriptions(%{})
      assert item.title == "Matching Slack update"
      assert item.target_url == nil
      assert item.context_label == "Source context unavailable"
      assert OperatorProjection.subscriptions(%{"q" => "run-k9CpPp3nWjQrkCMG"}) == []
      assert item.ref == context.subscription.ref
    end
  end

  test "active waits remain visible ahead of more recent resolved history",
       context do
    # A busy channel can resolve 100 waits while one older deployment still needs
    # attention. The default list must not hide that live wait behind history.
    insert_resolved_history!(context)
    items = OperatorProjection.subscriptions(%{})
    assert length(items) == 100
    assert hd(items).ref == context.subscription.ref
    assert hd(items).status == :active
  end

  test "exact subscription references remain findable outside the bounded recent search window",
       context do
    Repo.update_all(from(s in EventSubscription, where: s.id == ^context.subscription.id),
      set: [status: :resolved, resolution_kind: :input, last_observed_at: DateTime.utc_now()]
    )

    insert_resolved_history!(context)
    items = OperatorProjection.subscriptions(%{})
    assert length(items) == 100
    refute Enum.any?(items, &(&1.ref == context.subscription.ref))
    assert [exact] = OperatorProjection.subscriptions(%{"q" => context.subscription.ref})
    assert exact.ref == context.subscription.ref

    assert OperatorProjection.subscriptions(%{
             "q" => context.subscription.ref,
             "status" => "active"
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

  test "live wait updates retain filters and stable disclosure identities without executing work",
       context do
    observer = self()

    options = %{
      actions: %{},
      csrf_secret: String.duplicate("s", 32),
      observability: %{},
      projection:
        Map.put(Projection.callbacks(), :subscriptions, fn params ->
          result = OperatorProjection.subscriptions(params)
          send(observer, {:subscriptions_projected, result})
          result
        end)
    }

    start_supervised!(
      {Endpoint,
       [
         server: false,
         secret_key_base: String.duplicate("s", 64),
         pubsub_server: Responder.ControlPlane.PubSub,
         live_view: [signing_salt: "control-plane-test"],
         check_origin: ["//localhost:4321"],
         url: [host: "localhost", port: 4321],
         control_plane: options
       ]}
    )

    {:ok, view, _} =
      live(build_conn() |> Map.put(:host, "localhost"), "/subscriptions?q=run-k9&status=active")

    assert has_element?(view, ".subscription-title", "Run run-k9CpPp3nWjQrkCMG")

    assert has_element?(
             view,
             "details[id='wait-details-#{context.subscription.ref}']:not([open])"
           )

    assert has_element?(view, "input[name=q][value=run-k9]")
    assert has_element?(view, "select[name=status] option[value=active][selected]")
    # Drain initial static and connected projection notifications before refresh.
    assert_receive {:subscriptions_projected, [_]}
    assert_receive {:subscriptions_projected, [_]}
    send(view.pid, :reconcile)
    assert_receive {:subscriptions_projected, [_]}
    assert has_element?(view, "details[id='wait-details-#{context.subscription.ref}']")
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
    assert has_element?(view, ".subscription-timing", "overdue by 3 minutes")
    assert has_element?(view, ".subscription-timing", "Waiting")
  end
end
