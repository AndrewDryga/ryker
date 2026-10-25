defmodule Ryker.Admission.HistoryAuthorizationTest do
  use Ryker.DataCase, async: true
  alias Ryker.Admission
  alias Ryker.Admission.{Context, Decision, Executor, Prompt}
  alias Ryker.Episodes
  alias Ryker.Episodes.Command
  alias Ryker.Fixtures.LocalRouting
  alias Ryker.Ingress.{Inbox, Input}
  alias Ryker.Learning.ConversationObservation
  alias Ryker.Repo
  alias Ryker.Slack.ChannelMembership
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.TestSupport.FakeCoopAPI, as: FakeAPI
  alias Ryker.Work.Session

  @moduletag isolation: "REPEATABLE READ"
  @fixture Path.expand("fixtures/history_authorization/cross_channel_health_check.json", __DIR__)
  @scope_fixture Path.expand(
                   "fixtures/history_authorization/cross_environment_health_check.json",
                   __DIR__
                 )

  setup do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    scopes = @scope_fixture |> File.read!() |> Jason.decode!()
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

    {:ok,
     fixture: fixture,
     scopes: scopes,
     workspace: workspace,
     now: now,
     history: history,
     active: active}
  end

  # A resumed routing generation bypassed the new selector and could disclose
  # its prepatch summary from another product. This must fail before submit.
  for provenance <- [:foreign, :unknown, :unlabeled] do
    test "a frozen #{provenance} thread summary is rebuilt before another model disclosure", %{
      fixture: fixture,
      scopes: scopes,
      workspace: workspace,
      now: now,
      active: active
    } do
      pin!(active, scopes["incoming"])
      entry = scoped_record!(fixture["incoming"], workspace, scopes["incoming"])
      context = context!(entry, now)

      summary = %{
        "state" => %{"situation" => fixture["history"]["input"]["content"]["text"]},
        "covered_through" => DateTime.to_iso8601(now),
        "freshness" => "current"
      }

      summary =
        case unquote(provenance) do
          :foreign ->
            Map.merge(summary, %{
              "environment_ref" => scopes["active"]["environment_ref"],
              "environment_known" => true
            })

          :unknown ->
            Map.merge(summary, %{"environment_ref" => nil, "environment_known" => false})

          :unlabeled ->
            summary
        end

      snapshot =
        context
        |> Context.snapshot()
        |> put_in(["conversation_context", "thread_summary"], summary)

      claimed = claim!(entry, now)
      assert {:ok, _} = Inbox.bind_context(Inbox.ref(entry), claimed.lease_ref, snapshot)
      {:ok, fake} = FakeAPI.start_link([LocalRouting.hi_quick_reply()])

      assert Executor.run(Inbox.ref(entry), executor_options(fake, claimed.lease_ref, now)) ==
               {:error, {:admission_generation_spent, {:admission_rejected, :context_stale}}}

      assert FakeAPI.state(fake).submit_count == 0
    end
  end

  for mismatch <- [:environment, :connection, :both] do
    @mismatch mismatch
    test "an identical health request cannot inherit another #{@mismatch} scope", %{
      fixture: fixture,
      scopes: scopes,
      workspace: workspace,
      now: now,
      active: active
    } do
      # The recovered message joined a different environment's session and
      # received its database/backup findings. A successful commit was the
      # wrong proof: both environment and Emisar connection must stay local.
      scope = scopes["active"]
      incoming = scopes["incoming"]

      scope =
        case @mismatch do
          :environment ->
            Map.put(scope, "emisar_connection_ref", incoming["emisar_connection_ref"])

          :connection ->
            Map.put(scope, "environment_ref", incoming["environment_ref"])

          :both ->
            scope
        end

      pin!(active, scope)
      entry = scoped_record!(fixture["incoming"], workspace, incoming)
      context = context!(entry, now)
      refute Enum.any?(context.candidates, &(&1.episode.id == active.id))
    end
  end

  test "an exact source owner cannot bypass the incoming environment boundary", %{
    fixture: fixture,
    scopes: scopes,
    workspace: workspace,
    now: now,
    active: active
  } do
    pin!(active, scopes["active"])

    revised =
      fixture["active"]
      |> Map.put("event_ref", "EvTenantScopeRevision")
      |> Map.put("revision", fixture["active"]["revision"] + 1)
      |> Map.put("occurred_at", fixture["incoming"]["occurred_at"])

    entry = scoped_record!(revised, workspace, scopes["incoming"])

    options = [
      now: now,
      continuation_window: 1_800,
      history_window: 2_592_000,
      candidate_limit: 8
    ]

    assert Admission.context(Inbox.ref(entry), options) ==
             {:error, {:admission_execution_blocked, :source_owner_scope_changed}}

    {:ok, fake} = FakeAPI.start_link([])

    claimed = claim!(entry, now)

    assert Executor.run(Inbox.ref(entry), executor_options(fake, claimed.lease_ref, now)) ==
             {:error, {:admission_execution_blocked, :source_owner_scope_changed}}

    assert FakeAPI.state(fake).submit_count == 0
    assert Repo.get!(Inbox.Entry, entry.id).status == :pending
  end

  test "same-environment cross-channel work retains its selected repository and session", %{
    fixture: fixture,
    scopes: scopes,
    workspace: workspace,
    now: now,
    active: active
  } do
    scope = scopes["incoming"]
    session_scope = Map.put(scope, "repository_ref", scopes["active"]["repository_ref"])
    session = pin!(active, session_scope)
    entry = scoped_record!(fixture["incoming"], workspace, scope)
    context = context!(entry, now)
    assert candidate = Enum.find(context.candidates, &(&1.episode.id == active.id))

    assert {:ok, decision} =
             scopes["decision"] |> Map.put("episode_ref", candidate.ref) |> Decision.parse()

    assert {:ok, result} = Admission.commit(context, decision, "same-environment-continuation")
    assert result.episode.id == active.id
    assert Repo.get_by!(Session, episode_id: active.id).id == session.id
    assert Repo.get!(Session, session.id).repository_ref == scopes["active"]["repository_ref"]
  end

  test "foreign evidence invalidates a frozen briefing even when the answer selects no episode",
       %{
         fixture: fixture,
         scopes: scopes,
         workspace: workspace,
         now: now,
         active: active
       } do
    # A pre-deploy briefing can contain the same foreign findings as the
    # misrouted health check. Reject its whole answer, including a quick
    # reply with no selection, and rebuild before sending another prompt.
    session = pin!(active, scopes["incoming"])
    entry = scoped_record!(fixture["incoming"], workspace, scopes["incoming"])
    context = context!(entry, now)
    assert Enum.any?(context.candidates, &(&1.episode.id == active.id))
    snapshot = Context.snapshot(context)
    claimed = claim!(entry, now)
    assert {:ok, frozen} = Inbox.bind_context(Inbox.ref(entry), claimed.lease_ref, snapshot)

    session
    |> Ecto.Changeset.change(emisar_connection_ref: scopes["active"]["emisar_connection_ref"])
    |> Repo.update!()

    quick_reply_document = LocalRouting.hi_quick_reply() |> Jason.decode!()
    assert {:ok, quick_reply} = Decision.parse(quick_reply_document)
    assert quick_reply.episode_ref == nil

    assert Admission.validate(context, quick_reply) ==
             {:error, {:admission_rejected, :work_scope_not_allowed}}

    assert Admission.commit(context, quick_reply, "foreign-unselected-evidence",
             lease_ref: claimed.lease_ref
           ) ==
             {:error, {:admission_rejected, :work_scope_not_allowed}}

    assert Admission.restore_context(frozen, claimed.lease_ref) ==
             {:error, {:admission_rejected, :work_scope_not_allowed}}

    {:ok, fake} = FakeAPI.start_link([LocalRouting.hi_quick_reply()])

    assert Executor.run(Inbox.ref(entry), executor_options(fake, claimed.lease_ref, now)) ==
             {:error,
              {:admission_generation_spent, {:admission_rejected, :work_scope_not_allowed}}}

    assert FakeAPI.state(fake).submit_count == 0
    assert Repo.get!(Inbox.Entry, entry.id).status == :pending
  end

  defp executor_options(fake, lease_ref, now) do
    [
      api: FakeAPI,
      client: fake,
      lease_ref: lease_ref,
      max_polls: 10,
      now: fn -> now end,
      policy: "admission-read-only",
      policy_digest: String.duplicate("a", 64),
      poll_interval_ms: 0,
      renew_lease: fn -> :ok end,
      sleep: fn _milliseconds -> :ok end
    ]
  end

  defp claim!(entry, now) do
    entry
    |> Inbox.Entry.Changeset.claim(%{
      attempt_count: 1,
      lease_ref: "scope-lease:#{entry.id}",
      lease_owner: "scope-test",
      lease_expires_at: DateTime.add(now, 300)
    })
    |> Repo.update!()
  end

  test "a frozen valid choice cannot cross an environment pin established before commit", %{
    fixture: fixture,
    scopes: scopes,
    workspace: workspace,
    now: now,
    active: active
  } do
    session = pin!(active, scopes["incoming"])
    entry = scoped_record!(fixture["incoming"], workspace, scopes["incoming"])
    context = context!(entry, now)
    assert candidate = Enum.find(context.candidates, &(&1.episode.id == active.id))

    assert {:ok, decision} =
             scopes["decision"] |> Map.put("episode_ref", candidate.ref) |> Decision.parse()

    session
    |> Ecto.Changeset.change(environment_ref: scopes["active"]["environment_ref"])
    |> Repo.update!()

    assert Admission.commit(context, decision, "changed-environment-pin") ==
             {:error, {:admission_rejected, :work_scope_not_allowed}}

    assert Repo.get!(Inbox.Entry, entry.id).status == :pending
  end

  defp pin!(entry, scope) do
    Repo.insert!(%Session{
      episode_id: entry.id,
      external_ref: "scoped-history:#{entry.id}",
      policy: "recorded-scope",
      policy_digest: String.duplicate("a", 64),
      environment_ref: scope["environment_ref"],
      emisar_connection_ref: scope["emisar_connection_ref"],
      repository_ref: scope["repository_ref"]
    })
  end

  defp scoped_record!(document, workspace, scope) do
    repositories = Enum.uniq([scope["repository_ref"], "tenant-shared-infra"])

    profile = %{
      environment_ref: scope["environment_ref"],
      emisar_connection_ref: scope["emisar_connection_ref"],
      parallel_goal_limit: 2,
      repositories: repositories,
      policies:
        Map.new(repositories, fn repository ->
          {repository,
           Map.new([:conversational, :standard, :deep], fn work_class ->
             {work_class,
              %{
                authority_digest: String.duplicate("e", 64),
                policy: "#{repository}-#{work_class}",
                policy_digest: String.duplicate("b", 64)
              }}
           end)}
        end)
    }

    assert {:ok, %{entry: entry}} =
             Inbox.record(input!(document, workspace), work_profile: profile)

    entry
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

    excluded =
      Enum.find(context.routing_receipt["selection"]["items"], &(&1["episode_id"] == history.id))

    assert excluded["reason"] == "source_unavailable"
    assert excluded["offered"] == false

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
