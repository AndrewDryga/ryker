defmodule Ryker.Work.EnvironmentContextTest do
  use Ryker.DataCase, async: true
  alias Ryker.Episodes.Episode
  alias Ryker.Work.EnvironmentContext

  test "an absent source identity never borrows the channel's current environment" do
    for source <- [%{work_profile: nil}, %{work_profile: %{}}, %Episode{}, nil] do
      assert EnvironmentContext.ref(source) == nil
      assert EnvironmentContext.model_context(source) == nil
    end
  end

  test "a removed environment retains its source identity without replacement labels" do
    source = %{work_profile: %{"environment_ref" => "removed-product"}}
    assert EnvironmentContext.ref(source) == "removed-product"
    assert EnvironmentContext.model_context(source) == %{"ref" => "removed-product"}
  end
end
