defmodule Ryker.Slack.TaskCardWorkerTest do
  use Ryker.DataCase, async: false

  import Ecto.Query
  import Ryker.TestHelpers, only: [eventually: 2]

  alias Ryker.ControlPlane.{FailureExplanation, FailureProjection}
  alias Ryker.{Episodes, Repo}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Operator.Failures
  alias Ryker.Records
  alias Ryker.Slack.{TaskCard, TaskCards, TaskCardWorker}
  alias Ryker.Work.Custody

  @conversation "slack:T123:C456"

  defmodule API do
    def update_message(agent, _channel, _message_ref, _document, _ref) do
      Agent.get_and_update(agent, fn state ->
        {state.result, Map.update!(state, :updates, &(&1 + 1))}
      end)
    end
  end

  # A card whose message was deleted, or whose channel was archived, was
  # claimed again every hour for as long as its task existed, edited a message
  # Slack had already said was gone, and was listed nowhere: the only cap on
  # its attempts was the backoff ceiling.
  test "a task card whose message is gone stops retrying and is listed on Failures" do
    card = card!("gone")
    client = client!({:error, {:slack_api_error, "message_not_found"}})
    options = options(client)

    assert {:ok, {:blocked, ref}} = TaskCardWorker.run_once(options)
    assert ref == card.ref

    blocked = Repo.get!(TaskCard, card.id)
    assert blocked.status == :blocked
    assert blocked.attempt_count == 1
    assert blocked.last_error_code == "slack_api_error"
    assert blocked.lease_ref == nil
    assert blocked.next_attempt_at == nil

    # Nothing claims it again: not on the next cycle, not in an hour.
    assert {:ok, :idle} = TaskCardWorker.run_once(options)
    assert Agent.get(client, & &1.updates) == 1

    assert {:ok, failures} = FailureProjection.list(%{})
    assert %{} = row = Enum.find(failures, &(&1.ref == card.ref))
    assert row.kind == "slack_task_card"
    assert row.action == :rearm
    assert row.status == :blocked
    assert row.destination == "slack:T123:C456 / #{card.thread_ref}"
    assert row.provider_error == "message_not_found"
    assert row.episode_ref == card.episode.key

    explanation = FailureExplanation.explain(row)
    assert explanation.title == "Updating a task’s card stopped"
    assert explanation.outlook == :stuck
    assert FailureExplanation.kind_name("slack_task_card") == "Task card update"
  end

  # Slack answering "try later" for long enough is not a reason to edit the
  # same message forever either; after its attempts the card waits for a
  # person, who can rearm it from Failures, and a rearmed card is due at once.
  test "a task card Slack keeps refusing blocks after its attempts and a person can rearm it" do
    card = card!("busy")
    client = client!({:error, {:slack_api_error, "internal_error"}})
    options = options(client, max_attempts: 2)

    assert {:ok, {:deferred, _ref}} = TaskCardWorker.run_once(options)
    make_due!(card.id)
    assert {:ok, {:blocked, _ref}} = TaskCardWorker.run_once(options)
    assert Repo.get!(TaskCard, card.id).attempt_count == 2
    assert {:ok, %{status: :blocked}} = FailureProjection.fetch("slack_task_card", card.ref)

    assert {:ok, %{outcome: %{"status" => "active"}}} =
             Failures.retry("slack_task_card", card.ref,
               actor_ref: "control-plane:local",
               action_ref: "control-plane:retry:#{Ecto.UUID.generate()}"
             )

    rearmed = Repo.get!(TaskCard, card.id)
    assert rearmed.status == :active
    assert rearmed.attempt_count == 0
    assert rearmed.last_error_code == nil
    assert FailureProjection.fetch("slack_task_card", card.ref) == :not_found

    assert {:error, :task_card_not_blocked} = TaskCards.rearm(card.ref)

    Agent.update(client, &%{&1 | result: :ok})
    assert {:ok, {:updated, _ref}} = TaskCardWorker.run_once(options)
    assert Agent.get(client, & &1.updates) == 3
  end

  # A blocked card is listed on Failures and on its task's Timeline, and a
  # rearm takes it off. Until 2026-09-26 those pages heard of either from a
  # trigger's NOTIFY and a five-second poll; the context now announces the
  # card, and its task, once the change commits.
  test "a blocked and rearmed task card reaches Failures and its task's Timeline" do
    card = card!("announced")
    card_id = card.id
    episode_id = card.episode.id
    client = client!({:error, {:slack_api_error, "message_not_found"}})
    :ok = TaskCards.subscribe_task_cards()
    :ok = Episodes.subscribe_episode(episode_id)

    assert {:ok, {:blocked, _ref}} = TaskCardWorker.run_once(options(client))
    assert_received {:task_card_updated, ^card_id}
    assert_received {:episode_updated, ^episode_id}

    assert {:ok, _rearmed} = TaskCards.rearm(card.ref)
    assert_received {:task_card_updated, ^card_id}
  end

  # Every claim counted as an attempt, successful refreshes included, so a
  # card that had been refreshed a hundred times waited the full hour after
  # its first transient failure, and with a cap would have been blocked by
  # its own successes.
  test "a successful refresh gives the card a fresh attempt budget" do
    card = card!("fresh")
    client = client!(:ok)
    options = options(client)

    assert {:ok, {:updated, _ref}} = TaskCardWorker.run_once(options)
    assert Repo.get!(TaskCard, card.id).attempt_count == 0
  end

  # On 2026-09-27 an idle install committed about 125 transactions a second;
  # the task-card worker polled every second. It now sleeps until a task or a
  # card is announced, so a person rearming a card has to wake it.
  test "a card a person rearms is refreshed at once, not at the next timer" do
    card = card!("rearmed")
    client = client!({:error, {:slack_api_error, "message_not_found"}})
    assert {:ok, {:blocked, _ref}} = TaskCardWorker.run_once(options(client))
    Agent.update(client, &%{&1 | result: :ok})

    worker = start_supervised!({TaskCardWorker, sleeping_options(client)})
    # Its first poll found nothing, and its next timer is five minutes away.
    _state = :sys.get_state(worker)

    assert {:ok, _rearmed} = TaskCards.rearm(card.ref)
    assert eventually(fn -> Agent.get(client, & &1.updates) == 2 end, 500)
  end

  # Every active card is checked again every few seconds, and only the clock
  # says when: a worker sleeping its safety-net interval would leave a card
  # showing stale progress for up to ten seconds.
  test "a card whose next check falls due is refreshed then, not at the safety-net interval" do
    card = card!("due")
    client = client!(:ok)

    Repo.update_all(from(stored in TaskCard, where: stored.id == ^card.id),
      set: [card_checked_at: Repo.now!()]
    )

    start_supervised!({TaskCardWorker, sleeping_options(client)})

    refute eventually(fn -> Agent.get(client, & &1.updates) == 1 end, 500)
    assert eventually(fn -> Agent.get(client, & &1.updates) == 1 end, 1_500)
  end

  # A card is checked every two seconds for as long as its task exists, and
  # each check announced its claim and its result on the task's topics even
  # when the card had not changed. Once a dozen workers woke on those topics,
  # every such check woke all of them.
  test "a check that finds a card unchanged is not announced" do
    card = card!("unchanged")
    client = client!(:ok)
    episode_id = card.episode.id
    assert {:ok, {:updated, _ref}} = TaskCardWorker.run_once(options(client))

    make_due!(card.id)
    :ok = TaskCards.subscribe_task_cards()
    :ok = Episodes.subscribe_episode(episode_id)
    assert {:ok, {:updated, _ref}} = TaskCardWorker.run_once(options(client))

    refute_received {:task_card_updated, _card_id}
    refute_received {:episode_updated, ^episode_id}
  end

  defp sleeping_options(client),
    do: options(client, idle_interval_ms: 300_000, interval_ms: 300_000)

  defp client!(result),
    do: start_supervised!({Agent, fn -> %{result: result, updates: 0} end})

  defp options(client, overrides \\ []) do
    Map.merge(
      %{
        api: API,
        check_interval_seconds: 1,
        client: client,
        lease_seconds: 300,
        retry_base_seconds: 1,
        worker_ref: "task-card-worker-test"
      },
      Map.new(overrides)
    )
  end

  # Due by the database's clock, which the worker claims with: a host-clock
  # "one second ago" was still in the future whenever the database trailed the
  # host by more than a second, and the gate saw an idle worker.
  defp make_due!(id) do
    past = DateTime.add(Repo.now!(), -3_600, :second)

    Repo.update_all(from(card in TaskCard, where: card.id == ^id),
      set: [next_attempt_at: past, card_checked_at: past]
    )
  end

  defp card!(suffix) do
    producer = claim!("#{suffix}-source")
    task = claim!("#{suffix}-task")

    assert {:ok, offered} =
             Records.create(Records.token(producer.turn), "task-#{suffix}", "task_offer", %{
               "kind" => "engineering",
               "repository" => "ryker",
               "title" => "Cap the card retries",
               "prompt" => "Stop editing a message Slack says is gone."
             })

    offer =
      offered
      |> Ecto.Changeset.change(
        status: :confirmed,
        confirmed_episode_id: task.episode.id,
        confirmed_at: DateTime.utc_now(),
        confirmed_by_actor_ref: "slack:user:U1",
        confirmation_ref: "confirmation-#{suffix}"
      )
      |> Repo.update!()

    card =
      Repo.insert!(%TaskCard{
        id: Ecto.UUID.generate(),
        record_id: offer.id,
        episode_id: task.episode.id,
        ref: "task-card:#{offer.id}",
        workspace_ref: "T123",
        channel_ref: "C456",
        thread_ref: task.episode.destination_thread_ref,
        message_ref: "1787832001.000200"
      })

    %{card | episode: task.episode}
  end

  defp claim!(suffix) do
    id = Ecto.UUID.generate()

    thread_ref =
      "1787832000.#{System.unique_integer([:positive]) |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")}"

    assert {:ok, _} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: id,
                 episode_key: "task-card-worker:#{suffix}:#{id}",
                 native_input_id: "source:#{suffix}:#{id}",
                 turn_ref: "turn:#{id}",
                 payload: %{"text" => "Cap the retries."},
                 destination: %{
                   transport: "slack",
                   conversation_ref: @conversation,
                   thread_ref: thread_ref
                 }
               })
             )

    assert {:ok, _} = Custody.pin_episode(id, "fixture", String.duplicate("a", 64))
    assert {:ok, claim} = Custody.claim_next("worker:#{id}", 60, :work)
    claim
  end
end
