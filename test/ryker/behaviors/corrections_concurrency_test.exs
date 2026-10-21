defmodule Ryker.Behaviors.CorrectionsConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Behaviors
  alias Ryker.Episodes
  alias Ryker.Fixtures.Corrections
  alias Ryker.Ingress
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Slack
  alias Ryker.Work

  test "saving a correction cannot deadlock the activity that owns its episode" do
    # The first two-episode model evaluation cancelled valid Work because
    # correction saving held Session while activity held Episode. Both host
    # transactions must finish, without spending a model turn on a DB retry.
    Sandbox.unboxed_run(Repo, fn ->
      correction = Corrections.correction!()
      parent = self()

      activity =
        unboxed_task(fn ->
          database_result(fn ->
            Repo.transaction(fn ->
              Repo.query!("SET LOCAL deadlock_timeout = '50ms'")

              correction.claim.episode.id
              |> Episodes.Episode.Query.by_id()
              |> Episodes.Episode.Query.lock_for_key_share()
              |> Repo.fetch!()

              send(parent, {:activity_held, backend_pid()})

              receive do
                :ingest -> Work.Activity.ingest(correction.claim.session.id, [])
              end
            end)
          end)
        end)

      assert_receive {:activity_held, activity_backend}, 5_000

      writer =
        unboxed_task(fn ->
          Repo.query!("SET deadlock_timeout = '50ms'")
          send(parent, {:writer_started, backend_pid()})

          database_result(fn ->
            Behaviors.Corrections.remember(correction.binding, correction.arguments, fn _ ->
              true
            end)
          end)
        end)

      try do
        assert_receive {:writer_started, writer_backend}, 5_000
        await_blocked_by(writer_backend, activity_backend)
        send(activity.pid, :ingest)

        assert {:ok, {:ok, %{inserted: 0}}} = Task.await(activity, 5_000)
        assert {:ok, %{"status" => "remembered"}} = Task.await(writer, 5_000)
      after
        send(activity.pid, :ingest)
        stop_tasks([activity, writer])
        cleanup!(correction)
      end
    end)
  end

  test "saving a correction cannot hold its episode while waiting for memory review" do
    # Confirmation and retention own review maintenance before locking an
    # episode. Moving only Episode ahead of Session traded the activity
    # deadlock for this one, so the source/review locks must come first too.
    Sandbox.unboxed_run(Repo, fn ->
      correction = Corrections.correction!()
      parent = self()

      review =
        unboxed_task(fn ->
          database_result(fn ->
            Repo.transaction(fn ->
              Repo.query!("SET LOCAL deadlock_timeout = '50ms'")
              Ryker.Memories.Reviews.lock_review_maintenance!()
              send(parent, {:review_held, backend_pid()})

              receive do
                :lock_episode ->
                  correction.claim.episode.id
                  |> Episodes.Episode.Query.by_id()
                  |> Episodes.Episode.Query.lock_for_update()
                  |> Repo.exists?()
              end
            end)
          end)
        end)

      assert_receive {:review_held, review_backend}, 5_000

      writer =
        unboxed_task(fn ->
          Repo.query!("SET deadlock_timeout = '50ms'")
          send(parent, {:writer_started, backend_pid()})

          database_result(fn ->
            Behaviors.Corrections.remember(correction.binding, correction.arguments, fn _ ->
              true
            end)
          end)
        end)

      try do
        assert_receive {:writer_started, writer_backend}, 5_000
        await_blocked_by(writer_backend, review_backend)
        send(review.pid, :lock_episode)

        assert Task.await(review, 5_000) == {:ok, true}
        assert {:ok, %{"status" => "remembered"}} = Task.await(writer, 5_000)
      after
        send(review.pid, :lock_episode)
        stop_tasks([review, writer])
        cleanup!(correction)
      end
    end)
  end

  defp database_result(fun) do
    fun.()
  rescue
    error in Postgrex.Error -> {:database_error, error.postgres.code}
  end

  defp cleanup!(correction) do
    episode_id = correction.claim.episode.id
    conversation = correction.entry.destination_conversation_ref
    workspace = correction.entry.source_ref

    Repo.delete_all(
      from(b in Behaviors.Behavior, where: b.source_conversation_ref == ^conversation)
    )

    Repo.delete_all(from(r in Records.Record, where: r.episode_id == ^episode_id))

    delete_entries!(
      from(e in Ingress.Inbox.Entry, where: e.destination_conversation_ref == ^conversation)
    )

    Repo.delete_all(from(t in Work.Turn, where: t.episode_id == ^episode_id))
    Repo.delete_all(from(s in Work.Session, where: s.episode_id == ^episode_id))
    Repo.delete_all(from(e in Episodes.Event, where: e.episode_id == ^episode_id))
    Repo.delete_all(from(e in Episodes.Episode, where: e.id == ^episode_id))
    Repo.delete_all(from(m in Slack.ChannelMembership, where: m.workspace_ref == ^workspace))
  end
end
