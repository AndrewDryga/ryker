defmodule Responder.GitHub.BindingTest do
  use ExUnit.Case, async: true

  alias Responder.GitHub.Binding

  @valid [
    authorized_actor_ids: [7, 8],
    installation_id: 41,
    name: "github-main",
    repository_full_name: "octo/example",
    repository_id: 99,
    responder_actor_id: 99,
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
          authorized_actor_ids: [],
          installation_id: 0,
          max_body_bytes: 1_023,
          name: "Not Valid",
          repository_full_name: "missing-owner",
          repository_id: 0,
          responder_actor_id: 0,
          secret: "short"
        ] do
      attributes = @valid |> Map.new() |> Map.put(field, value)
      assert Binding.new(attributes) == {:error, {:invalid_github_binding, field}}
    end
  end

  test "fails closed without an authorized actor set and a distinct responder identity" do
    assert Binding.new(Keyword.drop(@valid, [:authorized_actor_ids])) ==
             {:error, {:invalid_github_binding, :fields}}

    assert Binding.new(Keyword.drop(@valid, [:responder_actor_id])) ==
             {:error, {:invalid_github_binding, :fields}}

    assert Binding.new(Keyword.put(@valid, :responder_actor_id, 7)) ==
             {:error, {:invalid_github_binding, :responder_actor_id}}
  end
end
