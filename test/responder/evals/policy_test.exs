defmodule Responder.Evals.PolicyTest do
  use ExUnit.Case, async: true

  alias Responder.Evals.Policy

  @configuration %{
    model_evals: %{
      no_tools_policy: "eval-no-tools",
      no_tools_policy_digest: String.duplicate("a", 64),
      world_policy: "eval-world",
      world_policy_digest: String.duplicate("b", 64),
      world_baseline_policy: "eval-world-baseline",
      world_baseline_policy_digest: String.duplicate("c", 64)
    }
  }

  test "each live eval lane receives only its dedicated authority" do
    for kind <- [:admission, :work] do
      assert {:ok,
              %{
                subject: %{name: "eval-no-tools", digest: no_tools_digest},
                judge: nil
              }} = Policy.for_kind(@configuration, kind)

      assert no_tools_digest == String.duplicate("a", 64)
    end

    assert {:ok,
            %{
              subject: %{name: "eval-world", digest: world_digest},
              judge: %{name: "eval-no-tools", digest: judge_digest},
              baseline: %{name: "eval-world-baseline", digest: baseline_digest}
            }} = Policy.for_kind(@configuration, :world)

    assert world_digest == String.duplicate("b", 64)
    assert judge_digest == String.duplicate("a", 64)
    assert baseline_digest == String.duplicate("c", 64)
  end

  test "a world lane may omit a baseline until paired qualification is requested" do
    configuration =
      update_in(
        @configuration.model_evals,
        &Map.drop(&1, [:world_baseline_policy, :world_baseline_policy_digest])
      )

    assert {:ok, %{baseline: nil}} = Policy.for_kind(configuration, :world)
  end

  test "missing or unknown eval authority fails closed" do
    assert Policy.for_kind(%{}, :world) == {:error, :model_eval_policies_not_configured}
    assert Policy.for_kind(@configuration, :unknown) == {:error, :invalid_model_eval_kind}
  end
end
