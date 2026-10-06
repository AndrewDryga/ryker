defmodule Ryker.CredoChecks.StyleChecksTest do
  # Fixture coverage for the house style checks: acronym casing, pipes in
  # branch heads and spelled-out bindings. Each gets a probe it must flag and
  # a compliant probe it must not.
  use ExUnit.Case, async: true

  import Ryker.CredoCheckProbe

  @context "lib/ryker/sprockets.ex"

  setup_all do
    load()
  end

  describe "Ryker.Checks.AcronymModuleCase" do
    test "flags a CamelCased acronym in a module name" do
      source = """
      defmodule Ryker.Delivery.Json.Client do
      end
      """

      assert [issue] = issues(acronym(), source, @context)
      assert issue.check == acronym()
      assert issue.trigger == "Json"
      assert issue.line_no == 1
      assert issue.message =~ "JSON"
    end

    test "flags every miscased acronym segment in an alias" do
      source = """
      defmodule Ryker.Sprockets do
        alias Ryker.Coop.Acp.Http
        alias Ryker.StateTools.Mcp
      end
      """

      assert triggers(acronym(), source, @context) == ["Acp", "Http", "Mcp"]
    end

    test "allows all-caps acronyms and snake_case identifiers" do
      source = """
      defmodule Ryker.Delivery.JSONClient do
        alias Ryker.CoopFleet.ACP.HTTP
        alias Ryker.StateTools.MCP

        def path, do: "/v1/mcp"
        def body(json_body), do: json_body
      end
      """

      assert issues(acronym(), source, @context) == []
    end
  end

  describe "Ryker.Checks.NoPipeInBranchHead" do
    test "flags a pipe in a with, for and case head" do
      source = """
      defmodule Ryker.Sprockets do
        def fetch(id) do
          with {:ok, sprocket} <- id |> by_id() |> Repo.one() do
            {:ok, sprocket}
          end
        end

        def ids, do: for(sprocket <- all() |> Repo.all(), do: sprocket.id)

        def kind(queryable) do
          case queryable |> Repo.all() do
            [] -> :empty
            _rows -> :some
          end
        end
      end
      """

      assert triggers(pipe_in_branch_head(), source, @context) == ["<-", "<-", "case"]
      assert [issue | _] = issues(pipe_in_branch_head(), source, @context)
      assert issue.check == pipe_in_branch_head()
      assert issue.message =~ "bind the pipeline to a name"
    end

    test "allows a pipeline bound above the head, or with `=` inside it" do
      source = """
      defmodule Ryker.Sprockets do
        def fetch(id) do
          queryable = id |> by_id() |> lock()

          with {:ok, sprocket} <- Repo.one(queryable),
               name = sprocket.name |> String.trim() |> String.downcase(),
               {:ok, label} <- label(name) do
            {:ok, label}
          end
        end
      end
      """

      assert issues(pipe_in_branch_head(), source, @context) == []
    end

    test "ignores test sources" do
      source = """
      defmodule Ryker.SprocketsTest do
        def kind(queryable) do
          case queryable |> Repo.all() do
            [] -> :empty
            _rows -> :some
          end
        end
      end
      """

      assert issues(pipe_in_branch_head(), source, "test/ryker/sprockets_test.exs") == []
    end
  end

  describe "Ryker.Checks.ShortBindings" do
    test "flags abbreviated parameters, assignments and DSL bindings" do
      source = """
      defmodule Ryker.Sprockets do
        def apply_changes(cs, attrs) do
          q = all()
          Repo.all(q, attrs)
        end

        def scoped(queryable) do
          where(queryable, [group_members: gm], gm.account_id == ^1)
        end
      end
      """

      found = issues(short_bindings(), source, @context)

      assert found |> Enum.map(& &1.trigger) |> Enum.sort() == ["cs", "gm", "q"]
      assert Enum.all?(found, &(&1.check == short_bindings()))
      assert Enum.find(found, &(&1.trigger == "cs")).message =~ "spell the binding out"
      assert Enum.find(found, &(&1.trigger == "gm")).message =~ "single letter"
    end

    test "allows spelled-out names and a single-letter DSL binding" do
      source = """
      defmodule Ryker.Sprockets do
        def apply_changes(changeset, attrs) do
          queryable = all()
          Repo.all(queryable, attrs)
        end

        def scoped(queryable) do
          where(queryable, [group_members: g], g.account_id == ^1)
        end
      end
      """

      assert issues(short_bindings(), source, @context) == []
    end
  end

  defp acronym, do: check("AcronymModuleCase")
  defp pipe_in_branch_head, do: check("NoPipeInBranchHead")
  defp short_bindings, do: check("ShortBindings")
end
