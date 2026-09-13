defmodule Ryker.StateTools.BindingTest do
  use Ryker.DataCase, async: true

  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.StateTools.Binding
  alias Ryker.Work.{Cancellation, Custody, StateBinding}

  test "only the exact live leased turn can use its state-tools bearer" do
    command =
      EpisodeFixtures.admit_input(%{
        episode_id: Ecto.UUID.generate(),
        episode_key: "state-binding:#{Ecto.UUID.generate()}",
        native_input_id: "source:state-binding:#{Ecto.UUID.generate()}",
        payload: %{"text" => "Please inspect the state."},
        turn_ref: "turn:state-binding:#{Ecto.UUID.generate()}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(command.episode_id, "test-policy", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("worker:state-binding", 60)

    assert {:ok, state_binding} =
             StateBinding.derive(
               claim.session,
               claim.turn,
               StateBinding.local_scope(claim.session),
               "https://ryker.example/v1/state-tools/mcp",
               "controller-state-tools-secret"
             )

    assert {:ok, _session} =
             Custody.bind_state_tools(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               state_binding.endpoint,
               state_binding.token_sha256
             )

    assert {:ok, binding} = Binding.resolve(state_binding.token)
    assert binding.episode.id == claim.episode.id
    assert binding.session.id == claim.session.id
    assert binding.turn.id == claim.turn.id
    assert Binding.authorize(state_binding.token) == :ok

    assert Binding.resolve("wrong-secret-that-is-long-enough-to-check") ==
             {:error, :state_tools_binding_not_authorized}

    assert Binding.resolve(:not_a_token) == {:error, :state_tools_binding_not_authorized}

    assert {:ok, _deferred} =
             Custody.defer(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               1,
               "retry",
               "release the lease"
             )

    assert Binding.authorize(state_binding.token) ==
             {:error, :state_tools_binding_not_authorized}
  end

  test "a replacement logical turn cannot be reached with the previous turn bearer" do
    command =
      EpisodeFixtures.admit_input(%{
        episode_id: Ecto.UUID.generate(),
        episode_key: "state-binding-replacement:#{Ecto.UUID.generate()}",
        native_input_id: "source:state-binding-replacement:#{Ecto.UUID.generate()}",
        payload: %{"text" => "Continue this task safely."},
        turn_ref: "turn:state-binding-original:#{Ecto.UUID.generate()}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(command.episode_id, "test-policy", String.duplicate("a", 64))

    assert {:ok, original} = Custody.claim_next("worker:state-binding-original", 60)

    assert {:ok, original_binding} =
             StateBinding.derive(
               original.session,
               original.turn,
               StateBinding.local_scope(original.session),
               "https://ryker.example/v1/state-tools/mcp",
               "controller-state-tools-secret"
             )

    assert {:ok, _turn} =
             Custody.bind_state_tools(
               original.episode.id,
               original.turn.turn_ref,
               original.lease_ref,
               original_binding.endpoint,
               original_binding.token_sha256
             )

    replacement_ref = "turn:state-binding-replacement:#{Ecto.UUID.generate()}"

    assert {:ok, %{status: :pending}} =
             Custody.request_transfer(
               original.episode.id,
               original.episode.key,
               original.turn.turn_ref,
               replacement_ref,
               "transfer:state-binding:#{Ecto.UUID.generate()}"
             )

    assert {:ok, cancellation} = Custody.claim_next("worker:state-binding-cancel", 60)

    create_operation_ref =
      "ryker:work:create:#{original.session.id}:g#{original.session.create_generation}"

    assert {:ok, receipt} = Cancellation.absent_receipt(create_operation_ref, nil, nil, nil, nil)

    assert {:ok, %{episode: %{owner_ref: ^replacement_ref}}} =
             Custody.settle_cancellation(
               original.episode.id,
               original.episode.key,
               original.turn.turn_ref,
               cancellation.lease_ref,
               receipt
             )

    assert {:ok, replacement} = Custody.claim_next("worker:state-binding-replacement", 60)
    assert replacement.turn.turn_ref == replacement_ref

    assert {:ok, replacement_binding} =
             StateBinding.derive(
               replacement.session,
               replacement.turn,
               StateBinding.local_scope(replacement.session),
               "https://ryker.example/v1/state-tools/mcp",
               "controller-state-tools-secret"
             )

    assert {:ok, _turn} =
             Custody.bind_state_tools(
               replacement.episode.id,
               replacement.turn.turn_ref,
               replacement.lease_ref,
               replacement_binding.endpoint,
               replacement_binding.token_sha256
             )

    assert original_binding.token != replacement_binding.token

    assert Binding.resolve(original_binding.token) ==
             {:error, :state_tools_binding_not_authorized}

    assert {:ok, binding} = Binding.resolve(replacement_binding.token)
    assert binding.turn.id == replacement.turn.id
  end
end
