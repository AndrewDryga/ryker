defmodule Ryker.Work.StateBindingTest do
  use ExUnit.Case, async: true

  alias Ryker.Work.{Session, StateBinding, Turn}

  test "state-tool authority is exact to one logical turn and one session placement" do
    session = %Session{id: Ecto.UUID.generate()}
    replacement = %Session{id: Ecto.UUID.generate()}
    turn = %Turn{id: Ecto.UUID.generate()}
    next_turn = %Turn{id: Ecto.UUID.generate()}
    endpoint = "https://ryker.example/v1/state-tools/mcp"
    secret = "controller-state-tools-secret"
    scope = StateBinding.local_scope(session)

    assert {:ok, binding} = StateBinding.derive(session, turn, scope, endpoint, secret)

    assert {:ok, next_binding} =
             StateBinding.derive(session, next_turn, scope, endpoint, secret)

    assert {:ok, replacement_binding} =
             StateBinding.derive(
               replacement,
               turn,
               StateBinding.local_scope(replacement),
               endpoint,
               secret
             )

    assert {:ok, replacement_scope_binding} =
             StateBinding.derive(session, turn, "placement:replacement", endpoint, secret)

    refute binding.token == next_binding.token
    refute binding.token == replacement_binding.token
    refute binding.token == replacement_scope_binding.token
    assert StateBinding.scope_matches?(binding.token, scope)
    refute StateBinding.scope_matches?(binding.token, "placement:replacement")
    assert StateBinding.document(binding) == %{"endpoint" => endpoint, "token" => binding.token}
    assert binding.token_sha256 == StateBinding.sha256(binding.token)

    bound = %Turn{
      state_tools_endpoint: endpoint,
      state_tools_token_sha256: binding.token_sha256
    }

    assert StateBinding.binding_digest(bound) ==
             StateBinding.sha256(endpoint <> <<0>> <> binding.token_sha256)

    assert StateBinding.binding_digest(%Turn{}) == nil

    for invalid_endpoint <- [
          "http://ryker.example/v1/state-tools/mcp",
          "https://ryker.example/wrong",
          "https://user@ryker.example/v1/state-tools/mcp",
          "https://ryker.example/v1/state-tools/mcp?token=leak",
          String.duplicate("a", 2_049)
        ] do
      assert StateBinding.derive(session, turn, scope, invalid_endpoint, secret) ==
               {:error, {:invalid_work_state_tools_binding, :endpoint}}
    end

    for invalid_secret <- ["short", String.duplicate("a", 4_097), "valid-secret-value" <> <<0>>] do
      assert StateBinding.derive(session, turn, scope, endpoint, invalid_secret) ==
               {:error, {:invalid_work_state_tools_binding, :secret}}
    end

    assert StateBinding.derive(%Session{}, turn, scope, endpoint, secret) ==
             {:error, {:invalid_work_state_tools_binding, :fields}}

    assert StateBinding.derive(session, %Turn{}, scope, endpoint, secret) ==
             {:error, {:invalid_work_state_tools_binding, :fields}}

    assert StateBinding.derive(session, turn, "", endpoint, secret) ==
             {:error, {:invalid_work_state_tools_binding, :scope}}

    refute StateBinding.scope_matches?(:not_a_token, scope)

    assert StateBinding.current_scope(%Session{}) ==
             {:error, {:invalid_work_state_tools_binding, :session}}
  end
end
