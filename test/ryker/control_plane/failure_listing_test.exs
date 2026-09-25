defmodule Ryker.ControlPlane.FailureListingTest do
  use Ryker.DataCase, async: true

  alias Ryker.ControlPlane.{Pages, Projection}
  alias Ryker.Delivery.{Operator, PlatformAction}
  alias Ryker.Episodes
  alias Ryker.Episodes.Episode
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Work.Custody

  # Blocked replies were read oldest first, a hundred of each kind, and the page
  # then kept the newest hundred of what it had read. Once more than a hundred
  # replies were blocked, the newest ones, the replies people were still
  # waiting for, were cut before anything sorted them, and nothing on the page
  # said that anything was missing.
  test "the newest blocked replies are listed first, and older ones are a page away, never dropped" do
    turn = work_turn!()
    base = ~U[2099-01-01 00:00:00.000000Z]

    # Oldest first: refs[0] stopped first, refs[100] most recently.
    refs =
      for index <- 0..100, do: blocked_reply!(turn, index, DateTime.add(base, index, :second))

    newest = List.last(refs)
    oldest = hd(refs)

    assert {:ok, [first | _rest]} = Operator.list_blocked(100)
    assert first.delivery_ref == newest

    assert {:ok, page_one} = Projection.failures(%{})
    assert length(page_one) == 100
    assert hd(page_one).ref == newest
    refute Enum.any?(page_one, &(&1.ref == oldest))

    listed = page(%{})
    assert listed =~ ~s(href="/failures?page=2")
    assert listed =~ "Older failures"

    assert {:ok, [%{ref: ^oldest}]} = Projection.failures(%{"page" => "2"})

    older = page(%{"page" => "2"})
    assert older =~ ~s(href="/failures")
    assert older =~ "Newer failures"
    refute older =~ "page=3"

    # A page that is not a number is the first page, not an error.
    assert {:ok, ^page_one} = Projection.failures(%{"page" => "second"})
  end

  test "a page that holds every failure offers no other page" do
    turn = work_turn!()
    blocked_reply!(turn, 0, ~U[2099-01-01 00:00:00.000000Z])

    assert {:ok, [_one]} = Projection.failures(%{})
    listed = page(%{})
    refute listed =~ "page=2"
    refute listed =~ "Older failures"
  end

  defp page(params) do
    page = Pages.page(["failures"], params, %{projection: Projection.callbacks()})
    assert page.status == 200
    page.body
  end

  defp work_turn! do
    episode_id = Ecto.UUID.generate()
    suffix = System.unique_integer([:positive])

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: episode_id,
                 episode_key: "failure-listing:#{suffix}",
                 native_input_id: "source:failure-listing:#{suffix}",
                 payload: %{"text" => "Post the summary."},
                 turn_ref: "turn:failure-listing:#{suffix}"
               })
             )

    assert {:ok, _session} =
             Custody.pin_episode(transition.episode.id, "test-policy", String.duplicate("f", 64))

    # The claimant takes the oldest pending work; make it this episode.
    Episode
    |> Repo.get!(episode_id)
    |> Ecto.Changeset.change(updated_at: ~U[2000-01-01 00:00:00.000000Z])
    |> Repo.update!()

    assert {:ok, claim} = Custody.claim_next("work:failure-listing:#{suffix}", 60)
    assert claim.episode.id == episode_id
    claim.turn
  end

  # Structural: one model-requested Slack post that Slack kept refusing.
  defp blocked_reply!(turn, index, stopped_at) do
    action =
      Repo.insert!(%PlatformAction{
        id: Ecto.UUID.generate(),
        episode_id: turn.episode_id,
        turn_id: turn.id,
        action_ref: "platform-action:failure-listing:#{turn.id}:#{index}",
        host_slot: "failure-listing-#{index}",
        tool: :post_slack_message,
        kind: :message,
        transport: "slack",
        conversation_ref: "slack:TLISTING:CLISTING",
        thread_ref: "1787832000.000100",
        document: %{"message" => "Summary #{index}"},
        intent_fingerprint: String.duplicate("e", 64),
        status: :blocked,
        attempt_count: 3,
        last_error_code: "slack_api_error",
        last_error_detail: ~s|{:slack_api_error, "not_in_channel"}|,
        inserted_at: stopped_at,
        updated_at: stopped_at
      })

    action.action_ref
  end
end
