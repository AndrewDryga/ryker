defmodule Ryker.Admission.HistoryAuthorizationTest do
  use Ryker.DataCase, async: true
  alias Ryker.Admission
  alias Ryker.Admission.{Context, Decision, Prompt}
  alias Ryker.Episodes
  alias Ryker.Episodes.Command
  alias Ryker.Ingress.{Inbox, Input}
  alias Ryker.Learning.ConversationObservation
  alias Ryker.Repo
  alias Ryker.Slack.ChannelMembership
  alias Ryker.Slack.Input, as: SlackInput

  @moduletag isolation: "REPEATABLE READ"
  @fixture Path.expand("fixtures/history_authorization/cross_channel_health_check.json", __DIR__)

  setup do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    workspace = "THISTORY#{System.unique_integer([:positive])}"
    now = datetime!(fixture["incoming"]["occurred_at"])

    for channel <- [fixture["active"]["channel_ref"], fixture["incoming"]["channel_ref"]] do
      Repo.insert!(%ChannelMembership{
        workspace_ref: workspace,
        channel_ref: channel,
        private: false,
        external_shared: false,
        generation: 1,
        status: :joined,
        joined_at: now
      })
    end

    history = seed!(fixture["history"]["input"], workspace)
    active = seed!(fixture["active"], workspace)
    {:ok, fixture: fixture, workspace: workspace, now: now, history: history, active: active}
  end

  test "inaccessible unselected history cannot spend a valid continuation's routing attempts",
       %{fixture: fixture, workspace: workspace, now: now, history: history, active: active} do
    # A captured health check spent all eight attempts on context_stale even
    # after the model chose the right active task: one unrelated old source
    # was conversation-only, but every offered candidate entered its custody.
    restrict_history!(history)
    entry = record!(fixture["incoming"], workspace)
    context = context!(entry, now)

    refute Enum.any?(context.candidates, &(&1.episode.id == history.id))
    candidate = Enum.find(context.candidates, &(&1.episode.id == active.id))
    assert candidate
    assert context.routing_receipt["offered"] == length(context.candidates)

    refute Enum.any?(
             context.candidate_messages,
             &(&1["message_ref"] == history.source_item_ref)
           )

    request = Prompt.build(context)
    refute Jason.encode!(request) =~ fixture["history"]["input"]["content"]["text"]
    refute Enum.any?(context.source_dependencies, &(&1["source_input_id"] == history.id))

    assert {:ok, decision} =
             fixture["decision"] |> Map.put("episode_ref", candidate.ref) |> Decision.parse()

    assert {:ok, result} = Admission.commit(context, decision, "history-authorization")
    assert result.entry.status == :decided
    assert result.episode.id == active.id
  end

  test "conversation-only history remains available inside its original conversation", %{
    fixture: fixture,
    workspace: workspace,
    now: now,
    history: history,
    active: active
  } do
    restrict_history!(history)

    incoming =
      Map.put(fixture["incoming"], "channel_ref", fixture["active"]["channel_ref"])

    entry = record!(incoming, workspace)
    context = context!(entry, now)
    assert Enum.any?(context.candidates, &(&1.episode.id == history.id))
    assert Enum.any?(context.source_dependencies, &(&1["source_input_id"] == history.id))
    assert Context.for_model(context)["candidates"] != []
    candidate = Enum.find(context.candidates, &(&1.episode.id == active.id))

    assert {:ok, decision} =
             fixture["decision"] |> Map.put("episode_ref", candidate.ref) |> Decision.parse()

    assert {:ok, _result} = Admission.commit(context, decision, "same-conversation-history")
  end

  test "source authorization still refuses history restricted after the briefing was frozen",
       %{fixture: fixture, workspace: workspace, now: now, history: history, active: active} do
    entry = record!(fixture["incoming"], workspace)
    context = context!(entry, now)
    assert Enum.any?(context.candidates, &(&1.episode.id == history.id))
    candidate = Enum.find(context.candidates, &(&1.episode.id == active.id))
    restrict_history!(history)

    assert {:ok, decision} =
             fixture["decision"] |> Map.put("episode_ref", candidate.ref) |> Decision.parse()

    assert Admission.commit(context, decision, "revoked-history") ==
             {:error, {:admission_rejected, :context_stale}}
  end

  defp restrict_history!(entry) do
    entry.id
    |> ConversationObservation.Query.by_id()
    |> Repo.one!()
    |> Ecto.Changeset.change(visibility: :conversation)
    |> Repo.update!()
  end

  defp seed!(document, workspace) do
    entry = record!(document, workspace)
    input = input!(document, workspace)

    assert {:ok, _transition} =
             Episodes.apply(%Command.AdmitInput{
               actor_ref: Input.actor_ref(input),
               destination: input.destination,
               episode_id: entry.id,
               episode_key: Inbox.ref(entry),
               linked_episode_id: nil,
               native_input_id: input.native_input_id,
               occurred_at: input.occurred_at,
               payload: Input.document(input),
               revision: input.revision,
               turn_ref: "history-turn:#{entry.id}"
             })

    entry
  end

  defp record!(document, workspace) do
    assert {:ok, %{entry: entry}} = Inbox.record(input!(document, workspace))
    entry
  end

  defp input!(document, workspace) do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: document["actor"]["ref"]},
               channel_ref: document["channel_ref"],
               content: document["content"],
               event_kind: :message,
               event_ref: document["event_ref"],
               message_ref: document["message_ref"],
               occurred_at: datetime!(document["occurred_at"]),
               revision: document["revision"],
               thread_ref: document["thread_ref"],
               workspace_ref: workspace
             })

    input
  end

  defp context!(entry, now) do
    assert {:ok, context} =
             Admission.context(Inbox.ref(entry),
               now: now,
               continuation_window: 1_800,
               history_window: 30 * 24 * 60 * 60,
               candidate_limit: 8
             )

    context
  end

  defp datetime!(value) do
    {:ok, at, 0} = DateTime.from_iso8601(value)
    at
  end
end
