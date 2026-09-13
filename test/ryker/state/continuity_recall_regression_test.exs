defmodule Ryker.State.ContinuityRecallRegressionTest do
  use Ryker.DataCase, async: false

  alias Ryker.{CanonicalJSON, Repo}
  alias Ryker.Episodes.Episode
  alias Ryker.Fixtures.Learning, as: LearningFixtures
  alias Ryker.Slack.ChannelMembership

  alias Ryker.State.{
    Continuity,
    ConversationObservation,
    ConversationRollup,
    ConversationSummary,
    LearningSources,
    Observations
  }

  # Copied verbatim from the "cross-channel operational continuity" behavioral
  # scenario in testdata/eval/scenarios.jsonl. The 64 unrelated rows below are
  # structural cardinality expansion only; they are not claimed model output.
  @captured_situation "Host and runtime checks passed; Cloud SQL latency remains unverified."
  @captured_query "Cloud SQL latency"
  @now ~U[2026-09-07 12:00:00.000000Z]

  for kind <- [:summary, :rollup] do
    test "automatic #{kind} recall validates only the ranked results it needs" do
      # Each retained dependency list can reach 8 MiB. Loading and validating
      # all 64 candidates just to return 4 or 8 causes avoidable memory and I/O.
      [input | _] = captured_inputs!()
      memory = captured_memory!(unquote(kind), input, older: false)
      expand_stale_memory!(unquote(kind), memory)
      handler = {__MODULE__, make_ref()}
      reference = make_ref()

      :ok =
        :telemetry.attach(
          handler,
          [:ryker, :repo, :query],
          &__MODULE__.record_validation/4,
          {self(), reference}
        )

      try do
        key = if unquote(kind) == :summary, do: "related", else: "rollups"

        context =
          Continuity.model_context(
            target(input.destination_conversation_ref),
            input.repository_ref
          )

        assert length(context[key]) == if(unquote(kind) == :summary, do: 8, else: 4)
        assert count_validations(reference) <= length(context[key]) + 1
      after
        :telemetry.detach(handler)
      end
    end

    test "64 newer withdrawn #{kind} receipts cannot hide healthy older automatic memory" do
      # The automatic 64-row window ran before source reauthorization, making
      # healthy memory disappear after a burst of stale derived records.
      [healthy_input, stale_input] = captured_inputs!()
      workspace = healthy_input.source_ref
      joined!("CPUBLIC", workspace_ref: workspace)
      joined!("CPRIVATE", workspace_ref: workspace, private: true)
      healthy = captured_memory!(unquote(kind), healthy_input, older: true)
      stale = captured_memory!(unquote(kind), stale_input, older: false)
      expand_stale_memory!(unquote(kind), stale)

      assert {:ok, :ok} =
               Repo.transaction(fn ->
                 Observations.receive_in_transaction(%{
                   stale_input
                   | id: Ecto.UUID.generate(),
                     event_kind: :delete,
                     revision: stale_input.revision + 1,
                     event_fingerprint: String.duplicate("f", 64)
                 })
               end)

      key = if unquote(kind) == :summary, do: "related", else: "rollups"

      for conversation <- [
            healthy_input.destination_conversation_ref,
            "slack:#{workspace}:CPUBLIC"
          ] do
        context = Continuity.model_context(target(conversation), healthy_input.repository_ref)
        assert [%{"source_ref" => ref}] = context[key]
        assert ref == healthy.ref
      end

      for conversation <- ["slack:#{workspace}:CPRIVATE", "slack:TFOREIGN:CFOR"] do
        assert Continuity.model_context(target(conversation), healthy_input.repository_ref)[key] ==
                 []
      end
    end

    for {clock, retention} <- [
          {"not-a-timestamp", 3600},
          {"infinity", 3600},
          {"-infinity", nil},
          {"now", 3600},
          {:nonzero_offset, 3600},
          {:negative_colon_zero, 3600},
          {:end_of_day, 3600},
          {:trailing_newline, 3600}
        ] do
      test "#{inspect(clock)} #{kind} source clocks cannot hide healthy automatic memory" do
        retention!(unquote(retention))
        [healthy_input, corrupt_input] = captured_inputs!()
        healthy = captured_memory!(unquote(kind), healthy_input, older: true)
        corrupt = captured_memory!(unquote(kind), corrupt_input, older: false)
        [receipt] = corrupt.source_dependencies

        clock = invalid_clock(unquote(clock), receipt["retained_at"])

        refute match?({:ok, _, 0}, DateTime.from_iso8601(clock))

        corrupt =
          Repo.update!(
            Ecto.Changeset.change(corrupt,
              source_dependencies: [Map.put(receipt, "retained_at", clock)]
            )
          )

        expand_stale_memory!(unquote(kind), corrupt)
        key = if unquote(kind) == :summary, do: "related", else: "rollups"

        context =
          Continuity.model_context(
            target(healthy_input.destination_conversation_ref),
            healthy_input.repository_ref
          )

        assert [%{"source_ref" => ref}] = context[key]
        assert ref == healthy.ref
      end
    end

    test "finite UTC #{kind} clocks retain zero-offset and fractional-precision spellings" do
      retention!(3600)
      [input | _] = captured_inputs!()
      memory = captured_memory!(unquote(kind), input, older: true)
      [receipt] = memory.source_dependencies
      second = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      prefix = String.trim_trailing(second, "Z")
      key = if unquote(kind) == :summary, do: "related", else: "rollups"

      for clock <- [
            second,
            prefix <> ".123456Z",
            prefix <> "+00",
            prefix <> "+0000",
            prefix <> "+00:00",
            prefix <> "-00",
            prefix <> "-0000",
            prefix <> ".123456789+00:00",
            String.replace(prefix, "T", " ") <> ",123456789Z"
          ] do
        assert {:ok, _, 0} = DateTime.from_iso8601(clock)

        Repo.update!(
          Ecto.Changeset.change(memory,
            source_dependencies: [Map.put(receipt, "retained_at", clock)]
          )
        )

        context =
          Continuity.model_context(
            target(input.destination_conversation_ref),
            input.repository_ref
          )

        assert Enum.map(context[key], & &1["source_ref"]) == [memory.ref],
               "UTC clock #{inspect(clock)} should remain recallable"
      end
    end
  end

  def record_validation(_event, _measurements, %{query: query}, {owner, reference}) do
    if String.contains?(query, "conversation_observations") and
         String.contains?(query, "FOR SHARE"),
       do: send(owner, {reference, :validated})
  end

  defp count_validations(reference, count \\ 0) do
    receive do
      {^reference, :validated} -> count_validations(reference, count + 1)
    after
      0 -> count
    end
  end

  defp retention!(seconds) do
    previous = Application.get_env(:ryker, :retention)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ryker, :retention, previous),
        else: Application.delete_env(:ryker, :retention)
    end)

    Application.put_env(:ryker, :retention, %{conversation_memory_seconds: seconds})
  end

  defp invalid_clock(:nonzero_offset, at), do: String.replace(at, "Z", "+00:30")
  defp invalid_clock(:negative_colon_zero, at), do: String.replace(at, "Z", "-00:00")
  defp invalid_clock(:end_of_day, at), do: String.slice(at, 0, 10) <> "T24:00:00Z"
  defp invalid_clock(:trailing_newline, at), do: at <> "\n"
  defp invalid_clock(value, _at), do: value

  test "64 private summary aggregates with public receipts cannot hide healthy public memory" do
    # Receipt visibility and aggregate visibility are captured at different times.
    # A later public membership must not make private aggregates spend recall slots.
    [healthy_input, private_input] = captured_inputs!()
    workspace = healthy_input.source_ref
    joined!("CPUBLIC", workspace_ref: workspace)
    healthy = captured_memory!(:summary, healthy_input, older: true)
    private = captured_memory!(:summary, private_input, older: false)
    private = Repo.update!(Ecto.Changeset.change(private, visibility: :private))
    expand_stale_memory!(:summary, private)

    reader = target("slack:#{workspace}:CPUBLIC")
    assert {:ok, scope} = Continuity.destination_context(reader, healthy_input.repository_ref)
    assert LearningSources.valid?(private.source_dependencies, scope)

    assert [%{"source_ref" => ref}] =
             Continuity.model_context(reader, healthy_input.repository_ref)["related"]

    assert ref == healthy.ref
  end

  defp captured_inputs! do
    # Membership must exist when ingress receipts are saved, not be inferred later.
    [first | _] =
      "testdata/learning/retained-haproxy-lifecycle.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("inputs")

    ["slack", workspace, channel] =
      String.split(first["destination_conversation_ref"], ":", parts: 3)

    joined!(channel, workspace_ref: workspace)
    LearningFixtures.inputs!()
  end

  defp captured_memory!(kind, entry, options) do
    # Reuse both actual retained alert receipts and their exact source title.
    # Duplicate rows below exercise storage cardinality, not invented model answers.
    source = Repo.get_by!(ConversationObservation, source_input_id: entry.id)
    [%{"title" => title}] = entry.content["attachments"]

    case kind do
      :summary ->
        summary = summary!(entry.id, source.conversation_ref, source.visibility, title, source)
        if Keyword.fetch!(options, :older), do: make_older!(summary), else: summary

      :rollup ->
        ["slack", workspace, channel] = String.split(source.conversation_ref, ":", parts: 3)

        scopes = [
          %{"channel_ref" => channel, "transport" => "slack", "workspace_ref" => workspace}
        ]

        rollup!(entry.id, source, state(title), scopes, options)
    end
  end

  defp expand_stale_memory!(:summary, stale),
    do: expand_summaries!(stale, 63, fn _ -> {stale.state, stale.source_dependencies} end)

  defp expand_stale_memory!(:rollup, stale),
    do: expand_rollups!(stale, 63, fn _ -> {stale.state, stale.source_scopes} end)

  test "an older matching continuity state survives more than 64 newer nonmatches" do
    joined!("C1")
    matching = summary!("matching", "slack:T123:C1", :public, @captured_situation)
    make_older!(matching)

    # A query after this window used to see only these structural rows, then
    # discard all of them in Elixir because none contains the requested text.
    expand_summaries!(matching, 64, fn index ->
      {state("Unrelated structural continuity row #{index}."), matching.source_dependencies}
    end)

    target = target("slack:T123:C1")

    assert [
             %{
               "kind" => "continuity",
               "state" => %{"situation" => @captured_situation}
             }
           ] = Continuity.search_context(target, "ryker", @captured_query, "workspace", 1)
  end

  test "private newer continuity cannot consume search capacity ahead of an older public match" do
    joined!("C1")
    joined!("CSECRET", private: true)
    matching = summary!("public-match", "slack:T123:C1", :public, @captured_situation)
    make_older!(matching)

    private =
      summary!(
        "private-source",
        "slack:T123:CSECRET",
        :private,
        "Private channel state that must not cross the channel fence."
      )

    expand_summaries!(private, 64, fn index ->
      {state("Private structural Cloud SQL latency row #{index}."), private.source_dependencies}
    end)

    target = target("slack:T123:C1")

    assert [
             %{
               "kind" => "continuity",
               "state" => %{"situation" => @captured_situation}
             }
           ] = Continuity.search_context(target, "ryker", @captured_query, "workspace", 1)
  end

  test "expired newer continuity sources cannot consume search capacity ahead of an older match" do
    previous = Application.get_env(:ryker, :retention)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ryker, :retention, previous),
        else: Application.delete_env(:ryker, :retention)
    end)

    Application.put_env(:ryker, :retention, %{conversation_memory_seconds: 3600})
    joined!("C1")
    matching = summary!("expired-match", "slack:T123:C1", :public, @captured_situation)
    make_older!(matching)

    expired_sources =
      Enum.map(matching.source_dependencies, fn source ->
        Map.put(
          source,
          "retained_at",
          DateTime.utc_now() |> DateTime.add(-3601) |> DateTime.to_iso8601()
        )
      end)

    expand_summaries!(matching, 64, fn index ->
      {state("Expired structural Cloud SQL latency row #{index}."), expired_sources}
    end)

    target = target("slack:T123:C1")

    assert [
             %{
               "kind" => "continuity",
               "state" => %{"situation" => @captured_situation}
             }
           ] = Continuity.search_context(target, "ryker", @captured_query, "workspace", 1)
  end

  test "invalid newer repository rollup scopes cannot crowd out an older public match" do
    joined!("C1")
    joined!("CSECRET", private: true)
    joined!("CLEFT", status: :left)
    source = observation!("rollup-match", "slack:T123:C1", :public)

    matching =
      rollup!(
        "rollup-match",
        source,
        state(@captured_situation),
        [%{"channel_ref" => "C1", "transport" => "slack", "workspace_ref" => "T123"}],
        older: true
      )

    # These all match the literal query. Before visibility and source-scope
    # checks moved into SQL, the 64-row rollup window excluded `matching`.
    expand_rollups!(matching, 64, fn index ->
      {state("Structural Cloud SQL latency rollup #{index}."), invalid_rollup_scope(index)}
    end)

    public_target = target("slack:T123:C1")

    assert [%{"source_ref" => ref}] =
             Continuity.model_context(public_target, "ryker")["rollups"]

    assert ref == matching.ref

    for scope <- ["workspace", "repository"] do
      assert [
               %{
                 "kind" => "continuity",
                 "state" => %{"situation" => @captured_situation}
               }
             ] = Continuity.search_context(public_target, "ryker", @captured_query, scope, 1)
    end

    assert [] =
             Continuity.search_context(
               public_target,
               "ryker",
               @captured_query,
               "current_channel",
               1
             )

    assert [] =
             Continuity.search_context(
               target("slack:TFOREIGN:CFOR"),
               "ryker",
               @captured_query,
               "workspace",
               1
             )
  end

  defp summary!(suffix, conversation_ref, visibility, situation, source \\ nil) do
    source = source || observation!(suffix, conversation_ref, visibility)
    now = DateTime.utc_now()
    summary_state = state(situation)

    Repo.insert!(%ConversationSummary{
      id: Ecto.UUID.generate(),
      ref: "continuity:#{suffix}:#{Ecto.UUID.generate()}",
      identity_key: CanonicalJSON.digest("summary:#{suffix}:#{Ecto.UUID.generate()}"),
      transport: "slack",
      workspace_ref: source.workspace_ref,
      conversation_ref: conversation_ref,
      thread_ref: "thread:#{suffix}",
      repository_ref: source.repository_ref,
      visibility: visibility,
      state: summary_state,
      source_dependencies: LearningSources.for_source(source),
      state_fingerprint: CanonicalJSON.digest(summary_state),
      source_result_ref: "result:#{suffix}",
      source_message_ref: "message:#{suffix}",
      inserted_at: now,
      updated_at: now
    })
  end

  defp observation!(suffix, conversation_ref, visibility) do
    now = DateTime.utc_now()

    Repo.insert!(%ConversationObservation{
      id: Ecto.UUID.generate(),
      identity_key: CanonicalJSON.digest("observation:#{suffix}:#{Ecto.UUID.generate()}"),
      transport: "slack",
      workspace_ref: "slack:T123",
      conversation_ref: conversation_ref,
      thread_ref: "thread:#{suffix}",
      repository_ref: "ryker",
      visibility: visibility,
      source_input_id: Ecto.UUID.generate(),
      source_message_ref: "message:#{suffix}",
      source_result_ref: "result:#{suffix}",
      source_fingerprint: String.duplicate("a", 64),
      actor_ref: "slack:user:U1",
      execution_mode: :live,
      revision: 1,
      occurred_at: @now,
      inserted_at: now,
      updated_at: now
    })
  end

  defp rollup!(suffix, source, rollup_state, source_scopes, options) do
    now = DateTime.utc_now()

    {period_start, period_end} =
      if Keyword.get(options, :older, false) do
        {DateTime.add(now, -240, :second), DateTime.add(now, -180, :second)}
      else
        {now, now}
      end

    Repo.insert!(%ConversationRollup{
      id: Ecto.UUID.generate(),
      ref: "continuity-rollup:#{suffix}:#{Ecto.UUID.generate()}",
      workspace_ref: source.workspace_ref,
      scope_kind: :repository,
      scope_ref: source.repository_ref,
      repository_ref: source.repository_ref,
      visibility: :public,
      period_start: period_start,
      period_end: period_end,
      state: rollup_state,
      source_dependencies: LearningSources.for_source(source),
      state_fingerprint: CanonicalJSON.digest(rollup_state),
      source_refs: ["observation:#{source.id}"],
      source_scopes: source_scopes,
      source_count: 1,
      expires_at: DateTime.add(now, 3600, :second),
      inserted_at: now,
      updated_at: now
    })
  end

  defp expand_summaries!(summary, count, attributes_for) do
    for index <- 1..count do
      {copied_state, source_dependencies} = attributes_for.(index)

      duplicate = %{
        summary
        | id: Ecto.UUID.generate(),
          ref: "continuity:#{Ecto.UUID.generate()}",
          identity_key: CanonicalJSON.digest("structural:#{Ecto.UUID.generate()}"),
          state: copied_state,
          source_dependencies: source_dependencies,
          state_fingerprint: CanonicalJSON.digest(copied_state),
          updated_at: DateTime.add(DateTime.utc_now(), index, :microsecond)
      }

      Repo.insert!(duplicate)
    end
  end

  defp expand_rollups!(rollup, count, attributes_for) do
    now = DateTime.utc_now()

    for index <- 1..count do
      {copied_state, source_scopes} = attributes_for.(index)
      period_start = DateTime.add(now, index, :microsecond)

      duplicate = %{
        rollup
        | id: Ecto.UUID.generate(),
          ref: "continuity-rollup:#{Ecto.UUID.generate()}",
          period_start: period_start,
          period_end: DateTime.add(period_start, 1, :microsecond),
          state: copied_state,
          source_scopes: source_scopes,
          state_fingerprint: CanonicalJSON.digest(copied_state),
          expires_at: DateTime.add(now, 3600, :second),
          updated_at: now
      }

      Repo.insert!(duplicate)
    end
  end

  defp invalid_rollup_scope(index) do
    case rem(index, 3) do
      0 -> [%{"channel_ref" => "CSECRET", "transport" => "slack", "workspace_ref" => "T123"}]
      1 -> [%{"channel_ref" => "CLEFT", "transport" => "slack", "workspace_ref" => "T123"}]
      2 -> [%{"channel_ref" => "C1", "transport" => "github", "workspace_ref" => "T123"}]
    end
  end

  defp target(conversation_ref) do
    struct!(Episode, %{
      destination_conversation_ref: conversation_ref,
      destination_thread_ref: "thread:target",
      destination_transport: "slack"
    })
  end

  defp make_older!(summary) do
    Repo.update!(
      Ecto.Changeset.change(summary,
        updated_at: DateTime.add(DateTime.utc_now(), -120, :second)
      )
    )
  end

  defp joined!(channel_ref, options \\ []) do
    status = Keyword.get(options, :status, :joined)

    Repo.insert!(%ChannelMembership{
      channel_ref: channel_ref,
      external_shared: false,
      generation: 1,
      id: Ecto.UUID.generate(),
      joined_at: @now,
      left_at: if(status == :left, do: @now),
      private: Keyword.get(options, :private, false),
      status: status,
      workspace_ref: Keyword.get(options, :workspace_ref, "T123")
    })
  end

  defp state(situation) do
    %{
      "active_topics" => ["Ryker"],
      "decisions" => ["Keep continuity derived"],
      "evidence_refs" => [],
      "goal" => "Ship the requested behavior",
      "open_loops" => [],
      "participants" => ["operator"],
      "purpose" => "Product development",
      "situation" => situation,
      "topology" => ["Ryker uses PostgreSQL"],
      "unresolved_questions" => []
    }
  end
end
