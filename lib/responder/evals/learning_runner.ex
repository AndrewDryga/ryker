defmodule Responder.Evals.LearningRunner do
  @moduledoc """
  A sequential, disposable-database learning experiment, not an alternate runtime.

  Uses the production dispatcher, prompt, schema, budgets, application and cleanup
  custody. Source events stay unchanged; replay admission is explicitly silent
  shadow admission. Every batch settles before the next source becomes visible.
  Structural checks are not a substitute for reviewing the retained model results.
  """
  import Ecto.Query
  alias Responder.Admission.Decision
  alias Responder.CanonicalJSON
  alias Responder.Evals.LearningProbe
  alias Responder.Ingress.Inbox.{Entry, EntryChangeset}
  alias Responder.Learning.{Batch, Batches, Dispatcher, InputMembership, Runtime}
  alias Responder.Repo

  alias Responder.State.{
    ConversationKnowledge,
    Knowledge,
    KnowledgeRevision,
    LearningRun,
    LearningSources,
    Observations
  }

  alias Responder.Work.Session

  @terminal [:applied, :no_change, :deferred, :superseded]
  @runtime_keys ~w(admission learning work retention delivery publication slack github webhooks
    schedules event_waits state_tools coop_worker_gateway)a

  defmodule ScratchAPI do
    @moduledoc false
    # Reject a crossed policy repository before any retained source is submitted.
    def get_session(client, id), do: client.api.get_session(client.client, id) |> checked(client)

    def create_session(client, key, policy, ref, source),
      do: client.api.create_session(client.client, key, policy, ref, source) |> checked(client)

    defp checked({:ok, %{"session" => session} = response}, client) do
      with {:ok, _} <- checked({:ok, session}, client), do: {:ok, response}
    end

    defp checked({:ok, %{"base_commit" => head} = session}, %{scratch_head: head}),
      do: {:ok, session}

    defp checked({:ok, %{"operation" => _}} = response, _client), do: response
    defp checked({:ok, _}, _client), do: {:error, :learning_eval_scratch_mismatch}
    defp checked(error, _client), do: error

    for {name, arity} <- [
          capabilities: 0,
          operation_by_key: 1,
          get_turn: 2,
          fence_create_session: 4,
          submit_frozen_turn: 6,
          fence_frozen_turn: 6,
          validate_frozen_candidate: 6,
          cancel_turn: 4,
          checkpoint_workspace: 3,
          get_changes: 1,
          get_output_artifact: 3,
          close_session: 3,
          plan_discard: 5,
          discard_session: 3
        ] do
      arguments = Macro.generate_arguments(arity, __MODULE__)

      def unquote(name)(client, unquote_splicing(arguments)),
        do: apply(client.api, unquote(name), [client.client, unquote_splicing(arguments)])
    end
  end

  @doc "Loads exact harvested sources, never the fixture's recorded model answers."
  def recorded_sequence(scenario \\ "haproxy")

  def recorded_sequence("haproxy"),
    do: sequence("retained-haproxy-lifecycle.json", [:new_topic, :same_topic])

  def recorded_sequence("auth-memory-recurrence"),
    do:
      sequence("retained-auth-memory-recurrence.json", [
        :new_topic,
        :same_topic,
        :later_occurrence
      ])

  def recorded_sequence("draft-keep"),
    do: sequence("retained-draft-keep-thread.json", [:new_topic, :same_topic, :same_topic])

  def recorded_sequence("unoffered-draft-match") do
    [first | _] = recorded_sequence("draft-keep")
    path = "testdata/learning/recorded-draft-retention-create.json"

    [
      Map.merge(first, %{
        expectation: :matched_topic,
        concurrent_fixture: path,
        concurrent_fixture_sha256: path |> File.read!() |> sha()
      })
    ]
  end

  def recorded_sequence("fortnite-correction"),
    do:
      sequence("retained-fortnite-manual-correction.json", [
        :optional_topic,
        :topic_progress,
        :same_topic
      ])

  def recorded_sequence("chatter"), do: sequence("retained-great-thanks.json", [:no_change])

  def recorded_sequence("one-off-request"),
    do: sequence("retained-one-off-acceptance-request.json", [:no_change])

  defp sequence(file, expectations) do
    path = Path.join("testdata/learning", file)
    bytes = File.read!(path)
    %{"inputs" => inputs} = Jason.decode!(bytes)

    unless length(inputs) == length(expectations),
      do: raise(ArgumentError, "harvested sequence size changed")

    Enum.zip(inputs, expectations)
    |> Enum.map(fn {input, expectation} ->
      %{input: input, expectation: expectation, fixture: path, fixture_sha256: sha(bytes)}
    end)
  end

  @doc "Returns a public report even when a model or cleanup step fails; never deletes receipts."
  def run(sequence, options) when is_list(sequence) and is_map(options) do
    with :ok <- preflight(options), :ok <- valid_sequence(sequence) do
      {head, 0} = System.cmd("git", ["-C", options.scratch_repository, "rev-parse", "HEAD"])

      settings =
        Runtime.options!(%{
          api: ScratchAPI,
          client: %{api: options.api, client: options.client, scratch_head: String.trim(head)},
          policy: options.policy,
          policy_digest: options.policy_digest,
          worker_ref: "learning-eval",
          quiet_seconds: 0,
          batch_size: 1
        })

      steps = execute(sequence, settings, Map.get(options, :max_polls, 2200), [])
      learned = length(steps) == length(sequence) and Enum.all?(steps, & &1.passed)

      probe =
        if learned and options[:probe_question] do
          LearningProbe.run(options.probe_question, settings, hd(steps).input_id)
        end

      %{rows: [[database]]} = Repo.query!("SELECT current_database()")

      {:ok,
       Map.merge(retained_report(), %{
         database: database,
         policy: options.policy,
         policy_digest: options.policy_digest,
         scratch_repository: options.scratch_repository,
         scratch_head: String.trim(head),
         execution:
           if(options.api == Responder.Coop.Client, do: "live_model", else: "host_plumbing"),
         transformation:
           "Original input bodies, identities and event times retained; learning uses silent shadow admission, removed transport capabilities, dedicated evaluation policy and current ingestion receipts. Only the optional, separately labelled Work probe creates an episode with inert delivery.",
         semantic_review:
           "required; structural checks do not prove the model's factual interpretation",
         passed: learned and (is_nil(probe) or probe.passed),
         work_probe: probe,
         unrun_inputs:
           sequence
           |> Enum.drop(length(steps))
           |> Enum.map(&(&1.input["source_input_id"] || &1.input["id"])),
         steps: steps
       })}
    end
  end

  @doc false
  def retained_report,
    do: %{
      runs: documents(LearningRun),
      sessions: documents(Session),
      work_turns: documents(Responder.Work.Turn),
      topics: documents(ConversationKnowledge),
      revisions: documents(KnowledgeRevision)
    }

  def preflight(options) do
    %{rows: [[database]]} = Repo.query!("SELECT current_database()")

    cond do
      options[:database] != database ->
        {:error, :learning_eval_database_mismatch}

      not Regex.match?(~r/\Aresponder_(?:learning_eval|test)_[a-z0-9_]+\z/, database) ->
        {:error, :learning_eval_requires_disposable_database}

      Enum.any?(@runtime_keys, &Application.get_env(:responder, &1)) ->
        {:error, :learning_eval_background_runtime_configured}

      Map.get(options, :max_polls, 2200) not in 1..2200 ->
        {:error, :learning_eval_invalid_poll_budget}

      options[:probe_question] != nil and
          not (is_binary(options.probe_question) and byte_size(options.probe_question) in 1..4000) ->
        {:error, :learning_eval_invalid_probe_question}

      true ->
        with :ok <- empty_database(), do: empty_scratch(options[:scratch_repository])
    end
  end

  defp empty_database do
    %{rows: tables} =
      Repo.query!(
        "SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename != 'schema_migrations'"
      )

    if Enum.any?(tables, &table_populated?/1),
      do: {:error, :learning_eval_database_not_empty},
      else: :ok
  end

  defp table_populated?([table]) do
    quoted = String.replace(table, "\"", "\"\"")

    %{rows: [[exists]]} =
      Repo.query!("SELECT EXISTS(SELECT 1 FROM public.\"#{quoted}\" LIMIT 1)")

    exists
  end

  defp empty_scratch(root) when is_binary(root) do
    with true <- Path.type(root) == :absolute,
         {actual, 0} <-
           System.cmd("git", ["-C", root, "rev-parse", "--show-toplevel"], stderr_to_stdout: true),
         true <- String.trim(actual) == root,
         {"", 0} <-
           System.cmd("git", ["-C", root, "ls-tree", "-r", "--name-only", "HEAD"],
             stderr_to_stdout: true
           ),
         {"", 0} <-
           System.cmd("git", ["-C", root, "ls-files", "--cached", "--others"],
             stderr_to_stdout: true
           ),
         do: :ok,
         else: (_ -> {:error, :learning_eval_requires_empty_scratch_repository})
  end

  defp empty_scratch(_), do: {:error, :learning_eval_requires_empty_scratch_repository}

  defp valid_sequence(sequence) when length(sequence) in 1..8 do
    if Enum.all?(sequence, fn step ->
         is_map(step[:input]) and
           step[:expectation] in [
             :new_topic,
             :same_topic,
             :no_change,
             :optional_topic,
             :topic_progress,
             :later_occurrence,
             :matched_topic
           ] and
           is_binary(step[:fixture]) and is_binary(step[:fixture_sha256]) and harvested?(step) and
           concurrent_fixture_valid?(step)
       end), do: :ok, else: {:error, :learning_eval_invalid_sequence}
  end

  defp valid_sequence(_), do: {:error, :learning_eval_invalid_sequence}

  defp harvested?(step) do
    with {:ok, bytes} <- File.read(step.fixture),
         true <- sha(bytes) == step.fixture_sha256,
         {:ok, fixture} <- Jason.decode(bytes) do
      step.input in Map.get(fixture, "inputs", [fixture["input"]])
    else
      _ -> false
    end
  end

  defp concurrent_fixture_valid?(%{expectation: :matched_topic} = step) do
    with {:ok, bytes} <- File.read(step.concurrent_fixture),
         true <- sha(bytes) == step.concurrent_fixture_sha256,
         {:ok, %{"result" => %{"updates" => [update]}}} <- Jason.decode(bytes) do
      update["action"] == "create" and
        update["source_input_ids"] == [step.input["source_input_id"] || step.input["id"]]
    else
      _ -> false
    end
  end

  defp concurrent_fixture_valid?(_step), do: true

  defp execute([], _settings, _polls, steps), do: Enum.reverse(steps)

  defp execute([step | rest], settings, polls, steps) do
    before = heads()
    started = System.monotonic_time(:millisecond)
    entry = persist!(step.input, settings)
    controlled_race = prepare_concurrent_topic(step, entry, settings)
    result = drive(entry.id, settings, polls)
    after_heads = heads()
    provider_receipts = provider_receipts(entry.id, settings)
    cleanup = cleanup(settings, 20)
    check = check(step.expectation, before, after_heads)
    matching_check = matching_check(controlled_race, result)

    report = %{
      input_id: entry.id,
      fixture: step.fixture,
      fixture_sha256: step.fixture_sha256,
      original_input_sha256: CanonicalJSON.digest(step.input),
      content_sha256: CanonicalJSON.digest(entry.content),
      occurred_at: DateTime.to_iso8601(entry.occurred_at),
      received_at: DateTime.to_iso8601(entry.inserted_at),
      original_execution_mode: step.input["execution_mode"],
      replay_execution_mode: "shadow",
      expectation: step.expectation,
      before: before,
      after: after_heads,
      check: check,
      controlled_race: controlled_race,
      matching_check: matching_check,
      semantic_review: semantic_review(step.expectation),
      elapsed_ms: System.monotonic_time(:millisecond) - started,
      provider_receipts: provider_receipts,
      batch: result,
      cleanup: cleanup,
      passed:
        result["status"] in ["applied", "no_change"] and check and matching_check and
          cleanup == :discarded
    }

    if report.passed,
      do: execute(rest, settings, polls, [report | steps]),
      else: Enum.reverse([report | steps])
  end

  defp prepare_concurrent_topic(%{expectation: :matched_topic} = step, entry, settings) do
    {:ok, claim} = Batches.claim(settings.worker_ref, settings)
    {:ok, run} = Batches.prepare(claim)
    [] = run.knowledge
    {:ok, _} = Batches.begin_execution(claim, run.id)

    %{"result" => %{"updates" => [update]}, "run_id" => original_run_id} =
      step.concurrent_fixture |> File.read!() |> Jason.decode!()

    {:ok, topic} =
      Repo.transaction(fn ->
        :ok =
          Knowledge.record_sources_in_transaction(
            [entry],
            Map.drop(update, ~w(action source_input_ids)),
            [],
            %{
              result_ref: "learning-eval-recorded-writer:#{original_run_id}",
              source_dependencies: LearningSources.for_entry(entry),
              omissions: []
            }
          )

        Repo.one!(from(k in ConversationKnowledge, where: k.topic_key == ^update["topic_key"]))
      end)

    {:ok, _} = Batches.yield(claim, 0)

    %{
      provenance:
        "structural concurrent writer applies an exact captured creation after the real first request was frozen; no model candidate is injected into the evaluated provider calls",
      fixture: step.concurrent_fixture,
      fixture_sha256: step.concurrent_fixture_sha256,
      recorded_run_id: original_run_id,
      frozen_run_id: run.id,
      frozen_prompt_sha256: sha(run.prompt),
      source_ref: "knowledge:" <> topic.id,
      version: topic.version
    }
  end

  defp prepare_concurrent_topic(_step, _entry, _settings), do: nil

  defp matching_check(nil, _batch), do: true

  defp matching_check(race, batch) do
    first = Repo.get!(LearningRun, race.frozen_run_id)

    later =
      Repo.all(
        from(r in LearningRun,
          where:
            r.batch_id == ^first.batch_id and
              r.generation > ^first.generation,
          order_by: r.generation
        )
      )

    rejected_unoffered?(first, race) and batch["start_count"] in 2..3 and
      batch["start_limit"] == 3 and Enum.any?(later, &completed_offered_retry?(&1, race))
  end

  defp rejected_unoffered?(run, race),
    do:
      run.knowledge == [] and run.error_code == "learning_match_required" and
        race.source_ref in run.match_refs and is_binary(run.result)

  defp completed_offered_retry?(run, race),
    do:
      run.status == :applied and is_binary(run.result) and
        Enum.any?(run.knowledge, &offered_match?(&1, race))

  defp offered_match?(offered, race),
    do:
      offered["source_ref"] == race.source_ref and offered["version"] == race.version and
        offered["can_update"] == true

  defp persist!(raw, settings) do
    # Import source fields only. Recorded routing, work authority and model results
    # are intentionally not accepted as authority by this silent learning replay.
    fields = ~w(dedupe_key event_ref event_fingerprint source_kind source_ref native_input_id
      source_item_ref actor_ref revision content destination_transport destination_conversation_ref
      destination_thread_ref repository_ref)a
    attrs = Map.new(fields, &{&1, raw[Atom.to_string(&1)]})

    {:ok, decision} =
      Decision.parse(%{
        "action" => "ignore",
        "episode_ref" => nil,
        "reaction" => nil,
        "relation" => "unrelated",
        "repository_source" => nil,
        "reason" => "Silent shadow learning evaluation.",
        "work_class" => nil
      })

    {:ok, entry} =
      Repo.transaction(fn ->
        entry =
          struct!(
            Entry,
            Map.merge(attrs, %{
              id: raw["source_input_id"] || raw["id"],
              status: :pending,
              actor_kind: enum!(raw["actor_kind"], [:user, :app, :bot, :system]),
              event_kind: enum!(raw["event_kind"], [:message, :edit, :delete, :event]),
              occurred_at: source_time!(raw["occurred_at"]),
              occurred_at_source: :source,
              execution_mode: :shadow,
              source_capabilities: %{},
              work_policy: settings.policy,
              work_policy_digest: settings.policy_digest
            })
          )

        entry =
          entry
          |> EntryChangeset.decide(decision, "learning-eval:#{entry.id}", nil)
          |> Repo.insert!()

        :ok = Observations.record_excerpt_in_transaction(entry)
        entry
      end)

    entry
  end

  defp enum!(value, allowed),
    do:
      Enum.find(allowed, &(Atom.to_string(&1) == value)) ||
        raise(ArgumentError, "invalid recorded enum")

  defp source_time!(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, 0} -> at
      _ -> value |> NaiveDateTime.from_iso8601!() |> DateTime.from_naive!("Etc/UTC")
    end
  end

  defp drive(_id, _settings, 0),
    do: %{"status" => "unfinished", "error_code" => "evaluation_poll_budget_exhausted"}

  defp drive(id, settings, left) do
    result = Dispatcher.run_once(settings)

    batch =
      Repo.one(
        from(b in Batch,
          join: m in InputMembership,
          on: m.batch_id == b.id,
          where: m.input_id == ^id,
          select: b
        )
      )

    cond do
      batch && batch.status in @terminal ->
        document(batch)

      match?({:error, _}, result) ->
        %{"status" => "failed", "error_code" => inspect(result)}

      true ->
        Process.sleep(1000)
        drive(id, settings, left - 1)
    end
  end

  defp cleanup(_settings, 0), do: :unfinished

  defp cleanup(settings, left) do
    sessions = Repo.all(Session)

    if Enum.all?(sessions, &(&1.cleanup_status == :discarded)) do
      :discarded
    else
      case Responder.Retention.Dispatcher.run_once(
             api: ScratchAPI,
             client: settings.client,
             worker_ref: "learning-eval-cleanup",
             closed_session_grace_seconds: 0
           ) do
        {:ok, {:executed, _}} -> cleanup(settings, left - 1)
        _ -> :unfinished
      end
    end
  end

  defp provider_receipts(input_id, settings) do
    Repo.all(
      from(r in LearningRun,
        join: m in InputMembership,
        on: m.batch_id == r.batch_id,
        join: s in Session,
        on: s.learning_run_id == r.id,
        where: m.input_id == ^input_id,
        order_by: r.generation,
        select: {r.id, s.coop_session_id, r.coop_turn_id}
      )
    )
    |> Enum.map(&provider_receipt(&1, settings))
  end

  defp provider_receipt({run_id, session_id, turn_id}, settings) do
    receipt =
      if session_id && turn_id,
        do: inspect_turn(settings.api.get_turn(settings.client, session_id, turn_id)),
        else: %{"inspection_error" => "no_bound_remote_turn"}

    Map.put(receipt, "run_id", run_id)
  end

  defp inspect_turn({:ok, turn}),
    do:
      Map.take(
        turn,
        ~w(id session_id state target usage queued_at started_at finished_at error_code error_detail validation_attempt)
      )

  defp inspect_turn(error) do
    %{"inspection_error" => inspect(error, printable_limit: 2000)}
  end

  defp heads,
    do:
      Repo.all(
        from(k in ConversationKnowledge, order_by: k.id, select: %{id: k.id, version: k.version})
      )

  defp check(:new_topic, before, after_heads), do: length(after_heads) == length(before) + 1
  defp check(:no_change, before, after_heads), do: before == after_heads

  defp check(:optional_topic, before, after_heads),
    do: check(:no_change, before, after_heads) or check(:new_topic, before, after_heads)

  defp check(:topic_progress, before, after_heads),
    do: check(:new_topic, before, after_heads) or check(:same_topic, before, after_heads)

  defp check(:later_occurrence, before, after_heads),
    do: check(:topic_progress, before, after_heads)

  defp check(:matched_topic, _before, after_heads), do: after_heads != []

  defp check(:same_topic, before, after_heads),
    do:
      before != [] and
        Enum.map(before, & &1.id) == Enum.map(after_heads, & &1.id) and
        Enum.zip(before, after_heads)
        |> Enum.any?(fn {old, current} -> current.version == old.version + 1 end)

  defp semantic_review(:later_occurrence),
    do:
      "required; a maintained service topic or distinct occurrence topic is valid, but the earlier resolution must not establish recovery of the later firing occurrence; review the exact source chronology and retained answer"

  defp semantic_review(:matched_topic),
    do:
      "required; after the proven match correction a fresh judgment may update the offered topic or make no redundant change; a distinct creation needs independent semantic justification"

  defp semantic_review(_expectation),
    do: "required; structural checks do not prove the model's factual interpretation"

  defp documents(schema),
    do: Repo.all(from(item in schema, order_by: [asc: item.inserted_at])) |> Enum.map(&document/1)

  defp document(record),
    do:
      Map.take(record, record.__struct__.__schema__(:fields))
      |> Map.new(fn {key, value} -> {Atom.to_string(key), printable(value)} end)

  defp printable(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp printable(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp printable(value), do: value
  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
