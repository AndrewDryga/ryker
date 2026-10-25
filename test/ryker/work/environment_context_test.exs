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

  test "a retained bare source is different from a missing producer" do
    assert EnvironmentContext.provenance(%{work_profile: nil}) == %{
             environment_ref: nil,
             environment_known: true
           }

    for missing <- [nil, %{}, %Episode{}] do
      assert EnvironmentContext.provenance(missing) == %{
               environment_ref: nil,
               environment_known: false
             }
    end

    assert EnvironmentContext.provenance(nil) == %{
             environment_ref: nil,
             environment_known: false
           }

    assert EnvironmentContext.provenance(%{
             environment_ref: "product-a",
             environment_known: false
           }) == %{
             environment_ref: "product-a",
             environment_known: false
           }
  end

  test "a removed environment retains its source identity without replacement labels" do
    source = %{work_profile: %{"environment_ref" => "removed-product"}}
    assert EnvironmentContext.ref(source) == "removed-product"
    assert EnvironmentContext.model_context(source) == %{"ref" => "removed-product"}
  end
end
