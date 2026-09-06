defmodule Responder.State.ObservationsTest do
  use Responder.DataCase, async: false
  @moduletag isolation: "REPEATABLE READ"
  import Ecto.Query
  alias Responder.{Admission, Repo}
  alias Responder.Admission.{Context, Decision, Executor, Prompt}
  alias Responder.ControlPlane.{ConversationMemory, HTML, Projection}
  alias Responder.Episodes.Episode
  alias Responder.Ingress.Inbox
  alias Responder.Retention.Data
  alias Responder.Slack.{ChannelMembership, Input}
  alias Responder.State.{Continuity, ConversationObservation, Observations}
  alias Responder.TestSupport.FakeCoopAPI, as: FakeAPI

  @now ~U[2026-09-06 10:00:00.000000Z]
  # Harvested from the Blitz service-retention discussion, not a synthetic policy.
  @message "`draft-ai-suggestions`\nplanning to look into it at some point, let’s keep it"
  @note %{
    "summary" =>
      "U03EPT4RP5M wants to keep `draft-ai-suggestions` and plans to look into it at an unspecified future time.",
    "topics" => ["draft-ai-suggestions"]
  }

  test "Memory shows silently learned notes with sources and visible search controls" do
    entry = observe!("visible", "C1", @note)
    # A replay's import time and raw UUID are not the date or substance of the discussion.
    Repo.update_all(from(n in ConversationObservation, where: n.id == ^entry.id),
      set: [note: %{@note | "summary" => @note["summary"] <> " Source: message #{entry.id}."}]
    )

    snapshot = Projection.memory()
    [item] = snapshot.conversation_memory.items
    assert item.at == @now
    assert item.text == @note["summary"]
    html = HTML.memory(snapshot, "test-secret") |> IO.iodata_to_binary()
    assert html =~ "draft-ai-suggestions"
    assert html =~ "Source message"
    assert html =~ "name=\"q\""
    assert html =~ "Conversation notes"
  end

  test "memory resolves bare people references without corrupting mentions, code or links" do
    # Model summaries mix bare attribution IDs with already-formatted source content.
    text =
      "U03EPT4RP5M and <@U03EPT4RP5M> kept `U03EPT4RP5M`.\n\n```U03EPT4RP5M```\n\n[record](https://example.test/U03EPT4RP5M)"

    observe!("formatting", "C1", %{@note | "summary" => text})
    html = HTML.memory(Projection.memory(), "test-secret") |> IO.iodata_to_binary()
    assert length(Regex.scan(~r/class="slack-mention"/, html)) == 2
    assert html =~ "<code>U03EPT4RP5M</code>"
    assert html =~ "<pre><code>U03EPT4RP5M</code></pre>"
    assert html =~ "href=\"https://example.test/U03EPT4RP5M\""
    refute html =~ "&lt;@"
  end

  test "memory expiry is the configured retention horizon, not the original message date" do
    previous = Application.get_env(:responder, :retention)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:responder, :retention, previous),
        else: Application.delete_env(:responder, :retention)
    end)

    Application.put_env(:responder, :retention, %{conversation_memory_seconds: 7_776_000})
    entry = observe!("expiry", "C1", @note)
    saved = Repo.get!(ConversationObservation, entry.id)
    [item] = ConversationMemory.project(%{"kind" => "notes"}).items
    assert item.expires_at == DateTime.add(saved.updated_at, 7_776_000)
    html = HTML.memory(Projection.memory(), "test-secret") |> IO.iodata_to_binary()
    assert html =~ "Retention"
    assert html =~ Calendar.strftime(item.expires_at, "%d %b %Y")
    Application.delete_env(:responder, :retention)
    [item] = ConversationMemory.project(%{"kind" => "notes"}).items
    assert item.expires_at == nil
  end

  for channel <- ["CSOURCE", "CTARGET"], boundary <- [:restored, :completed] do
    test "#{boundary} routing rejects frozen notes after #{channel} access changes" do
      # A persisted prompt must not carry formerly-public notes through retry or commit.
      joined!("TNOTES", "CSOURCE")
      joined!("TNOTES", "CTARGET")
      observe!("learn-first", "CSOURCE", @note)
      target = input!("route-later", "CTARGET")
      {:ok, %{lease_ref: lease}} = Inbox.claim_next("privacy-test", @now, 300)

      {:ok, context} =
        Admission.context(Inbox.ref(target),
          now: @now,
          lease_ref: lease,
          continuation_window: 1_800,
          history_window: 604_800,
          candidate_limit: 20
        )

      assert length(context.observations) == 1
      {:ok, _} = Inbox.bind_context(Inbox.ref(target), lease, Context.snapshot(context))

      candidate =
        Jason.encode!(%{
          "action" => "ignore",
          "episode_ref" => nil,
          "reaction" => nil,
          "relation" => "unrelated",
          "reason" => "No response needed.",
          "work_class" => nil
        })

      {:ok, fake} = FakeAPI.start_link([candidate])

      revoke = fn ->
        Repo.update_all(from(m in ChannelMembership, where: m.channel_ref == ^unquote(channel)),
          set: [private: true]
        )

        :ok
      end

      options = [
        api: FakeAPI,
        client: fake,
        lease_ref: lease,
        max_polls: 10,
        now: fn -> @now end,
        policy: "admission-read-only",
        policy_digest: String.duplicate("a", 64),
        renew_lease: fn -> :ok end,
        sleep: fn _ -> :ok end,
        settle_execution_session: fn _, _ ->
          if unquote(boundary) == :completed, do: revoke.(), else: :ok
        end
      ]

      if unquote(boundary) == :restored, do: revoke.()

      assert {:error, {:admission_generation_spent, {:admission_rejected, :context_stale}}} =
               Executor.run(Inbox.ref(target), options)

      assert {:ok, %{status: :pending, decision_ref: nil}} = Inbox.fetch(Inbox.ref(target))

      assert FakeAPI.state(fake).submit_count ==
               if(unquote(boundary) == :restored, do: 0, else: 1)

      assert Repo.aggregate(Episode, :count) == 0
    end
  end

  test "silent shadow observations are recalled by later live work and frozen routing" do
    joined!("TNOTES", "C1")
    first = observe!("first", "C1", @note, mode: :shadow)

    next =
      input!("next", "C1",
        text: "Why are we keeping that service?",
        message_ref: "1787832000.000101"
      )

    context = context!(next)
    assert [%{"summary" => summary}] = context.observations
    assert summary == @note["summary"]
    assert Prompt.build(context)["context"]["conversation_observations"] == context.observations
    assert {:ok, restored} = Context.restore(Context.snapshot(context), context.input, next, %{})
    assert restored.observations == context.observations

    destination = destination(next)

    assert [%{"source_input_id" => source}] =
             Continuity.model_context(destination, "blitz-infra")["observations"]

    assert source == first.id

    assert [%{"topics" => ["draft-ai-suggestions"]}] =
             Continuity.search_context(
               destination,
               "blitz-infra",
               "draft-ai",
               "current_channel",
               10
             )
  end

  test "silent notes outlive operational records and expire at the memory horizon" do
    # Learning must not disappear when the much shorter execution-detail retention runs.
    entry = observe!("memory-retention", "C1", @note)
    old = DateTime.add(DateTime.utc_now(), -2 * 86_400, :second)
    Repo.update_all(ConversationObservation, set: [updated_at: old])

    settings = %{
      operational_data_seconds: 86_400,
      closed_work_seconds: 86_400,
      episode_history_seconds: 86_400,
      audit_data_seconds: 86_400,
      conversation_memory_seconds: 90 * 86_400
    }

    assert {:ok, _} = Data.prune(settings)
    assert [_] = Observations.context(entry, nil)

    Repo.update_all(ConversationObservation,
      set: [updated_at: DateTime.add(old, -90 * 86_400, :second)]
    )

    assert {:ok, _} = Data.prune(settings)
    assert Observations.context(entry, nil) == []
  end

  test "Memory searches all notes before paging and malformed filter values remain usable" do
    # A decision must remain discoverable after newer chat pushes it off the first page.
    for n <- 1..32 do
      observe!("page-#{n}", "C1", %{@note | "summary" => "Decision #{n}"},
        message_ref: "1787832000.#{String.pad_leading(to_string(n), 6, "0")}"
      )
    end

    first = ConversationMemory.project(%{"kind" => "notes"})
    assert first.total == 32
    assert length(first.items) == 30
    assert first.pages == 2

    filtered =
      ConversationMemory.project(%{
        "kind" => "notes",
        "q" => "Decision 32",
        "page" => "99"
      })

    assert [%{text: "Decision 32"}] = filtered.items
    assert filtered.page == 1

    assert %{page: 1, q: ""} =
             ConversationMemory.project(%{"page" => [], "q" => %{}})
  end

  test "cross-channel recall requires public source and destination membership in the same workspace" do
    for channel <- ~w(C1 C2 CPRIVATE CSHARED) do
      joined!("TNOTES", channel, channel == "CPRIVATE", channel == "CSHARED")
    end

    for channel <- ~w(C1 CPRIVATE CSHARED CUNKNOWN) do
      observe!(channel, channel, %{@note | "summary" => "#{channel} #{@note["summary"]}"})
    end

    target = input!("target", "C2")
    assert [public] = Observations.context(target, "blitz-infra")
    assert public["conversation_ref"] == "slack:TNOTES:C1"

    Repo.update_all(from(m in ChannelMembership, where: m.channel_ref == "C1"),
      set: [status: :left, left_at: @now]
    )

    assert Observations.context(target, "blitz-infra") == []
    private_target = input!("private-target", "CPRIVATE", message_ref: "1787832000.000101")
    assert [private] = Observations.context(private_target, "blitz-infra")
    assert private["conversation_ref"] == "slack:TNOTES:CPRIVATE"
    another_workspace = %{target | destination_conversation_ref: "slack:OTHER:C2"}
    assert Observations.context(another_workspace, "blitz-infra") == []
  end

  test "edits and deletions replace source notes and a delayed older revision cannot resurrect them" do
    first = observe!("source", "C1", @note)

    updated =
      observe!(
        "edited",
        "C1",
        %{@note | "summary" => "The author has withdrawn the request to keep the service."},
        revision: 2,
        kind: :edit
      )

    assert Repo.aggregate(ConversationObservation, :count) == 1
    assert [note] = Observations.context(updated, nil)
    assert note["summary"] =~ "withdrawn"

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Observations.record_in_transaction(first, @note, "delayed")
             end)

    assert Observations.context(updated, nil) == [note]
    deleted = observe!("deleted", "C1", @note, revision: 3, kind: :delete)
    assert Observations.context(deleted, nil) == []
    assert Repo.one!(ConversationObservation).revision == 3
  end

  test "saved routing notes are rejected when destination or source access is revoked" do
    joined!("TNOTES", "CSOURCE")
    joined!("TNOTES", "CTARGET")
    observe!("revoked", "CSOURCE", @note)
    target = input!("later-request", "CTARGET")
    notes = context!(target).observations
    assert length(notes) == 1
    assert :ok = Observations.reauthorize(target, nil, notes)

    Repo.update_all(from(m in ChannelMembership, where: m.channel_ref == "CTARGET"),
      set: [external_shared: true]
    )

    assert {:error, {:admission_rejected, :context_stale}} =
             Observations.reauthorize(target, nil, notes)

    Repo.update_all(from(m in ChannelMembership, where: m.channel_ref == "CTARGET"),
      set: [external_shared: false]
    )

    Repo.update_all(from(m in ChannelMembership, where: m.channel_ref == "CSOURCE"),
      set: [private: true]
    )

    assert {:error, {:admission_rejected, :context_stale}} =
             Observations.reauthorize(target, nil, notes)
  end

  test "channel deletion also removes silent notes and neither an old source nor recall restores them" do
    joined!("TNOTES", "C1")
    entry = observe!("delete-channel", "C1", @note)
    Repo.update_all(ChannelMembership, set: [status: :deleted, deleted_at: @now])

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Continuity.delete_slack_channel_in_transaction("TNOTES", "C1")
             end)

    assert Repo.aggregate(ConversationObservation, :count) == 0

    assert {:ok, :ok} =
             Repo.transaction(fn -> Observations.record_in_transaction(entry, @note, "old") end)

    assert Observations.context(entry, nil) == []
    assert Repo.aggregate(ConversationObservation, :count) == 0
  end

  test "unaccepted decisions and caller-selected source scopes cannot become notes" do
    entry = input!("pending", "C1")

    assert {:error, :observation_source_not_decided} =
             Observations.record_in_transaction(entry, @note, "bad")

    for invalid <- [
          Map.put(@note, "conversation_ref", "slack:OTHER:C1"),
          %{@note | "summary" => " "},
          %{@note | "topics" => List.duplicate("topic", 9)}
        ] do
      assert {:error, {:invalid_decision, :observation}} = Observations.prepare(invalid)
    end

    # Receipt custody keeps only a revision fence until classification succeeds.
    assert [%{note: nil, source_result_ref: nil}] = Repo.all(ConversationObservation)
    assert Observations.context(entry, nil) == []
  end

  defp observe!(event, channel, note, options \\ []) do
    entry = input!(event, channel, options)
    context = context!(entry)

    {:ok, decision} =
      Decision.parse(%{
        "action" => "ignore",
        "episode_ref" => nil,
        "reaction" => nil,
        "relation" => "unrelated",
        "reason" => "A conversation decision requires no interruption.",
        "work_class" => nil,
        "observation" => note
      })

    {:ok, %{entry: decided}} = Admission.commit(context, decision, "learned:#{event}")
    decided
  end

  defp input!(event, channel, options \\ []) do
    {:ok, input} =
      Input.new(%{
        actor: %{kind: :user, ref: "U03EPT4RP5M"},
        channel_ref: channel,
        workspace_ref: "TNOTES",
        message_ref: Keyword.get(options, :message_ref, "1787832000.000100"),
        thread_ref: nil,
        event_ref: event,
        revision: Keyword.get(options, :revision, 1),
        event_kind: Keyword.get(options, :kind, :message),
        occurred_at: @now,
        content: %{"text" => Keyword.get(options, :text, @message)}
      })

    {:ok, %{entry: entry}} =
      Inbox.record(input,
        execution_mode: Keyword.get(options, :mode, :live),
        work_profile: %{
          policy: "test-read-only",
          policy_digest: String.duplicate("a", 64),
          repository_ref: "blitz-infra"
        }
      )

    entry
  end

  defp destination(entry),
    do:
      struct!(
        Episode,
        Map.take(
          Map.from_struct(entry),
          [:destination_transport, :destination_conversation_ref, :destination_thread_ref]
        )
      )

  defp context!(entry) do
    {:ok, context} =
      Admission.context(Inbox.ref(entry),
        now: @now,
        continuation_window: 1_800,
        history_window: 604_800,
        candidate_limit: 20
      )

    context
  end

  defp joined!(workspace, channel, private \\ false, shared \\ false) do
    Repo.insert!(%ChannelMembership{
      id: Ecto.UUID.generate(),
      workspace_ref: workspace,
      channel_ref: channel,
      private: private,
      external_shared: shared,
      generation: 1,
      status: :joined,
      joined_at: @now
    })
  end
end
