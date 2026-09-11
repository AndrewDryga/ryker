defmodule Responder.Slack.CollectionsTest do
  use Responder.DataCase, async: true

  alias Responder.{Episodes, Repo}
  alias Responder.Fixtures.Episodes, as: Fixtures
  alias Responder.Slack.Collections
  alias Responder.State.{Behavior, MemoryEntry, Records, Schedule}
  alias Responder.Work.Custody

  @now ~U[2026-08-28 12:00:00.000000Z]
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
               "Showing 5 of 7 schedules in this channel. Open my App Home to see the complete list."
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

  defp source! do
    id = Ecto.UUID.generate()

    {:ok, started} =
      Episodes.apply(
        Fixtures.admit_input(%{
          destination: %{
            conversation_ref: @conversation,
            thread_ref: "1.000001",
            transport: "slack"
          },
          episode_id: id,
          episode_key: "collections:#{id}",
          native_input_id: "collections:#{id}",
          turn_ref: "turn:#{id}"
        })
      )

    {:ok, _session} = Custody.pin_episode(id, "policy:collections", String.duplicate("a", 64))
    {:ok, claim} = Custody.claim_next("collections:#{id}", 60, :work)
    %{episode: started.episode, turn: claim.turn}
  end

  defp offer!(source, kind, payload) do
    {:ok, record} =
      Records.create(Records.token(source.turn), "offer:#{Ecto.UUID.generate()}", kind, payload)

    record
  end

  defp schedule!(source, title, index, overrides \\ []) do
    payload = %{
      "authority" => "read_only",
      "catch_up" => "latest",
      "expires_at" => nil,
      "recurrence" => %{"kind" => "daily", "time" => "13:00:00"},
      "repository" => nil,
      "task" => "Inspect #{title}.",
      "timezone" => "Etc/UTC",
      "title" => title
    }

    record = offer!(source, "schedule_offer", payload)
    id = Ecto.UUID.generate()
    at = DateTime.add(@now, index, :hour)

    Repo.insert!(%Schedule{
      id: id,
      ref: "schedule:#{id}",
      offer_record_id: record.id,
      source_episode_id: source.episode.id,
      status: Keyword.get(overrides, :status, :active),
      title: title,
      task: payload["task"],
      recurrence: payload["recurrence"],
      timezone: "Etc/UTC",
      catch_up: :latest,
      authority: :read_only,
      repository: nil,
      destination_transport: "slack",
      destination_conversation_ref: Keyword.get(overrides, :destination, @conversation),
      destination_thread_ref: "1.000001",
      confirmed_by_actor_ref: "slack:user:U123",
      confirmation_ref: "interaction:#{id}",
      confirmed_at: @now,
      next_occurrence_at: at,
      inserted_at: at,
      updated_at: at
    })
  end

  defp behavior!(source, kind, payload, overrides) do
    record = offer!(source, "#{kind}_offer", payload)
    id = Ecto.UUID.generate()

    Repo.insert!(%Behavior{
      id: id,
      ref: "behavior:#{id}",
      offer_record_id: record.id,
      kind: kind,
      status: :active,
      workspace_ref: "slack:#{@workspace}",
      scope_kind: Keyword.get(overrides, :scope_kind, :conversation),
      scope_ref: Keyword.fetch!(overrides, :scope_ref),
      identity_key: payload["subject"] || payload["key"],
      payload: payload,
      confirmed_by_actor_ref: "slack:user:U123",
      confirmation_ref: "interaction:#{id}",
      confirmed_at: @now,
      source_transport: "slack",
      source_conversation_ref: @conversation,
      source_thread_ref: "1.000001",
      source_message_ref: "1.000002",
      expires_at: DateTime.add(@now, 30, :day),
      inserted_at: @now,
      updated_at: @now
    })
  end

  defp memory!(source, subject, value) do
    payload = %{
      "expires_in" => "30d",
      "kind" => "entity_relationship",
      "repository" => nil,
      "scope" => "workspace",
      "subject" => subject,
      "value" => value,
      "visibility" => "workspace"
    }

    record = offer!(source, "memory_offer", payload)
    id = Ecto.UUID.generate()

    Repo.insert!(%MemoryEntry{
      id: id,
      ref: "memory:#{id}",
      offer_record_id: record.id,
      kind: :entity_relationship,
      status: :active,
      workspace_ref: "slack:#{@workspace}",
      scope_kind: :workspace,
      scope_ref: "slack:#{@workspace}",
      visibility: :workspace,
      subject: subject,
      payload: payload,
      payload_fingerprint: Responder.CanonicalJSON.digest(payload),
      confirmed_by_actor_ref: "slack:user:U123",
      confirmation_ref: "interaction:#{id}",
      confirmed_at: @now,
      source_transport: "slack",
      source_conversation_ref: @conversation,
      source_thread_ref: "1.000001",
      source_message_ref: "1.000002",
      expires_at: DateTime.add(@now, 30, :day),
      inserted_at: @now,
      updated_at: @now
    })
  end
end
