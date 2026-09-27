defmodule Ryker.WeeklyReport.SchedulerTest do
  @moduledoc """
  The weekly report posts unattended into a channel people read, so the rules
  about when it posts are the ones a person notices first when they break: a
  report twice in one week, a report the moment someone ticks the box, a
  report an hour off, or a burst of stale reports after an outage.
  """
  use Ryker.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Ryker.ControlPlane.{FailureExplanation, FailureProjection}
  alias Ryker.Delivery.{Adapters, Dispatcher}
  alias Ryker.Operator.Delivery, as: DeliveryOperator
  alias Ryker.Settings
  alias Ryker.Settings.Edit
  alias Ryker.Slack.Renderer
  alias Ryker.TestSupport.TimeZones
  alias Ryker.WeeklyReport
  alias Ryker.WeeklyReport.{Report, Worker}

  @actor "control-plane:local"
  @workspace "T0REPORTS"
  @channel "C0REPORTS"

  defmodule Publisher do
    @behaviour Ryker.Delivery.Platform
    @behaviour Ryker.Delivery.MessagePublisher
    @behaviour Ryker.Delivery.ReactionPublisher

    alias Ryker.Work.DeliveryReceipt

    @impl true
    def transport, do: "slack"

    @impl true
    def publish_message(request, agent) do
      Agent.get_and_update(agent, fn state ->
        state = %{state | calls: state.calls ++ [request]}

        case state.responses do
          [{:error, _reason} = refusal | rest] ->
            {refusal, %{state | responses: rest}}

          _answer ->
            {DeliveryReceipt.new(
               request.ref,
               request.transport,
               request.conversation_ref,
               request.thread_ref,
               "1790900000.000100"
             ), state}
        end
      end)
    end

    @impl true
    def publish_reaction(_request, _agent), do: {:error, :not_a_reaction}
  end

  # -- When it is sent ---------------------------------------------------------------

  test "the report is queued once per calendar week at the chosen local time, and a restart inside the week posts nothing more" do
    connect!(%{weekday: 1, local_time: ~T[09:00:00]})
    zone!("Test/Plus2")
    last_saved!(~U[2026-09-30 10:00:00.000000Z])

    # Monday 08:59:59 two hours ahead of UTC: not yet.
    assert {:ok, {:waiting, ~U[2026-10-05 07:00:00.000000Z]}} =
             run_once(~U[2026-10-05 06:59:59Z])

    assert reports() == []

    # Monday 09:00:30 local: this week's report, covering the week before.
    assert {:ok, {:queued, report, ~U[2026-10-12 07:00:00.000000Z]}} =
             run_once(~U[2026-10-05 07:00:30Z])

    assert report.week == ~D[2026-10-05]
    assert report.due_at == ~U[2026-10-05 07:00:00.000000Z]
    assert report.period_start == ~U[2026-09-28 07:00:00.000000Z]
    assert report.timezone == "Test/Plus2"
    assert report.conversation_ref == "slack:#{@workspace}:#{@channel}"
    assert report.delivery_ref == "weekly-report:2026-10-05"
    assert report.status == :pending

    assert report.document["message"] =~
             "How my week went, from Mon 28 Sep 09:00 to Mon 5 Oct 09:00 TP2."

    # A restart later that day, and later that week, finds the week sent.
    for now <- [~U[2026-10-05 07:00:31Z], ~U[2026-10-05 12:00:00Z], ~U[2026-10-09 18:00:00Z]] do
      assert {:ok, {:waiting, ~U[2026-10-12 07:00:00.000000Z]}} = run_once(now)
    end

    assert Enum.map(reports(), & &1.week) == [~D[2026-10-05]]

    # Next Monday is next week's report.
    assert {:ok, {:queued, %{week: ~D[2026-10-12]}, _next}} = run_once(~U[2026-10-12 07:00:05Z])
    assert Enum.map(reports(), & &1.week) == [~D[2026-10-05], ~D[2026-10-12]]
  end

  # The Go report recorded the boundary on its first sweep for the same
  # reason: a deployment that ticks the box and gets a report that second has
  # learned the bot posts whenever it likes.
  test "turning the report on never posts at once: the first report is the next send time" do
    connect!(%{weekday: 1, local_time: ~T[09:00:00]})
    last_saved!(~U[2026-10-05 09:30:00.000000Z])

    # Monday's send time passed half an hour before the report was turned on.
    assert {:ok, {:waiting, ~U[2026-10-12 09:00:00.000000Z]}} =
             run_once(~U[2026-10-05 10:00:00Z])

    assert reports() == []

    assert {:ok, {:queued, %{week: ~D[2026-10-12]}, _next}} = run_once(~U[2026-10-12 09:00:01Z])
  end

  test "a four-week outage posts one report, for the latest send time" do
    connect!(%{weekday: 1, local_time: ~T[09:00:00]})
    last_saved!(~U[2026-09-01 00:00:00.000000Z])

    assert {:ok, {:queued, report, _next}} = run_once(~U[2026-11-04 12:00:00Z])
    assert report.week == ~D[2026-11-02]
    assert report.period_start == ~U[2026-10-26 09:00:00.000000Z]
    assert {:ok, {:waiting, _next}} = run_once(~U[2026-11-04 12:00:01Z])
    assert Enum.map(reports(), & &1.week) == [~D[2026-11-02]]
  end

  test "a report that is off, names no channel, or has no Slack to post to does nothing and logs nothing" do
    settings = connect!(%{weekday: 1, local_time: ~T[09:00:00]})
    last_saved!(~U[2026-09-01 00:00:00.000000Z])

    assert {:ok, off} =
             Settings.save_report(
               %{weekly_self_report_enabled: false, channel_ref: nil},
               settings.installation.revision,
               @actor
             )

    log =
      capture_log(fn ->
        assert {:ok, :off} = run_once(~U[2026-11-04 12:00:00Z])
      end)

    assert log == ""
    assert reports() == []

    # On, but Slack was disconnected since: nothing can post it.
    assert {:ok, on} =
             Settings.save_report(
               %{weekly_self_report_enabled: true, channel_ref: @channel},
               off.installation.revision,
               @actor
             )

    assert {:ok, _disconnected} =
             Settings.save_slack(%{enabled: false}, on.installation.revision, @actor)

    last_saved!(~U[2026-09-01 00:00:00.000000Z])
    assert capture_log(fn -> assert {:ok, :off} = run_once(~U[2026-11-04 12:00:00Z]) end) == ""
    assert reports() == []
  end

  # -- How it is posted --------------------------------------------------------------

  test "the week's report posts through the delivery lane once, and a post Slack refuses waits on Failures with Post it again" do
    connect!(%{weekday: 1, local_time: ~T[09:00:00]})
    last_saved!(~U[2026-09-01 00:00:00.000000Z])
    assert {:ok, {:queued, report, _next}} = run_once(~U[2026-10-05 09:00:01Z])

    agent = start_supervised!({Agent, fn -> %{calls: [], responses: []} end})

    assert {:ok, {:delivered, :report, "weekly-report:2026-10-05"}} = deliver(agent)
    assert [request] = Agent.get(agent, & &1.calls)
    assert request.kind == :message
    assert request.ref == "weekly-report:2026-10-05"
    assert request.conversation_ref == "slack:#{@workspace}:#{@channel}"
    assert request.thread_ref == nil
    assert request.document == %{"message" => report.document["message"]}

    # One Slack markdown block, as every reply is posted, well inside what
    # a markdown block holds; the channel sees the words the preview shows.
    assert {:ok, %{"blocks" => [%{"type" => "markdown", "text" => words}]}} =
             Renderer.render(request.document)

    assert words =~ "**Weekly report**"
    assert String.length(words) < 12_000

    delivered = Repo.get!(Report, report.id)
    assert delivered.status == :delivered
    assert delivered.external_receipt["message_ref"] == "1790900000.000100"

    # Nothing is posted twice.
    assert {:ok, :idle} = deliver(agent)
    assert length(Agent.get(agent, & &1.calls)) == 1

    # Next week Slack refuses: Ryker is not in the channel any more.
    assert {:ok, {:queued, refused, _next}} = run_once(~U[2026-10-12 09:00:01Z])

    Agent.update(agent, fn state ->
      %{state | responses: [{:error, {:slack_api_error, "not_in_channel"}}]}
    end)

    assert {:ok,
            {:blocked, :report, "weekly-report:2026-10-12", {:slack_api_error, "not_in_channel"}}} =
             deliver(agent)

    assert Repo.get!(Report, refused.id).status == :blocked

    assert {:ok, failures} = FailureProjection.list(%{})
    assert [row] = Enum.filter(failures, &(&1.ref == "weekly-report:2026-10-12"))
    assert row.kind == "delivery"
    assert row.destination == "slack:#{@workspace}:#{@channel}"

    explanation = FailureExplanation.explain(row)
    assert explanation.title == "Posting the weekly report stopped"
    assert explanation.impact == :people
    assert Enum.any?(explanation.options, &(&1[:label] == "Post the report again"))

    # Post it again sends the same words to the same channel.
    assert {:ok, %{status: :pending, retry_generation: 1}} =
             DeliveryOperator.rearm("weekly-report:2026-10-12")

    assert {:ok, {:delivered, :report, "weekly-report:2026-10-12"}} = deliver(agent)
    assert List.last(Agent.get(agent, & &1.calls)).document == refused.document
  end

  # -- The worker --------------------------------------------------------------------

  test "the worker posts a report Ryker was down for when it starts, and a settings save wakes it" do
    connect!(%{weekday: Date.day_of_week(Date.utc_today()), local_time: ~T[00:00:00]})

    # Saved just now: this week's send time came before it, so nothing is due.
    worker = start_supervised!({Worker, %{longest_sleep_ms: 3_600_000}})
    :sys.get_state(worker)
    refute_eventually(fn -> reports() != [] end)

    # Moved back without a word to the worker: it sleeps on.
    last_saved!(DateTime.add(DateTime.utc_now(), -30, :day))
    refute_eventually(fn -> reports() != [] end)

    # Any settings save is announced, and the worker wakes and posts.
    %{installation: %{revision: revision}} = Settings.fetch!()
    assert {:ok, _saved} = Settings.save_learning(%{enabled: false}, revision, @actor)
    assert_eventually(fn -> length(reports()) == 1 end)

    stop_supervised!(Worker)

    # A restart finds the week sent and posts nothing more.
    worker = start_supervised!({Worker, %{longest_sleep_ms: 3_600_000}})
    :sys.get_state(worker)
    refute_eventually(fn -> length(reports()) > 1 end)
  end

  # -- Helpers -------------------------------------------------------------------------

  defp run_once(now), do: WeeklyReport.run_once(now: now, time_zone_database: TimeZones)

  defp deliver(agent) do
    {:ok, adapters} =
      Adapters.new(%{
        "slack" => %{binding: agent, message_publisher: Publisher, reaction_publisher: Publisher}
      })

    Dispatcher.run_once(
      adapters: adapters,
      kind: :report,
      max_attempts: 3,
      worker_ref: "delivery:weekly-report-test"
    )
  end

  defp reports, do: Repo.all(from(report in Report, order_by: report.week))

  defp connect!(schedule) do
    {:ok, settings} = Settings.initialize(@actor)

    {:ok, settings} =
      Settings.put_repository(%{ref: "ryker"}, settings.installation.revision, @actor)

    {:ok, settings} =
      Settings.save_slack(
        %{
          enabled: true,
          workspace_ref: @workspace,
          bot_ref: "A0123456789",
          bot_user_ref: "U0123456789",
          operators: ["U1111111111"]
        },
        settings.installation.revision,
        @actor
      )

    {:ok, settings} =
      Settings.save_report(
        Map.merge(%{weekly_self_report_enabled: true, channel_ref: @channel}, schedule),
        settings.installation.revision,
        @actor
      )

    settings
  end

  # The release refuses any zone but UTC when the report is saved; these
  # tests hand the schedule a database that knows others.
  defp zone!(zone), do: Repo.update_all(Settings.Report, set: [timezone: zone])

  defp last_saved!(at),
    do: Repo.update_all(from(edit in Edit, where: edit.domain == :report), set: [inserted_at: at])

  defp assert_eventually(check, attempts \\ 40) do
    cond do
      check.() ->
        :ok

      attempts == 0 ->
        flunk("the worker never did it")

      true ->
        Process.sleep(50)
        assert_eventually(check, attempts - 1)
    end
  end

  # What must not happen has had time to.
  defp refute_eventually(check) do
    Process.sleep(300)
    refute check.()
  end
end
