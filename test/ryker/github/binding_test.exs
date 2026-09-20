defmodule Ryker.GitHub.BindingTest do
  use ExUnit.Case, async: true

  alias Ryker.GitHub.Binding

  @valid [
    installation_id: 41,
    name: "github-main",
    repository_full_name: "octo/example",
    repository_id: 99,
    ryker_actor_id: 99,
    secret: String.duplicate("s", 32),
    work_profile: %{
      policy: "github-read-only",
      policy_digest: String.duplicate("a", 64),
      repository_ref: "octo/example"
    }
  ]

  test "normalizes unique keyword attributes and applies the bounded body default" do
    assert {:ok, binding} = Binding.new(@valid)
    assert binding.max_body_bytes == 40_000
    assert binding.work_profile.repository_ref == "octo/example"
  end

  test "rejects malformed fields before a binding can grant repository authority" do
    assert Binding.new(:invalid) == {:error, {:invalid_github_binding, :fields}}

    assert Binding.new(@valid ++ [name: "duplicate"]) ==
             {:error, {:invalid_github_binding, :fields}}

    assert Binding.new(Map.put(Map.new(@valid), :unknown, true)) ==
             {:error, {:invalid_github_binding, :fields}}

    for {field, value} <- [
          installation_id: 0,
          max_body_bytes: 1_023,
          name: "Not Valid",
          repository_full_name: "missing-owner",
          repository_id: 0,
          ryker_actor_id: 0,
          secret: "short"
        ] do
      attributes = @valid |> Map.new() |> Map.put(field, value)
      assert Binding.new(attributes) == {:error, {:invalid_github_binding, field}}
    end
  end

  test "fails closed without a verified ryker identity" do
    assert Binding.new(Keyword.drop(@valid, [:ryker_actor_id])) ==
             {:error, {:invalid_github_binding, :fields}}
  end
end
