defmodule Responder.State.LearningConcurrencyTest do
  use Responder.ConcurrencyCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Responder.Episodes.{Episode, Event}
  alias Responder.Fixtures.Learning, as: Fixtures
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Repo
  alias Responder.State.{ConversationObservation, Learning, LearningRun}
  alias Responder.Work.Session

  @policy %{policy: "recorded-read-only-policy", policy_digest: String.duplicate("a", 64)}

  # A retried batch and its returning model result used opposite lock order;
  # a backfill resume must not deadlock or apply the same batch twice.
  test "preparing a retry and accepting its result share batch then row lock order" do
    Sandbox.unboxed_run(Repo, fn ->
      entries = Fixtures.inputs!()
      ids = Enum.map(entries, & &1.id)
      assert {:ok, run} = Learning.prepare(ids, @policy)
      parent = self()
      <<lock::signed-64, _::binary>> = :crypto.hash(:sha256, "learning:" <> run.batch_key)

      retry =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT pg_advisory_xact_lock($1)", [lock])
            send(parent, {:locked, backend_pid()})
            receive do: (:prepare -> Learning.prepare(ids, @policy))
          end)
        end)

      assert_receive {:locked, retry_backend}, 5000

      accept =
        unboxed_task(fn ->
          send(parent, {:accepting, backend_pid()})

          Responder.Fixtures.Learning.accept(
            run.id,
            Jason.encode!(%{"updates" => [], "reason" => "No new information."}),
            %{}
          )
        end)

      try do
        assert_receive {:accepting, accept_backend}, 5000
        await_blocked_by(accept_backend, retry_backend)
        send(retry.pid, :prepare)
        assert {:ok, {:ok, %{id: id}}} = Task.await(retry, 5000)
        assert id == run.id
        assert {:ok, %{status: :applied}} = Task.await(accept, 5000)
        assert {:ok, %{status: :applied}} = Learning.prepare(ids, @policy)
      after
        stop_tasks([retry, accept])
        runs = from(r in LearningRun, where: r.batch_key == ^run.batch_key, select: r.id)
        Repo.delete_all(from(s in Session, where: s.learning_run_id in subquery(runs)))
        Repo.delete_all(from(r in LearningRun, where: r.batch_key == ^run.batch_key))
        Repo.delete_all(from(o in ConversationObservation, where: o.source_input_id in ^ids))
        Repo.delete_all(from(e in Entry, where: e.id in ^ids))
        Repo.delete_all(from(e in Event, where: e.episode_id in ^ids))
        Repo.delete_all(from(e in Episode, where: e.id in ^ids))
      end
    end)
  end
end
