defmodule Ryker.ControlPlane.ContextSearchDesignTest do
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.ContextSearch

  test "full search details keep inspection secrets and signed URL parameters out of the browser" do
    # Expanding the formerly clipped query must not bypass the redaction used
    # by the adjacent original prompt. The raw search record shares that boundary.
    query = "https://example.com/alerts/" <> String.duplicate("a", 80)

    receipt = %{
      "identifiers" => [query <> "?token=private-query#private-fragment"],
      "lanes" => %{"identity" => %{"returned" => 0}},
      "password" => "private-password"
    }

    search = ContextSearch.present(%{"routing_receipt" => receipt})
    assert Enum.find(search.methods, &(&1.key == "identity")).used == [query]
    refute search.record =~ "private-query"
    refute search.record =~ "private-fragment"
    refute search.record =~ "private-password"
  end

  test "search queries retain full identifiers instead of display truncation" do
    query = "https://example.com/monitoring/alerting/alerts/" <> String.duplicate("a", 80)

    search =
      ContextSearch.present(%{
        "routing_receipt" => %{
          "identifiers" => [query],
          "lanes" => %{"identity" => %{"returned" => 0}}
        }
      })

    assert Enum.find(search.methods, &(&1.key == "identity")).used == [query]
  end

  test "each method carries actual offered counts and recorded exclusion reasons" do
    first = "018f0000-0000-7000-8000-000000000001"
    second = "018f0000-0000-7000-8000-000000000002"

    snapshot = %{
      "candidates" => [%{"episode_id" => first, "digest" => %{"title" => "Gateway errors"}}],
      "routing_receipt" => %{
        "examined" => 2,
        "offered" => 1,
        "omitted" => 1,
        "lanes" => %{"text" => %{"returned" => 2}, "thread" => %{"returned" => 1}},
        "selection" => %{
          "version" => 1,
          "limit" => 20,
          "reserved" => 0,
          "items" => [
            %{
              "episode_id" => first,
              "lanes" => ["text", "thread"],
              "offered" => true,
              "reason" => "ranked"
            },
            %{
              "episode_id" => second,
              "lanes" => ["text"],
              "offered" => false,
              "reason" => "weak_match"
            }
          ]
        }
      }
    }

    search =
      ContextSearch.present(snapshot)

    wording = Enum.find(search.methods, &(&1.name == "Similar wording"))
    assert wording.found == 2
    assert wording.offered == 1
    assert Enum.map(wording.results, & &1.title) == ["Gateway errors", "Request 00000002"]
    assert List.last(wording.results).reason == "Not closely enough related to this message."
    assert hd(wording.results).href =~ first
    assert List.last(wording.results).href == nil
    assert search.record =~ "weak_match"
    refute Enum.any?(search.facts, &(elem(&1, 0) == "Result"))

    assert {"Routing options",
            "Up to 20 options; 0 places reserved for supported matches outside this thread."} in search.facts
  end

  test "old counts do not become invented per-method zero offers or inferred exclusions" do
    search =
      ContextSearch.present(%{
        "routing_receipt" => %{
          "lanes" => %{"text" => %{"returned" => 3}},
          "offered" => 1,
          "examined" => 3
        }
      })

    wording = Enum.find(search.methods, &(&1.name == "Similar wording"))
    assert wording.offered == nil
    assert wording.results == []
  end

  test "unrecognized selection records preserve historical counts instead of crashing" do
    for selection <- [
          [],
          "old shape",
          false,
          %{"version" => 2},
          %{"version" => 1, "ineligible" => []}
        ] do
      search =
        ContextSearch.present(%{
          "routing_receipt" => %{
            "lanes" => %{"text" => %{"returned" => 3}},
            "selection" => selection
          }
        })

      method = Enum.find(search.methods, &(&1.key == "text"))
      assert method.found == 3
      assert method.offered == nil
      assert method.ineligible == nil
    end
  end

  test "source ownership and scope exclusions remain inspectable without exposing excluded sources" do
    search =
      ContextSearch.present(%{
        "routing_receipt" => %{
          "lanes" => %{"text" => %{"returned" => 1}},
          "selection" => %{
            "version" => 1,
            "ineligible" => %{"text" => 1},
            "items" => [
              %{
                "episode_id" => "owner",
                "lanes" => ["source_owner"],
                "offered" => true,
                "reason" => "source_owner"
              }
            ]
          }
        }
      })

    owner = Enum.find(search.methods, &(&1.key == "source_owner"))
    assert owner.found == 1
    assert owner.offered == 1
    assert length(owner.results) == 1
    assert Enum.find(search.methods, &(&1.key == "text")).ineligible == 1
  end

  test "an unavailable source never acquires a current title or inspection link" do
    id = "018f0000-0000-7000-8000-000000000003"

    search =
      ContextSearch.present(%{
        "candidates" => [%{"episode_id" => id, "digest" => %{"title" => "Private source text"}}],
        "routing_receipt" => %{
          "lanes" => %{"text" => %{"returned" => 1}},
          "selection" => %{
            "version" => 1,
            "items" => [
              %{
                "episode_id" => id,
                "lanes" => ["text"],
                "offered" => false,
                "reason" => "source_unavailable"
              }
            ]
          }
        }
      })

    [result] = Enum.find(search.methods, &(&1.name == "Similar wording")).results
    assert result.href == nil
    refute result.title =~ "Private source text"
    assert result.reason == "Its source was not available to this request."
  end
end
