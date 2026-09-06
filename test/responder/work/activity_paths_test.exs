defmodule Responder.Work.ActivityPathsTest do
  use ExUnit.Case, async: true
  alias Responder.Work.ActivityPaths

  test "only bounded relative path facts cross the worker display boundary" do
    # A checkout root is worker-private. The timeline needs relative files and
    # outside warnings, not guessed roots or arbitrary worker payload fields.
    context = %{
      "basis" => "lexical",
      "root" => "/private/worker/checkout",
      "paths" => [
        %{"source" => "/locations/0/path", "scope" => "project", "path" => "lib/a.ex"},
        %{"source" => "/input/path", "scope" => "outside", "path" => "/private/secret"}
      ]
    }

    assert ActivityPaths.sanitize(context) == %{
             "basis" => "lexical",
             "paths" => [
               %{"source" => "/locations/0/path", "scope" => "project", "path" => "lib/a.ex"},
               %{"source" => "/input/path", "scope" => "outside"}
             ]
           }

    for path <- [
          "/private/secret",
          "../secret",
          "a/../secret",
          "C:\\secret",
          "file:/host/secret",
          "vscode-remote:host/secret",
          "~/.ssh",
          "bad\npath"
        ] do
      invalid = put_in(context, ["paths", Access.at(0), "path"], path)
      assert ActivityPaths.sanitize(invalid)["partial"]
      refute inspect(ActivityPaths.sanitize(invalid)) =~ path
    end

    assert ActivityPaths.sanitize(nil) == nil
    assert ActivityPaths.sanitize(%{"basis" => "guessed", "paths" => []}) == nil
  end

  test "path limits and unsupported shapes remain explicit instead of guessed" do
    item = %{"source" => "/input/path", "scope" => "project", "path" => "lib/a.ex"}
    result = ActivityPaths.sanitize(%{"basis" => "lexical", "paths" => List.duplicate(item, 17)})
    assert length(result["paths"]) == 16
    assert result["partial"]

    for invalid <- [%{}, "path", Map.put(item, "source", "/private/secret")] do
      result = ActivityPaths.sanitize(%{"basis" => "lexical", "paths" => [invalid]})
      assert result == %{"basis" => "lexical", "paths" => [], "partial" => true}
    end
  end
end
