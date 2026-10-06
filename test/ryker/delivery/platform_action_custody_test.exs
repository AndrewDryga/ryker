defmodule Ryker.Delivery.PlatformActionCustodyTest do
  use Ryker.DataCase, async: true
  import Ecto.Query
  alias Ryker.Delivery.{PlatformAction, PlatformActionCustody, Request}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Work.{Custody, DeliveryReceipt, Validator}

  @now ~U[2026-08-29 12:00:00.000000Z]

  # A reaction or message a request asked for shows on its Timeline, on the
  # conversation it lands in, and on Failures while it is blocked. Until
  # 2026-09-26 those pages heard of it from a trigger's NOTIFY and a
  # five-second poll; custody now announces each change once it commits.
  test "a queued, claimed and delivered action reaches the pages that show it" do
    claim = claim!()
    episode_id = claim.episode.id
    :ok = PlatformActionCustody.subscribe_platform_actions()
    :ok = Episodes.subscribe_episode(episode_id)

    assert {:ok, %{action: %{id: id}, status: :created}} =
             PlatformActionCustody.enqueue_in_turn(claim, reaction_attributes())

    assert_received {:platform_action_updated, ^id}
    assert_received {:episode_updated, ^episode_id}

    assert {:ok, %{action: %{id: ^id}}} =
             PlatformActionCustody.claim_next("platform-action-worker", 60)

    assert_received {:platform_action_updated, ^id}
  end

  test "one live Work turn freezes an exact platform action and exact retries reuse it" do
    claim = claim!()
    attributes = reaction_attributes()

    assert {:ok, %{action: first, status: :created}} =
             PlatformActionCustody.enqueue_in_turn(claim, attributes)

    assert {:ok, %{action: duplicate, status: :duplicate}} =
             PlatformActionCustody.enqueue_in_turn(claim, attributes)

    assert duplicate.id == first.id

    # An action in a natural slot of its own keeps that slot for one intent.
    github = %{
      conversation_ref: "github:example/ryker:pull:42",
      document: %{"action" => "add", "emoji_name" => "eyes"},
      host_slot: "reaction",
      kind: :reaction,
      source_item_ref: "github:issue_comment:1",
      thread_ref: nil,
      tool: :set_github_reaction,
      transport: "github"
    }

    assert {:ok, %{status: :created}} = PlatformActionCustody.enqueue(claim, github)

    assert PlatformActionCustody.enqueue(
             claim,
             put_in(github, [:document, "emoji_name"], "heart")
           ) ==
             {:error, :platform_action_slot_conflict}

    assert {:ok, %{action: claimed, lease_ref: lease_ref}} =
             PlatformActionCustody.claim_next("platform-action-worker", 60)

    assert {:ok,
            %Request{
              document: %{"action" => "add", "emoji_name" => "eyes"},
              ref: action_ref,
              source_item_ref: "1787832000.000100"
            }} = PlatformActionCustody.request(claimed)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               action_ref,
               "slack",
               "slack:T123:C123",
               "1787832000.000100",
               "1787832000.000100"
             )

    assert {:ok, delivered} =
             PlatformActionCustody.confirm_delivery(action_ref, lease_ref, receipt)

    assert delivered.status == :delivered
    assert delivered.external_receipt == receipt
    assert {:ok, same} = PlatformActionCustody.confirm_delivery(action_ref, lease_ref, receipt)
    assert same.id == delivered.id

    [input_ref] = claim.episode.active_input_refs

    assert %{
             ^action_ref => %{
               "action" => "add",
               "action_kind" => "reaction",
               "continuation" => nil,
               "current_human_inputs" => [
                 %{
                   "input_ref" => ^input_ref,
                   "source_item_ref" => "1787832000.000100"
                 }
               ],
               "kind" => "platform_action",
               "source_item_ref" => "1787832000.000100",
               "status" => "delivered",
               "tool" => "set_slack_reaction"
             }
           } = PlatformActionCustody.validation_records(claim.episode.id)
  end

  test "validation records retain every active human input when one reaction cannot cover all" do
    claim = claim_with_two_human_inputs!()

    assert {:ok, %{action: action}} =
             PlatformActionCustody.enqueue_in_turn(claim, reaction_attributes())

    [first_input_ref, second_input_ref] = claim.episode.active_input_refs

    assert %{
             "current_human_inputs" => [
               %{
                 "input_ref" => ^first_input_ref,
                 "source_item_ref" => "1787832000.000100"
               },
               %{"input_ref" => ^second_input_ref, "source_item_ref" => "1787832000.000200"}
             ]
           } = PlatformActionCustody.validation_records(claim.episode.id)[action.action_ref]
  end

  test "model action history contains only typed identity and status rather than retained payload" do
    # Derived-context review checked this sibling read path: adding request or
    # response text here would need the same producer-source custody as records.
    claim = claim!()

    assert {:ok, %{action: action}} =
             PlatformActionCustody.enqueue_in_turn(claim, reaction_attributes())

    assert PlatformActionCustody.model_actions(claim.episode.id) == [
             %{
               "action_ref" => action.action_ref,
               "kind" => "reaction",
               "status" => "pending",
               "tool" => "set_slack_reaction"
             }
           ]
  end

  test "a delivered reaction removal cannot replace the reply to a current human input" do
    # The cost of accepting this is a human request ending with neither a reply nor even the
    # reaction that the final claims answered it, despite every host operation succeeding.
    claim = claim!()
    attributes = put_in(reaction_attributes(), [:document, "action"], "remove")
    assert {:ok, %{action: action}} = PlatformActionCustody.enqueue_in_turn(claim, attributes)

    assert {:ok, %{action: claimed, lease_ref: lease_ref}} =
             PlatformActionCustody.claim_next("platform-action-worker", 60)

    assert claimed.id == action.id

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               action.action_ref,
               "slack",
               "slack:T123:C123",
               "1787832000.000100",
               "1787832000.000100"
             )

    assert {:ok, delivered} =
             PlatformActionCustody.confirm_delivery(action.action_ref, lease_ref, receipt)

    assert delivered.status == :delivered

    records = PlatformActionCustody.validation_records(claim.episode.id, claim.turn.id)

    candidate =
      Jason.encode!(%{
        "decision_reason" => "The delivered reaction fully acknowledges this social message.",
        "delivery" => "none",
        "message" => nil,
        "outcome" => %{
          "artifact_refs" => [],
          "record_refs" => [action.action_ref],
          "state" => "complete"
        }
      })

    assert {:reject, violations} =
             Validator.validate(candidate, validation_context(records), @now)

    assert Enum.any?(violations, &String.contains?(&1, "Reaction removals"))
  end

  test "a reaction Ryker already took back does not authorize removing a human's" do
    # Removal authority came from "an add of this emoji was delivered on this
    # message", which stays true forever: after Ryker added and then removed
    # its own eyes, a person adding eyes would be the one removed on the next
    # model request. The latest delivered reaction action for that emoji has
    # to be the add.
    first = claim!()
    deliver!(first, reaction_attributes())

    assert PlatformActionCustody.delivered_reaction_added?(
             first.episode.id,
             "slack:T123:C123",
             "1787832000.000100",
             "eyes"
           )

    deliver!(first, put_in(reaction_attributes(), [:document, "action"], "remove"))

    refute PlatformActionCustody.delivered_reaction_added?(
             first.episode.id,
             "slack:T123:C123",
             "1787832000.000100",
             "eyes"
           )
  end

  # Andrew, 2026-09-26: "allow even quick model to send multiple reply
  # events, some messages, some emojis (and normal model should be able to do
  # that too)". A second reaction in one Work turn came back
  # "temporarily_unavailable", which the model reads as "try the same call
  # again". A turn now adds up to three: each frozen once, sent in the order
  # asked, the same emoji again the same reaction, and the answer refused
  # while any is still on its way.
  test "a turn adds a few reactions, each once and in the order asked, and the answer waits for them" do
    claim = claim!()

    assert {:ok, %{action: eyes, status: :created}} =
             PlatformActionCustody.enqueue_in_turn(claim, reaction_attributes("eyes"))

    assert {:ok, %{action: thumbsup, status: :created}} =
             PlatformActionCustody.enqueue_in_turn(claim, reaction_attributes("thumbsup"))

    # The same emoji again is the same reaction, not another one.
    assert {:ok, %{action: ^eyes, status: :duplicate}} =
             PlatformActionCustody.enqueue_in_turn(claim, reaction_attributes("eyes"))

    assert {:ok, %{action: tada, status: :created}} =
             PlatformActionCustody.enqueue_in_turn(claim, reaction_attributes("tada"))

    assert Enum.map([eyes, thumbsup, tada], & &1.host_slot) ==
             ~w(reaction:1 reaction:2 reaction:3)

    assert PlatformActionCustody.enqueue_in_turn(claim, reaction_attributes("rocket")) ==
             {:error, :reaction_limit_reached}

    # The second waits while the first is out, even after the first is put
    # back for a retry.
    assert {:ok, %{action: out, lease_ref: lease_ref}} =
             PlatformActionCustody.claim_next("platform-action-worker", 60)

    assert out.id == eyes.id
    assert {:ok, nil} = PlatformActionCustody.claim_next("platform-action-worker-2", 60)

    assert {:ok, _deferred} =
             PlatformActionCustody.defer(
               out.action_ref,
               lease_ref,
               1,
               "delivery_uncertain",
               "Slack's answer was lost."
             )

    Repo.update_all(Ryker.Delivery.PlatformAction, set: [next_attempt_at: @now])

    assert {:ok, %{action: retried, lease_ref: lease_ref}} =
             PlatformActionCustody.claim_next("platform-action-worker", 60)

    assert retried.id == eyes.id
    deliver_claimed!(retried, lease_ref, retried.source_item_ref)

    assert {:ok, %{action: next, lease_ref: lease_ref}} =
             PlatformActionCustody.claim_next("platform-action-worker", 60)

    assert next.id == thumbsup.id
    deliver_claimed!(next, lease_ref, next.source_item_ref)

    answer =
      Jason.encode!(%{
        "decision_reason" => nil,
        "delivery" => "reply",
        "message" => "Done.",
        "outcome" => %{"artifact_refs" => [], "record_refs" => [], "state" => "complete"}
      })

    records = PlatformActionCustody.validation_records(claim.episode.id, claim.turn.id)
    assert {:reject, [violation]} = Validator.validate(answer, validation_context(records), @now)

    assert violation =~
             "Do not complete while platform actions are unresolved: #{tada.action_ref}"

    assert {:ok, %{action: last, lease_ref: lease_ref}} =
             PlatformActionCustody.claim_next("platform-action-worker", 60)

    assert last.id == tada.id
    deliver_claimed!(last, lease_ref, last.source_item_ref)

    records = PlatformActionCustody.validation_records(claim.episode.id, claim.turn.id)
    assert {:accept, _accepted} = Validator.validate(answer, validation_context(records), @now)
  end

  # Taking a reaction back stays what it was: one call for one emoji on one
  # message, allowed only for a reaction Ryker added. Put back after that, it
  # is a new reaction; answered as a repeat of the first add, it would leave
  # the emoji off while telling the model it was on.
  test "a reaction taken back and put on again in one turn is three reactions, not one" do
    claim = claim!()

    assert {:ok, %{action: added, status: :created}} =
             PlatformActionCustody.enqueue_in_turn(claim, reaction_attributes("eyes"))

    assert {:ok, %{action: removed, status: :created}} =
             PlatformActionCustody.enqueue_in_turn(claim, reaction_attributes("eyes", "remove"))

    assert {:ok, %{action: ^removed, status: :duplicate}} =
             PlatformActionCustody.enqueue_in_turn(claim, reaction_attributes("eyes", "remove"))

    assert {:ok, %{action: again, status: :created}} =
             PlatformActionCustody.enqueue_in_turn(claim, reaction_attributes("eyes"))

    assert Enum.map([added, removed, again], &{&1.host_slot, &1.document["action"]}) == [
             {"reaction:1", "add"},
             {"reaction:2", "remove"},
             {"reaction:3", "add"}
           ]

    # A reaction or an update always takes the turn's next place; nothing
    # reaches either through a slot of its own choosing.
    assert PlatformActionCustody.enqueue(
             claim,
             Map.put(reaction_attributes("heart"), :host_slot, "x")
           ) ==
             {:error, {:invalid_platform_action, :host_slot}}
  end

  # Andrew, 2026-09-26: "Sometimes it's even helpful to let model to do that
  # mid-conversation to make it really live." The Work model may now post a
  # short update into its own conversation while it works. Each is posted
  # once, in the order it was written; a turn posts only a few; and the final
  # answer is refused while an update is still on its way, or the answer
  # could land above the update that led to it.
  test "a Work update is posted once, in order, a turn posts few, and the answer waits for them" do
    claim = claim!()

    assert {:ok, %{action: first, status: :created}} =
             PlatformActionCustody.enqueue_in_turn(
               claim,
               update_attributes("Looking at the deploy now.")
             )

    assert {:ok, %{action: second, status: :created}} =
             PlatformActionCustody.enqueue_in_turn(
               claim,
               update_attributes("The rollout is at 40%.")
             )

    # The same update asked for again is the same update, not a second post.
    assert {:ok, %{action: ^second, status: :duplicate}} =
             PlatformActionCustody.enqueue_in_turn(
               claim,
               update_attributes("The rollout is at 40%.")
             )

    assert {:ok, %{action: third, status: :created}} =
             PlatformActionCustody.enqueue_in_turn(
               claim,
               update_attributes("Checking the error rate.")
             )

    assert Enum.map([first, second, third], & &1.host_slot) == ~w(update:1 update:2 update:3)
    assert Enum.all?([first, second, third], &(&1.thread_ref == "1787832000.000100"))

    assert PlatformActionCustody.enqueue_in_turn(claim, update_attributes("One more thing.")) ==
             {:error, :update_limit_reached}

    # The second waits while the first is out.
    assert {:ok, %{action: out, lease_ref: lease_ref}} =
             PlatformActionCustody.claim_next("platform-action-worker", 60)

    assert out.id == first.id
    assert {:ok, nil} = PlatformActionCustody.claim_next("platform-action-worker-2", 60)
    deliver_claimed!(out, lease_ref, "1787832000.000301")

    # The answer is refused while the third update is still on its way.
    for {update, message_ref} <- [{second, "1787832000.000302"}] do
      assert {:ok, %{action: next, lease_ref: lease_ref}} =
               PlatformActionCustody.claim_next("platform-action-worker", 60)

      assert next.id == update.id
      deliver_claimed!(next, lease_ref, message_ref)
    end

    answer =
      Jason.encode!(%{
        "decision_reason" => nil,
        "delivery" => "reply",
        "message" => "The deploy finished and the error rate is back to normal.",
        "outcome" => %{"artifact_refs" => [], "record_refs" => [], "state" => "complete"}
      })

    records = PlatformActionCustody.validation_records(claim.episode.id, claim.turn.id)
    assert {:reject, [violation]} = Validator.validate(answer, validation_context(records), @now)

    assert violation =~
             "Do not complete while platform actions are unresolved: #{third.action_ref}"

    assert {:ok, %{action: last, lease_ref: lease_ref}} =
             PlatformActionCustody.claim_next("platform-action-worker", 60)

    assert last.id == third.id
    deliver_claimed!(last, lease_ref, "1787832000.000303")

    records = PlatformActionCustody.validation_records(claim.episode.id, claim.turn.id)
    assert {:accept, _accepted} = Validator.validate(answer, validation_context(records), @now)
  end

  # The action delivery lane sleeps until this moment (`PollingWorker.idle_delay/2`): an
  # answer too late or missing leaves a due reaction or update waiting out the
  # safety-net interval. The 2026-09-27 crash was in this family, a due-time aggregate
  # that came back without a zone and crashed every Work and delivery lane on each poll
  # while a row was due. Nothing ran this query against rows before.
  test "the action lane sleeps until an action's retry or unrenewed lease" do
    claim = claim!()
    since = Repo.now!()
    at = &DateTime.add(since, &1, :second)

    assert {:ok, %{action: reaction}} =
             PlatformActionCustody.enqueue_in_turn(claim, reaction_attributes())

    assert {:ok, %{action: update}} =
             PlatformActionCustody.enqueue_in_turn(
               claim,
               update_attributes("Checking the deploy.")
             )

    # Queued, they wait on nothing timed.
    assert PlatformActionCustody.next_due_at(since) == nil

    assert {:ok, %{action: %{id: reaction_id}, lease_ref: reaction_lease}} =
             PlatformActionCustody.claim_next("platform-action-worker", 60)

    assert reaction_id == reaction.id

    assert {:ok, %PlatformAction{lease_ref: nil}} =
             PlatformActionCustody.defer(
               reaction.action_ref,
               reaction_lease,
               1,
               "delivery_uncertain",
               "Slack's answer was lost."
             )

    assert {:ok, %{action: %{id: update_id}}} =
             PlatformActionCustody.claim_next("platform-action-worker", 60)

    assert update_id == update.id
    due!(reaction.id, next_attempt_at: at.(30))
    due!(update.id, lease_expires_at: at.(20))
    assert PlatformActionCustody.next_due_at(since) == at.(20)

    due!(update.id, lease_expires_at: at.(45))
    assert PlatformActionCustody.next_due_at(since) == at.(30)

    # A moment already reached wakes nothing more: the lane takes it this poll.
    assert PlatformActionCustody.next_due_at(at.(30)) == at.(45)
  end

  test "shadow work cannot create a platform side effect" do
    claim = claim!()

    Repo.query!(
      "UPDATE episode_kernel_episodes SET execution_mode = 'shadow' WHERE id = $1",
      [Ecto.UUID.dump!(claim.episode.id)]
    )

    assert PlatformActionCustody.enqueue_in_turn(claim, reaction_attributes()) ==
             {:error, :platform_action_not_authorized}
  end

  test "an expired Work binding cannot create a platform side effect" do
    claim = claim!()

    Repo.query!(
      "UPDATE episode_work_turns SET lease_expires_at = clock_timestamp() - interval '1 second' WHERE id = $1",
      [
        Ecto.UUID.dump!(claim.turn.id)
      ]
    )

    assert PlatformActionCustody.enqueue_in_turn(claim, reaction_attributes()) ==
             {:error, :platform_action_not_authorized}
  end

  defp due!(action_id, fields) do
    {1, nil} =
      Repo.update_all(from(action in PlatformAction, where: action.id == ^action_id), set: fields)
  end

  defp claim! do
    episode_id = Ecto.UUID.generate()
    assert {:ok, transition} = Episodes.apply(input(episode_id))
    pin_and_claim!(transition.episode)
  end

  # Enqueues one action on the claim's turn and settles it as delivered.
  defp deliver!(claim, attributes) do
    assert {:ok, %{action: action}} = PlatformActionCustody.enqueue_in_turn(claim, attributes)

    assert {:ok, %{action: claimed, lease_ref: lease_ref}} =
             PlatformActionCustody.claim_next("platform-action-worker", 60)

    assert claimed.id == action.id

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               action.action_ref,
               "slack",
               "slack:T123:C123",
               "1787832000.000100",
               "1787832000.000100"
             )

    assert {:ok, %{status: :delivered}} =
             PlatformActionCustody.confirm_delivery(action.action_ref, lease_ref, receipt)

    action
  end

  defp claim_with_two_human_inputs! do
    episode_id = Ecto.UUID.generate()
    assert {:ok, first} = Episodes.apply(input(episode_id))

    assert {:ok, second} =
             Episodes.apply(
               input(episode_id,
                 actor_ref: "slack:user:U2",
                 native_input_id: "platform-action:input:second:#{episode_id}",
                 occurred_at: DateTime.add(@now, 1, :second),
                 payload: %{"source_item_ref" => "1787832000.000200"}
               )
             )

    [second_input_ref] = second.episode.queued_input_refs

    assert {:ok, transferred} =
             Episodes.apply(
               EpisodeFixtures.transfer_owner(%{
                 episode_key: first.episode.key,
                 expected_owner: %{kind: :turn, ref: first.episode.owner_ref},
                 new_owner: %{kind: :turn, ref: "platform-action:replacement:#{episode_id}"},
                 occurred_at: DateTime.add(@now, 2, :second),
                 required_input_ref: second_input_ref,
                 transfer_ref: "platform-action:transfer:#{episode_id}"
               })
             )

    pin_and_claim!(transferred.episode)
  end

  defp input(episode_id, overrides \\ []) do
    overrides = Map.new(overrides)

    EpisodeFixtures.admit_input(
      Map.merge(
        %{
          destination: %{
            conversation_ref: "slack:T123:C123",
            thread_ref: "1787832000.000100",
            transport: "slack"
          },
          episode_id: episode_id,
          episode_key: "platform-action:#{episode_id}",
          native_input_id: "platform-action:input:#{episode_id}",
          occurred_at: @now,
          payload: %{"source_item_ref" => "1787832000.000100"},
          turn_ref: "platform-action:turn:#{episode_id}"
        },
        overrides
      )
    )
  end

  defp pin_and_claim!(episode) do
    assert {:ok, _session} =
             Custody.pin_episode(episode.id, "work-read-only", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("platform-action-work", 60)
    assert claim.episode.id == episode.id
    claim
  end

  defp validation_context(records) do
    %{
      "artifact_delivery_supported" => true,
      "artifact_metadata" => [],
      "artifact_refs" => [],
      "execution_mode" => "live",
      "open_required_goals" => [],
      "records" => records,
      "slack_mentions" => nil,
      "visible_reply_required" => true,
      "workspace" => nil
    }
  end

  defp update_attributes(message) do
    %{
      conversation_ref: "slack:T123:C123",
      document: %{"message" => message},
      kind: :message,
      source_item_ref: nil,
      thread_ref: "1787832000.000100",
      tool: :post_slack_update,
      transport: "slack"
    }
  end

  defp deliver_claimed!(action, lease_ref, message_ref) do
    assert {:ok, receipt} =
             DeliveryReceipt.new(
               action.action_ref,
               action.transport,
               action.conversation_ref,
               action.thread_ref,
               message_ref
             )

    assert {:ok, %{status: :delivered}} =
             PlatformActionCustody.confirm_delivery(action.action_ref, lease_ref, receipt)
  end

  # A Slack reaction as the tool asks for it; custody gives it the turn's
  # next reaction place.
  defp reaction_attributes(emoji_name \\ "eyes", action \\ "add") do
    %{
      conversation_ref: "slack:T123:C123",
      document: %{"action" => action, "emoji_name" => emoji_name},
      kind: :reaction,
      source_item_ref: "1787832000.000100",
      thread_ref: "1787832000.000100",
      tool: :set_slack_reaction,
      transport: "slack"
    }
  end
end
