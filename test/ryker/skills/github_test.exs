defmodule Ryker.Skills.GitHubTest do
  use ExUnit.Case, async: true
  alias Ryker.Skills.{Document, GitHub}

  test "unsupported origins and paths are refused before any request" do
    Ryker.Config.put_override(:public_skill_reader, fn _, _, _ -> flunk("unexpected request") end)

    for url <- [
          "http://github.com/org/repo",
          "https://github.com.other.test/org/repo",
          "https://github.com@other.test/org/repo",
          "https://github.com:8080/org/repo",
          "https://github.com/org/repo/blob/main/README.md",
          "https://github.com/org/repo/tree/main/../folder"
        ] do
      assert GitHub.preview(url) == {:error, :invalid_url}
    end
  end

  test "an import cannot replace a bundled or unrelated skill; a reviewed update can replace the same file" do
    document = File.read!("priv/skills/verify-rollout/SKILL.md")
    {:ok, bundled} = Document.parse(document)
    sha = String.duplicate("a", 40)
    source = "https://github.com/example/runbooks/blob/#{sha}/SKILL.md"
    assert GitHub.install(%{}, Map.put(bundled, "source", source)) == {:error, :skill_name_taken}
    {:ok, skill} = Document.parse(String.replace(document, "verify-rollout", "check-release"))
    imported = Map.put(skill, "source", source)
    assert {:ok, installed} = GitHub.install(%{}, imported)

    assert GitHub.install(installed, %{
             imported
             | "source" => String.replace(source, "example", "other")
           }) == {:error, :skill_name_taken}

    updated = %{imported | "source" => String.replace(source, sha, String.duplicate("b", 40))}
    assert GitHub.install(installed, updated) == {:ok, %{"check-release" => updated}}

    assert GitHub.install(installed, %{imported | "document" => document}) ==
             {:error, :invalid_skill}

    assert Document.parse("---\nname: &name alias\ndescription: *name\n---\nText") ==
             {:error, :invalid_skill}
  end
end
