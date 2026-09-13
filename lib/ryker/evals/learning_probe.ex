defmodule Ryker.Evals.LearningProbe do
  @moduledoc """
  An authored, held-out question through ordinary Work after a learning replay.

  Called only by LearningRunner after its disposable-database qualification and
  successful batches. This does not qualify admission decisions, explicit memory
  search, cross-channel recall, or public Slack delivery. No learning dispatcher
  runs after the question is admitted.
  """
  import Ecto.Query
  alias Ryker.{Admission, CanonicalJSON, Repo}
  alias Ryker.Admission.Decision
  alias Ryker.Delivery.Adapters
  alias Ryker.Evals.SlackDeliveryPublisher
  alias Ryker.Ingress.{Inbox, Input}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.State.{KnowledgeExposure, LearningRun}
  alias Ryker.Work.{Session, Turn}

  @doc false
  def run(question, settings, source_id) do
    source = Repo.get!(Entry, source_id)
    before_runs = Repo.aggregate(LearningRun, :count)
    {:ok, publisher} = Agent.start_link(fn -> [] end)

    try do
      {:ok, episode} = admit(source, question, settings)
      outcome = work(settings, 120)
      turn = Repo.one!(from(t in Turn, where: t.episode_id == ^episode.id))
      delivery = deliver(publisher)
      cleanup = cleanup(settings, 20)
      turn = Repo.get!(Turn, turn.id)
      session = Repo.get!(Session, turn.session_id)
      exposures = Repo.all(from(e in KnowledgeExposure, where: e.session_id == ^session.id))

      %{
        provenance: "authored held-out question; not a recorded source or expected model answer",
        scope:
          "same conversation, new live-mode episode, forced host routing; only an inert publisher is configured",
        proof: "ordinary Work automatic recall and validation; inert delivery only",
        not_qualified: [
          "explicit search_memory invocation",
          "cross-channel recall",
          "answer accuracy"
        ],
        question: question,
        question_sha256: CanonicalJSON.digest(question),
        episode_id: episode.id,
        outcome: inspect(outcome, printable_limit: 4000),
        delivery: inspect(delivery),
        cleanup: cleanup,
        turn: document(turn),
        session: document(session),
        knowledge_exposures: Enum.map(exposures, &document/1),
        semantic_review: "required; inspect the answer against the original source chronology",
        passed:
          turn.status == :settled and turn.delivered_at != nil and exposures != [] and
            cleanup == :discarded and Repo.aggregate(LearningRun, :count) == before_runs
      }
    after
      Agent.stop(publisher)
    end
  end

  defp admit(source, question, settings) do
    id = "learning-probe:" <> Ecto.UUID.generate()
    now = DateTime.utc_now()

    with {:ok, input} <-
           Input.new(%{
             actor: %{kind: :user, ref: "learning-evaluation-author"},
             content: %{"text" => question},
             destination: %{
               transport: source.destination_transport,
               conversation_ref: source.destination_conversation_ref,
               thread_ref: source.destination_thread_ref
             },
             event_kind: :message,
             event_ref: id,
             native_input_id: id,
             occurred_at: now,
             occurred_at_source: :ingress,
             revision: 1,
             source: %{kind: source.source_kind, ref: source.source_ref},
             source_capabilities: %{},
             source_item_ref: nil
           }),
         {:ok, %{entry: entry}} <-
           Inbox.record(input,
             execution_mode: :live,
             work_profile: %{
               policy: settings.policy,
               policy_digest: settings.policy_digest,
               repository_ref: source.repository_ref
             }
           ),
         %{rows: [[now]]} <- Repo.query!("SELECT clock_timestamp()"),
         {:ok, %{entry: %{id: claimed_id}, lease_ref: lease}} <-
           Inbox.claim_next("learning-probe-admission", now, 300),
         true <- claimed_id == entry.id,
         {:ok, context} <-
           Admission.context(Inbox.ref(entry),
             lease_ref: lease,
             now: now,
             continuation_window: 30 * 60,
             history_window: 30 * 24 * 60 * 60
           ),
         {:ok, result} <-
           Admission.commit(
             context,
             %Decision{
               action: :start_episode,
               episode_ref: nil,
               reaction: nil,
               relation: :unrelated,
               reason: "Authored held-out recall evaluation; routing is not under test.",
               repository_source: nil,
               work_class: :standard
             },
             id,
             lease_ref: lease,
             work_policy: %{
               name: settings.policy,
               digest: settings.policy_digest,
               repository_ref: source.repository_ref
             }
           ) do
      {:ok, result.episode}
    else
      error -> {:error, {:learning_probe_admission, inspect(error)}}
    end
  end

  # Normal Work keeps its own poll, lease and retry budgets. Do not move durable
  # retry clocks or reinterpret a pending remote operation as another model run.
  defp work(_settings, 0), do: {:error, :probe_poll_budget_exhausted}

  defp work(settings, left) do
    case Ryker.Work.Dispatcher.run_once(
           worker_ref: "learning-probe-work",
           executor_options: [
             api: settings.api,
             client: settings.client,
             require_project_isolation: true,
             require_repository_read_only: true,
             platform_tools: []
           ]
         ) do
      {:ok, {:executed, _}} = result ->
        result

      {:ok, {:blocked, _}} = result ->
        result

      {:error, _} = result ->
        result

      {:ok, {:deferred, {:work_poll_window_elapsed, _}}} ->
        Process.sleep(1000)
        work(settings, left - 1)

      {:ok, {:deferred, _}} = result ->
        result

      _ ->
        Process.sleep(1000)
        work(settings, left - 1)
    end
  end

  defp deliver(publisher) do
    {:ok, adapters} =
      Adapters.new(%{
        "slack" => %{
          binding: publisher,
          message_publisher: SlackDeliveryPublisher,
          reaction_publisher: SlackDeliveryPublisher
        }
      })

    Ryker.Delivery.Dispatcher.run_once(
      worker_ref: "learning-probe-delivery",
      kind: :message,
      adapters: adapters
    )
  end

  defp cleanup(_settings, 0), do: :unfinished

  defp cleanup(settings, left) do
    if Repo.exists?(from(s in Session, where: s.cleanup_status != :discarded)) do
      case Ryker.Retention.Dispatcher.run_once(
             api: settings.api,
             client: settings.client,
             worker_ref: "learning-probe-cleanup",
             closed_session_grace_seconds: 0
           ) do
        {:ok, {:executed, _}} -> cleanup(settings, left - 1)
        _ -> :unfinished
      end
    else
      :discarded
    end
  end

  defp document(record) do
    Map.take(record, record.__struct__.__schema__(:fields))
    |> Map.new(fn
      {key, %DateTime{} = value} ->
        {Atom.to_string(key), DateTime.to_iso8601(value)}

      {key, value} when is_atom(value) and value not in [nil, true, false] ->
        {Atom.to_string(key), Atom.to_string(value)}

      {key, value} ->
        {Atom.to_string(key), value}
    end)
  end
end
