defmodule Ryker.Evals.PolicyTest do
  use Ryker.DataCase, async: false

  alias Ryker.Evals.Policy
  alias Ryker.Settings

  @no_tools String.duplicate("a", 64)
  @world String.duplicate("b", 64)
  @baseline String.duplicate("c", 64)

  setup do
    environment(%{
      "RYKER_EVAL_SOCKET" => "/var/lib/ryker/eval-coop/control.sock",
      "RYKER_EVAL_NO_TOOLS_POLICY" => "eval-no-tools",
      "RYKER_EVAL_NO_TOOLS_POLICY_DIGEST" => @no_tools,
      "RYKER_EVAL_WORLD_POLICY" => "eval-world",
      "RYKER_EVAL_WORLD_POLICY_DIGEST" => @world,
      "RYKER_EVAL_WORLD_BASELINE_POLICY" => "eval-world-baseline",
      "RYKER_EVAL_WORLD_BASELINE_POLICY_DIGEST" => @baseline
    })
  end

  test "each live eval lane receives only its dedicated authority" do
    for kind <- [:admission, :work] do
      assert {:ok, %{subject: %{name: "eval-no-tools", digest: @no_tools}, judge: nil}} =
               Policy.for_kind(kind)
    end

    assert {:ok,
            %{
              subject: %{name: "eval-world", digest: @world},
              judge: %{name: "eval-no-tools", digest: @no_tools},
              baseline: %{name: "eval-world-baseline", digest: @baseline}
            }} = Policy.for_kind(:world)

    assert Policy.socket() == {:ok, "/var/lib/ryker/eval-coop/control.sock"}
  end

  test "a world lane may omit a baseline until paired qualification is requested" do
    System.delete_env("RYKER_EVAL_WORLD_BASELINE_POLICY")
    assert {:ok, %{baseline: nil}} = Policy.for_kind(:world)
  end

  test "an eval can never borrow a reviewed production authority" do
    # Running an evaluation beside a configured installation must not let it
    # acquire that installation's repository or mutation grants.
    {:ok, _} = Settings.initialize("control-plane:local")
    {:ok, _} = Settings.put_repository(%{ref: "ryker"}, 1, "control-plane:local")

    {:ok, _} =
      Settings.put_policy_binding(
        %{
          purpose: :conversational,
          scope_kind: :repository,
          scope_ref: "ryker",
          policy_name: "ryker-conversation-v1",
          policy_digest: @world,
          verified_by: :import
        },
        2,
        "control-plane:local"
      )

    assert Policy.for_kind(:world) == {:error, :model_eval_reuses_production_authority}
    assert {:ok, %{subject: %{name: "eval-no-tools"}}} = Policy.for_kind(:admission)

    System.put_env("RYKER_EVAL_NO_TOOLS_POLICY", "ryker-conversation-v1")
    assert Policy.for_kind(:admission) == {:error, :model_eval_reuses_production_authority}
  end

  test "missing, malformed or crossed eval authority fails closed" do
    System.delete_env("RYKER_EVAL_NO_TOOLS_POLICY")
    assert Policy.for_kind(:world) == {:error, :model_eval_policies_not_configured}
    assert Policy.for_kind(:unknown) == {:error, :invalid_model_eval_kind}

    environment(%{
      "RYKER_EVAL_NO_TOOLS_POLICY" => "eval-no-tools",
      "RYKER_EVAL_NO_TOOLS_POLICY_DIGEST" => "not-a-digest"
    })

    assert Policy.for_kind(:admission) == {:error, :invalid_model_eval_policy_digest}

    environment(%{"RYKER_EVAL_NO_TOOLS_POLICY_DIGEST" => @no_tools})
    environment(%{"RYKER_EVAL_WORLD_POLICY_DIGEST" => @no_tools})
    assert Policy.for_kind(:world) == {:error, :model_eval_policies_must_be_distinct}

    System.delete_env("RYKER_EVAL_SOCKET")
    assert Policy.socket() == {:error, :model_eval_socket_not_configured}
    System.put_env("RYKER_EVAL_SOCKET", "relative/control.sock")
    assert Policy.socket() == {:error, :model_eval_socket_must_be_absolute}
  end

  defp environment(values) do
    Enum.each(values, fn {name, value} -> put_variable(name, value) end)
    :ok
  end

  defp put_variable(name, value) do
    previous = System.get_env(name)
    System.put_env(name, value)
    on_exit(fn -> restore_variable(name, previous) end)
  end

  defp restore_variable(name, nil), do: System.delete_env(name)
  defp restore_variable(name, previous), do: System.put_env(name, previous)
end
