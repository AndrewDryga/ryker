defmodule Responder.Evals.WorldMatchTest do
  use ExUnit.Case, async: true

  alias Responder.Evals.WorldMatch

  test "reviewed match rules preserve exact list shape and nested values" do
    pattern = [%{"kind" => "deployment"}, %{"targets" => ["api", "worker"]}]

    assert WorldMatch.matches?(pattern, [
             %{"kind" => "deployment", "status" => "healthy"},
             %{"targets" => ["api", "worker"], "timestamp" => "now"}
           ])

    refute WorldMatch.matches?(pattern, [%{"kind" => "deployment"}])

    refute WorldMatch.matches?(pattern, [
             %{"kind" => "deployment"},
             %{"targets" => ["worker", "api"]}
           ])
  end

  test "reviewed contains-all rules match bounded query concepts without a hidden magic string" do
    pattern = %{"$contains_all" => ["checkout", "error"]}

    assert WorldMatch.matches?(
             pattern,
             "Checkout error rate over the last 15 minutes compared with baseline"
           )

    refute WorldMatch.matches?(pattern, "checkout request volume")
    refute WorldMatch.matches?(pattern, 42)
    refute WorldMatch.matches?(%{"$contains_all" => [1]}, "one")

    assert WorldMatch.valid?(pattern)
    refute WorldMatch.valid?(%{"$contains_all" => []})
    refute WorldMatch.valid?(%{"$contains_all" => ["same", "SAME"]})
    refute WorldMatch.valid?(%{"$contains_all" => [String.duplicate("x", 129)]})
  end

  test "reviewed aliases may choose among bounded text concept groups" do
    pattern = %{
      "$one_of" => [
        %{"$contains_all" => ["uptime", "nomad-hvn03"]},
        %{"$contains_all" => ["node_boot_time", "nomad-hvn03"]}
      ]
    }

    assert WorldMatch.valid?(pattern)
    assert WorldMatch.matches?(pattern, "What is the uptime for nomad-hvn03?")

    assert WorldMatch.matches?(
             pattern,
             ~s|time() - node_boot_time_seconds{instance="nomad-hvn03"}|
           )

    refute WorldMatch.matches?(pattern, "memory usage for nomad-hvn03")
  end

  test "only bounded non-nested operators and JSON-shaped values are valid" do
    assert WorldMatch.valid?([%{"kind" => "deployment"}, nil, true, 3])
    refute WorldMatch.valid?(%{"$unknown" => "anything"})
    refute WorldMatch.valid?(%{1 => "non-string-key"})
    refute WorldMatch.valid?(%{"$one_of" => []})
    refute WorldMatch.valid?(%{"$one_of" => ["same", "same"]})
    refute WorldMatch.valid?(%{"$one_of" => Enum.to_list(1..33)})
    refute WorldMatch.valid?(%{"$one_of" => %{"not" => "a list"}})

    refute WorldMatch.valid?(%{
             "$one_of" => [%{"$one_of" => ["nested", "operator"]}, "ordinary"]
           })
  end
end
