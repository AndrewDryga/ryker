defmodule Ryker.Feedback.RetentionTest do
  @moduledoc """
  Feedback on Ryker's answers is operational data (`Ryker.Retention.Policy`):
  it expires at the operational horizon, and with its request when that goes
  first. The migration that adds its table refuses to roll back while any
  feedback is kept.
  """
  # Retention takes one advisory lock for a whole pass, and the migrator runs
  # inside this test's sandbox transaction.
  use Ryker.DataCase, async: false

  import Ecto.Query

  alias Ryker.Feedback
  alias Ryker.Feedback.Signal
  alias Ryker.Ingress.Inbox
  alias Ryker.Retention.{Data, Policy}
  alias Ryker.Slack.Input, as: SlackInput

  @now ~U[2026-09-27 12:00:00.000000Z]
  @old ~U[2020-01-01 00:00:00.000000Z]

  @version 20_260_927_190_000
  @migration {Ryker.Repo.Migrations.AddAnswerFeedback, "20260927190000_add_answer_feedback.exs"}
  # A later migration that changes the table rolls back before it, as a
  # rollback of the release does.
  @message_ref_version 20_260_927_193_000
  @message_ref_migration {Ryker.Repo.Migrations.AddAnswerFeedbackMessageRef,
                          "20260927193000_add_answer_feedback_message_ref.exs"}
  @options [log: false, migration_lock: false]

  test "feedback expires at the operational horizon, and with its request" do
    assert {:ok, %{class: :operational}} = Policy.fetch("answer_feedback")

    input = input!("1790001000.000100")
    old = signal!(input, "slack-event:Ev-old")
    fresh = signal!(input, "slack-event:Ev-fresh")

    # It ages from when Ryker recorded it: a redelivered event about an old
    # answer is still recent news.
    Repo.update_all(from(signal in Signal, where: signal.id == ^old.id),
      set: [inserted_at: @old]
    )

    assert {:ok, result} = Data.prune(settings())
    assert result.feedback == 1
    refute Repo.get(Signal, old.id)
    assert Repo.get(Signal, fresh.id)

    # A request removed before its feedback expired takes its feedback with it.
    Repo.query!("DELETE FROM ingress_inbox_entries WHERE id = $1", [Ecto.UUID.dump!(input.id)])
    refute Repo.get(Signal, fresh.id)
  end

  test "the migration refuses to roll back while feedback is kept, and returns cleanly without it" do
    input = input!("1790001001.000100")
    signal = signal!(input, "slack-event:Ev-kept")

    assert_raise Postgrex.Error, ~r/feedback on Ryker's answers is kept/, fn ->
      Ecto.Migrator.down(Repo, @version, migration(@migration), @options)
    end

    assert Repo.get(Signal, signal.id)
    Repo.delete_all(Signal)

    assert :ok =
             Ecto.Migrator.down(
               Repo,
               @message_ref_version,
               migration(@message_ref_migration),
               @options
             )

    assert :ok = Ecto.Migrator.down(Repo, @version, migration(@migration), @options)
    refute table?("answer_feedback")
    assert :ok = Ecto.Migrator.up(Repo, @version, migration(@migration), @options)

    assert :ok =
             Ecto.Migrator.up(
               Repo,
               @message_ref_version,
               migration(@message_ref_migration),
               @options
             )

    assert table?("answer_feedback")
    assert {:ok, %{status: :recorded}} = Feedback.record(attributes(input, "slack-event:Ev-back"))
  end

  defp signal!(input, source_ref) do
    assert {:ok, %{signal: signal, status: :recorded}} =
             Feedback.record(attributes(input, source_ref))

    signal
  end

  defp attributes(input, source_ref) do
    %{
      kind: :reaction_added,
      value: "+1",
      actor_ref: "UALICE",
      source: "slack",
      source_ref: source_ref,
      occurred_at: @now,
      request: {:input, input.id}
    }
  end

  defp input!(ts) do
    {:ok, input} =
      SlackInput.new(%{
        actor: %{kind: :user, ref: "UALICE"},
        channel_ref: "CFEEDBACKRETENTION",
        content: %{"text" => "Is checkout up?"},
        event_kind: :message,
        event_ref: "Ev-#{ts}",
        message_ref: ts,
        occurred_at: @now,
        revision: 1,
        thread_ref: nil,
        workspace_ref: "TFEEDBACKRETENTION"
      })

    {:ok, %{entry: entry}} = Inbox.record(input)
    entry
  end

  defp table?(name) do
    %{rows: [[exists]]} =
      Repo.query!(
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = current_schema() AND table_name = $1)",
        [name]
      )

    exists
  end

  defp settings do
    %{
      audit_data_seconds: 600,
      closed_work_seconds: 600,
      conversation_memory_seconds: 600,
      episode_history_seconds: 600,
      operational_data_seconds: 60,
      routing_examples_enabled: false,
      routing_examples_seconds: 365 * 86_400,
      work_examples_enabled: false,
      work_examples_seconds: 365 * 86_400
    }
  end

  # `ecto.migrate` loads a migration only while it is pending, so a database
  # migrated by an earlier run leaves it for this test to load.
  defp migration({module, file_name}) do
    unless Code.ensure_loaded?(module) do
      :ryker
      |> Application.app_dir(Path.join("priv/repo/migrations", file_name))
      |> Code.compile_file()
    end

    module
  end
end
