defmodule Ryker.LocalRouting.SchemaTest do
  use ExUnit.Case, async: true

  alias Ryker.Admission.Decision
  alias Ryker.Fixtures.LocalRouting, as: Harvested
  alias Ryker.LocalRouting.Schema

  @fields ~w(action episode_ref messages reactions reason relation repository repository_source work_class)
  @actions [:start_episode, :continue_episode, :reply, :quick_reply, :react, :ignore]

  # Routing's contract states its fields once and each allowed shape of a
  # decision beside them in a top-level oneOf. A grammar-constrained local
  # server (llama.cpp under Ollama) builds its grammar from the oneOf alone,
  # so each shape would lose the fields it does not repeat: the reason among
  # them, and every answer would come back without one and be refused. Each
  # shape is sent whole instead.
  test "each shape of a routing decision is sent as a whole object a local grammar can hold" do
    local = Schema.local(Decision.json_schema(@actions, :any, true, ["acme-api", "acme-web"]))

    assert Map.keys(local) == ["anyOf"]
    assert length(local["anyOf"]) == 9

    for shape <- local["anyOf"] do
      assert shape["type"] == "object"
      assert shape["additionalProperties"] == false
      assert Enum.sort(shape["required"]) == @fields
      assert Enum.sort(Map.keys(shape["properties"])) == @fields
    end

    # Text patterns and one-of choices are what local grammars refuse or
    # misread; routing's own checks enforce both on every answer anyway.
    refute inspect(local) =~ "pattern"
    refute inspect(local) =~ "oneOf"
    refute inspect(local) =~ "$schema"
  end

  # A contract routing may publish later without shapes beside its fields is
  # still sent, made portable, rather than stopping every comparison.
  test "a contract of any other shape is sent as it is, without what local grammars misread" do
    contract = %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "type" => "object",
      "properties" => %{
        "pattern" => %{"type" => "string", "pattern" => "^[a-z]+$"},
        "kind" => %{"oneOf" => [%{"const" => "a"}, %{"const" => "b"}]}
      },
      "required" => ["pattern", "kind"]
    }

    assert Schema.local(contract) == %{
             "type" => "object",
             "properties" => %{
               "pattern" => %{"type" => "string"},
               "kind" => %{"anyOf" => [%{"const" => "a"}, %{"const" => "b"}]}
             },
             "required" => ["pattern", "kind"]
           }
  end

  test "the local contract takes every real decision routing's contract takes, and refuses its shapes" do
    contract = Decision.json_schema(@actions, :any, false, [])
    routing = JSV.build!(contract)
    local = JSV.build!(Schema.local(contract))

    for answer <- [
          Harvested.hi_quick_reply(),
          Harvested.hi_again_quick_reply(),
          Harvested.deploy_script_reply()
        ] do
      document = Jason.decode!(answer)
      assert {:ok, _} = JSV.validate(document, routing, cast: false)
      assert {:ok, _} = JSV.validate(document, local, cast: false)
    end

    quick = Jason.decode!(Harvested.hi_quick_reply())

    for refused <- [
          Jason.decode!(Harvested.hi_again_old_contract()),
          Map.delete(quick, "reason"),
          %{quick | "work_class" => "standard"},
          %{quick | "messages" => nil},
          %{quick | "action" => "reply"}
        ] do
      assert {:error, _} = JSV.validate(refused, routing, cast: false)
      assert {:error, _} = JSV.validate(refused, local, cast: false)
    end
  end
end
