defmodule Ryker.Slack.CollectionsTest do
  use Ryker.DataCase, async: true

  alias Ryker.Fixtures.SavedEntities, as: Fixtures
  alias Ryker.Repo
  alias Ryker.Slack.Collections

  @workspace "T123"
  @channel "C456"
  @conversation "slack:T123:C456"

  defmodule API do
    def find_message(agent, channel, thread, delivery_ref) do
      Agent.get(agent, fn state ->
        case Map.get(state.deliveries, {channel, thread, delivery_ref}) do
          nil -> :not_found
          message_ref -> {:ok, message_ref}
        end
      end)
    end

    def post_message(agent, channel, thread, document, delivery_ref) do
      Agent.get_and_update(agent, fn state ->
        if MapSet.member?(state.failing, delivery_ref) do
          {{:error, :slack_down}, state}
        else
          message_ref = "#{map_size(state.deliveries) + 1}.000001"

          {{:ok, message_ref},
           %{
             state
             | deliveries:
                 Map.put(state.deliveries, {channel, thread, delivery_ref}, message_ref),
               posts:
                 state.posts ++
                   [%{delivery_ref: delivery_ref, document: document, thread: thread}]
           }}
        end
      end)
    end
  end

  setup do
    agent =
      start_supervised!({Agent, fn -> %{deliveries: %{}, failing: MapSet.new(), posts: []} end})

    %{options: %{api: API, client: agent}}
  end

  # "What schedules are active?" used to be answered from a prose summary or a
  # single text blob with every delete control in one message. Each item is its
  # own card with its own delivery identity; a page is five; empty is not failure.
  test "a requested collection is one bounded page of separate item cards with exact counts",
       %{options: options} do
    source = source!()
    schedules = for index <- 1..7, do: schedule!(source, "Check #{index}", index)

    assert {:ok, %{outcome: :delivered, shown: 5, total: 7}} =
             Collections.deliver(:schedules, request("event:list-1"), options)

    posts = posts(options)
    assert length(posts) == 6
    assert Enum.all?(posts, &(&1.thread == "77.000001"))

    cards = Enum.take(posts, 5)

    assert Enum.map(cards, &get_in(&1.document, ["saved_entity", "ref"])) ==
             schedules |> Enum.take(5) |> Enum.map(& &1.ref)

    assert Enum.map(cards, &get_in(&1.document, ["saved_entity", "title"])) ==
             Enum.map(1..5, &"Check #{&1}")

    assert Enum.all?(cards, &(get_in(&1.document, ["saved_entity", "removable"]) == true))

    assert Enum.all?(
             cards,
             &(get_in(&1.document, ["saved_entity", "notice"]) == "Schedule active")
           )

    more = List.last(posts)

    assert more.document == %{
             "message" =>
               "Showing 5 of 7 schedules in this channel. Operators can open my App Home for the complete list."
           }

    assert more.delivery_ref == "slack-collection:event:list-1:more"

    # A retry of the same request finds every item and posts nothing again.
    assert {:ok, %{outcome: :delivered, shown: 5, total: 7}} =
             Collections.deliver(:schedules, request("event:list-1"), options)

    assert length(posts(options)) == 6
  end

  test "a failed item retries without duplicating the items delivered before it", %{
    options: options
  } do
    source = source!()
    [first, second, third] = for index <- 1..3, do: schedule!(source, "Retry #{index}", index)
    request = request("event:retry")

    Agent.update(options.client, fn state ->
      %{state | failing: MapSet.new(["slack-collection:event:retry:#{second.ref}"])}
    end)

    assert Collections.deliver(:schedules, request, options) == {:error, :slack_down}
    assert Enum.map(posts(options), &get_in(&1.document, ["saved_entity", "ref"])) == [first.ref]

    Agent.update(options.client, &%{&1 | failing: MapSet.new()})

    assert {:ok, %{outcome: :delivered, shown: 3, total: 3}} =
             Collections.deliver(:schedules, request, options)

    assert Enum.map(posts(options), &get_in(&1.document, ["saved_entity", "ref"])) ==
             [first.ref, second.ref, third.ref]
  end

  test "empty, unavailable and another channel's items are three different answers", %{
    options: options
  } do
    assert {:ok, %{outcome: :empty, shown: 0, total: 0}} =
             Collections.deliver(:standing_rules, request("event:empty"), options)

    assert [%{document: %{"message" => "No standing rules are set up in this channel."}}] =
             posts(options)

    source = source!()
    _elsewhere = schedule!(source, "Other channel", 1, destination: "slack:T123:C999")
    _paused = schedule!(source, "Paused here", 2, status: :paused)
    _deleted = schedule!(source, "Deleted here", 3, status: :deleted)

    assert {:ok, %{outcome: :delivered, shown: 1, total: 1}} =
             Collections.deliver(:schedules, request("event:scoped"), options)

    [_empty, only] = posts(options)
    assert get_in(only.document, ["saved_entity", "title"]) == "Paused here"
    assert get_in(only.document, ["saved_entity", "notice"]) == "Schedule paused"
    refute inspect(posts(options)) =~ "Other channel"
    refute inspect(posts(options)) =~ "Deleted here"

    assert Collections.deliver(:everything, request("event:kind"), options) ==
             {:error, :invalid_collection}
  end

  # A rescue nobody exercised: the failed query used to be indistinguishable
  # from an empty channel for anyone reading the thread, so an operator went
  # looking for the schedule they still had. Only a query that ran may say
  # "none"; a query that did not run says it could not load.
  test "a collection whose query never ran says so instead of reporting an empty channel", %{
    options: options
  } do
    source = source!()
    _still_here = schedule!(source, "Still here", 1)

    # The collection's own query fails for real: with this connection's schema
    # search path emptied, the `Repo.all` inside the collection raises
    # Postgrex.Error the way an unreachable table does mid-request.
    Repo.query!("SET LOCAL search_path TO pg_temp")

    assert {:ok, %{outcome: :unavailable, shown: 0, total: 0}} =
             Collections.deliver(:schedules, request("event:down"), options)

    assert [%{delivery_ref: "slack-collection:event:down:unavailable", document: document}] =
             posts(options)

    assert document == %{
             "message" =>
               "I couldn't load this channel's schedules right now. Try again in a moment."
           }

    refute inspect(document) =~ "No active schedules"
  end

  # "Open my App Home to see the complete list" was a promise no surface kept:
  # every list stopped at five. The complete list is read one bounded page at a
  # time from the same scoped query the first page was cut from.
  test "every authorized item past the first page is reachable one bounded page at a time" do
    source = source!()
    here = for index <- 1..7, do: schedule!(source, "Check #{index}", index)
    _elsewhere = schedule!(source, "Other channel", 8, destination: "slack:T123:C999")
    scope = %{channel_refs: [@channel], workspace_ref: @workspace}

    assert {:ok, %{entries: first, offset: 0, total: 7}} =
             Collections.page(:schedules, scope, 0, 5)

    assert {:ok, %{entries: second, offset: 5, total: 7}} =
             Collections.page(:schedules, scope, 5, 5)

    assert length(first) == 5
    assert length(second) == 2
    assert Enum.map(first ++ second, & &1.ref) == Enum.map(here, & &1.ref)
    refute inspect(second) =~ "Other channel"

    # A page named by a button that was rendered before items were removed
    # shows the last page that exists, never a blank one.
    assert {:ok, %{entries: clamped, offset: 5, total: 7}} =
             Collections.page(:schedules, scope, 40, 5)

    assert Enum.map(clamped, & &1.ref) == Enum.map(second, & &1.ref)

    assert {:ok, %{entries: [], offset: 0, total: 0}} =
             Collections.page(:standing_rules, scope, 15, 5)

    assert Collections.page(:everything, scope, 0, 5) == {:error, :invalid_collection}
    assert Collections.page(:schedules, scope, -1, 5) == {:error, :invalid_collection}
    assert Collections.page(:schedules, scope, 0, 0) == {:error, :invalid_collection}
  end

  # Every channel the reader shares with Ryker is one scoped query, so the
  # complete list an operator opens is the same rows the thread page came from.
  test "a multi-channel scope lists each channel's items and no one else's" do
    source = source!()
    mine = schedule!(source, "Mine", 1)
    shared = schedule!(source, "Also mine", 2, destination: "slack:T123:C999")
    _private = schedule!(source, "Not mine", 3, destination: "slack:T123:CPRIVATE")

    assert {:ok, %{entries: entries, total: 2}} =
             Collections.page(
               :schedules,
               %{channel_refs: [@channel, "C999"], workspace_ref: @workspace},
               0,
               20
             )

    assert Enum.map(entries, & &1.ref) == [mine.ref, shared.ref]
    refute inspect(entries) =~ "Not mine"
  end

  test "a paused standing rule is counted as paused and can be resumed from the channel", %{
    options: options
  } do
    # The 2026-09-12 coverage measurement: paused rules were listed, but the
    # count line called them all standing rules and the only way to restart one
    # was App Home, which most readers of this list cannot act in.
    source = source!()

    for index <- 1..2 do
      behavior!(
        source,
        :standing_assignment,
        %{
          "action" => "triage_alert",
          "expires_in" => "30d",
          "repository" => nil,
          "source_filter" => "human",
          "task" => "Summarise the alert for rule #{index}.",
          "trigger" => "operational_alert"
        },
        scope_ref: @conversation
      )
    end

    behavior!(
      source,
      :standing_assignment,
      %{
        "action" => "triage_alert",
        "expires_in" => "30d",
        "repository" => nil,
        "source_filter" => "human",
        "task" => "Summarise the alert for the paused rule.",
        "trigger" => "operational_alert"
      },
      scope_ref: @conversation,
      status: :disabled
    )

    assert {:ok, %{outcome: :delivered, shown: 3, total: 3}} =
             Collections.deliver(:standing_rules, request("event:paused"), options)

    cards = posts(options)

    resumable =
      Enum.map(cards, &get_in(&1.document, ["saved_entity", "resumable"])) |> Enum.sort()

    assert resumable == [false, false, true]
  end

  test "saved knowledge lists preferences, guidance and memories visible in this channel", %{
    options: options
  } do
    source = source!()

    guidance =
      behavior!(
        source,
        :guidance,
        %{
          "subject" => "Deploy reviews",
          "summary" => "Read the release notes before reviewing.",
          "text" => "Check the release notes first.",
          "scope" => "conversation",
          "visibility" => "conversation",
          "expires_in" => "30d",
          "repository" => nil
        },
        scope_ref: @conversation
      )

    preference =
      behavior!(
        source,
        :preference,
        %{
          "key" => "response_detail",
          "value" => "concise",
          "scope" => "workspace",
          "expires_in" => "30d",
          "repository" => nil
        },
        scope_kind: :workspace,
        scope_ref: "slack:T123"
      )

    memory = memory!(source, "GCP project", "portal-prod")

    _private =
      behavior!(
        source,
        :guidance,
        %{
          "subject" => "Only mine",
          "summary" => "Private guidance.",
          "text" => "Private.",
          "scope" => "operator",
          "visibility" => "private",
          "expires_in" => "30d",
          "repository" => nil
        },
        scope_kind: :operator,
        scope_ref: "slack:user:U123"
      )

    assert {:ok, %{outcome: :delivered, shown: 3, total: 3}} =
             Collections.deliver(:knowledge, request("event:knowledge"), options)

    refs = Enum.map(posts(options), &get_in(&1.document, ["saved_entity", "ref"]))
    assert Enum.sort(refs) == Enum.sort([guidance.ref, preference.ref, memory.ref])
    refute inspect(posts(options)) =~ "Only mine"

    kinds = Enum.map(posts(options), &get_in(&1.document, ["saved_entity", "kind"]))
    assert Enum.sort(kinds) == ["guidance", "memory", "preference"]
  end

  defp request(request_ref) do
    %{
      channel_ref: @channel,
      request_ref: request_ref,
      thread_ref: "77.000001",
      workspace_ref: @workspace
    }
  end

  defp posts(options), do: Agent.get(options.client, & &1.posts)

  defp source!, do: Fixtures.source!(@conversation)

  defp schedule!(source, title, index, overrides \\ []),
    do: Fixtures.schedule!(source, title, index, overrides)

  defp behavior!(source, kind, payload, overrides),
    do: Fixtures.behavior!(source, kind, payload, overrides)

  defp memory!(source, subject, value), do: Fixtures.memory!(source, subject, value)
end
