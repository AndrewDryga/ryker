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

  describe "Ryker.Checks.MultilineAliasGroup" do
    test "flags a grouped alias the formatter expanded across lines" do
      source = """
      defmodule Ryker.Sprockets do
        alias Ryker.ControlPlane.{
          Actions,
          BehaviorLibrary
        }
      end
      """

      assert [issue] = issues(alias_group(), source, @context)
      assert issue.check == alias_group()
      assert issue.line_no == 2
      assert issue.message =~ "single-line grouped aliases"
    end

    test "allows single-line groups and plain aliases" do
      source = """
      defmodule Ryker.Sprockets do
        alias Ryker.ControlPlane.{Actions, BehaviorLibrary, BrowserGuard}
        alias Ryker.ControlPlane.{CSRF, FactsPage, FailureExplanation}
        alias Ryker.Sprockets.Sprocket
      end
      """

      assert issues(alias_group(), source, @context) == []
    end
  end

  describe "Ryker.Checks.MultilineDoColon" do
    test "flags a do: the formatter wrapped onto its own line" do
      source = """
      defmodule Ryker.Sprockets do
        defp reduced?(a, b),
          do:
            not MapSet.subset?(perms(a), perms(b))
      end
      """

      assert [issue] = issues(do_colon(), source, @context)
      assert issue.check == do_colon()
      assert issue.line_no == 3
      assert issue.message =~ "do … end"
    end

    test "allows a fitting one-liner and a do … end block" do
      source = """
      defmodule Ryker.Sprockets do
        defp reduced?(a, b), do: MapSet.subset?(a, b)

        defp perms(role) do
          Enum.sort(role.permissions)
        end
      end
      """

      assert issues(do_colon(), source, @context) == []
    end

    test "reads a documented example as documentation, not as code" do
      source = """
      defmodule Ryker.Sprockets do
        @moduledoc \"""
        The banned shape:

            defp reduced?(a, b),
              do:
                not MapSet.subset?(perms(a), perms(b))
        \"""

        defp reduced?(a, b), do: MapSet.subset?(a, b)
      end
      """

      assert issues(do_colon(), source, @context) == []
    end
  end

  describe "Ryker.Checks.NoBoundTupleReturn" do
    # Until 2026-10-08 about 500 clauses bound a result only to return it, so
    # a reader had to look back at the head to know what came out.
    test "flags a tuple bound only to be returned, alone or inside another" do
      source = """
      defmodule Ryker.Sprockets do
        def spin(result) do
          case result do
            {:error, :lease_lost} = error -> error
            {:error, {:invalid, _field}} = error -> {:halt, error}
            {:ok, _sprocket} = ok when is_tuple(ok) -> ok
          end
        end

        def stop(result) do
          case result do
            {:error, _reason} = error ->
              :telemetry.execute([:stop], %{})
              error
          end
        end
      end
      """

      assert length(issues(bound_tuple(), source, @context)) == 4
    end

    test "allows a restated tuple and a binding passed on to a function" do
      source = """
      defmodule Ryker.Sprockets do
        def spin(result) do
          case result do
            {:error, :lease_lost} -> {:error, :lease_lost}
            {:error, reason} -> {:halt, {:error, reason}}
            {:error, _reason} = error -> retry(error)
          end
        end

        defp retry(error), do: error
      end
      """

      assert issues(bound_tuple(), source, @context) == []
    end
  end

  describe "Ryker.Checks.NoBlankBetweenDirectives" do
    test "flags a blank line sandwiched between two directives" do
      source = """
      defmodule Ryker.Sprockets do
        import Ecto.Query

        alias Ryker.Episodes
      end
      """

      assert [issue] = issues(blank_directives(), source, @context)
      assert issue.check == blank_directives()
      assert issue.line_no == 3
      assert issue.message =~ "contiguous block"
    end

    test "flags a blank line between the moduledoc and the first directive" do
      source = ~S'''
      defmodule Ryker.Sprockets do
        @moduledoc """
        Sprockets.

        alias in prose is not a directive.
        """

        alias Ryker.Episodes
      end
      '''

      assert [issue] = issues(blank_directives(), source, @context)
      assert issue.line_no == 7
      assert issue.message =~ "contiguous block"
    end

    test "allows a moduledoc directly above the header" do
      source = ~S'''
      defmodule Ryker.Sprockets do
        @moduledoc """
        Sprockets.
        """
        @behaviour Ryker.Coop.API
        alias Ryker.Episodes

        @doc """
        Turns.
        """

        def turn, do: :ok
      end
      '''

      assert issues(blank_directives(), source, @context) == []
    end

    test "allows a contiguous header, a why-comment, and the formatter's multi-line blank" do
      source = """
      defmodule Ryker.Sprockets do
        import Ecto.Query
        # The endpoint has to be compiled before the routes it verifies.

        use Phoenix.VerifiedRoutes,
          endpoint: Ryker.ControlPlane.Endpoint

        alias Ryker.Episodes
      end
      """

      assert issues(blank_directives(), source, @context) == []
    end

    test "reads a documented example as documentation, not as code" do
      source = """
      defmodule Ryker.Sprockets do
        @moduledoc \"""
        The banned shape:

            use Ryker.DataCase, async: true

            alias Ryker.Episodes
        \"""
        import Ecto.Query
        alias Ryker.Episodes
      end
      """

      assert issues(blank_directives(), source, @context) == []
    end
  end

  describe "Ryker.Checks.PreferCaptureClosure" do
    test "flags single-call forwarding closures" do
      source = """
      defmodule Ryker.Sprockets do
        def names(sprockets), do: Enum.map(sprockets, fn sprocket -> sprocket.name end)
        def strings(sprockets), do: Enum.map(sprockets, fn sprocket -> to_string(sprocket) end)
        def labels(sprockets), do: Enum.map(sprockets, fn sprocket -> label(sprocket, :short) end)
      end
      """

      assert triggers(capture_closure(), source, @context) == [
               "fn sprocket ->",
               "fn sprocket ->",
               "fn sprocket ->"
             ]

      assert [issue | _] = issues(capture_closure(), source, @context)
      assert issue.check == capture_closure()
      assert issue.message =~ "capture syntax"
    end

    test "allows a capture, a constructor body, a multi-arg closure, and a matching head" do
      source = """
      defmodule Ryker.Sprockets do
        def names(sprockets), do: Enum.map(sprockets, & &1.name)
        def pairs(sprockets), do: Enum.map(sprockets, fn sprocket -> {sprocket.id, sprocket.name} end)
        def sum(sprockets), do: Enum.reduce(sprockets, 0, fn sprocket, acc -> acc + sprocket.size end)
        def matched(sprockets), do: Enum.map(sprockets, fn %Sprocket{name: name} -> name end)
      end
      """

      assert issues(capture_closure(), source, @context) == []
    end

    # The first sweep turned ten-line closures into captures with `&1` buried
    # in a map, and wrote `^&1.id` into Ecto queries (2026-10-06). A capture
    # is for a body that fits on its line.
    test "leaves a body over several lines, a pinned query value and an inner closure alone" do
      source = """
      defmodule Ryker.Sprockets do
        def reset(approvals) do
          Enum.map(approvals, fn approval ->
            update!(approval, %{
              failure_count: 0,
              last_error: nil
            })
          end)
        end

        def load(items, query) do
          Enum.map(items, fn item -> Repo.one(from(row in query, where: row.id == ^item.id)) end)
        end

        def pairs(xs, ys), do: Enum.map(xs, fn x -> Enum.map(ys, fn y -> {x, y} end) end)
      end
      """

      assert issues(capture_closure(), source, @context) == []
    end

    test "flags a closure written over three lines whose body is one" do
      source = """
      defmodule Ryker.Sprockets do
        def scoped(checks, scope) do
          Enum.filter(checks, fn check ->
            Map.get(check, "scope", scope) == scope
          end)
        end
      end
      """

      assert triggers(capture_closure(), source, @context) == ["fn check ->"]
    end
  end

  describe "Ryker.Checks.NoIfOnArgField" do
    test "flags a closure dispatching on its argument's field truthiness" do
      source = """
      defmodule Ryker.Sprockets do
        def labels(sprockets) do
          Enum.map(sprockets, fn sprocket ->
            if sprocket.name, do: sprocket.name, else: "unnamed"
          end)
        end
      end
      """

      assert [issue] = issues(if_on_arg_field(), source, @context)
      assert issue.check == if_on_arg_field()
      assert issue.trigger == "if sprocket.name"
      assert issue.line_no == 3
      assert issue.message =~ "function clause heads"
    end

    test "allows a captured two-clause function and a genuinely computed condition" do
      source = """
      defmodule Ryker.Sprockets do
        def labels(sprockets), do: Enum.map(sprockets, &label/1)

        def sizes(sprockets) do
          Enum.map(sprockets, fn sprocket ->
            if Enum.empty?(sprocket.tags), do: 0, else: length(sprocket.tags)
          end)
        end

        defp label(%Sprocket{name: nil}), do: "unnamed"
        defp label(%Sprocket{name: name}), do: name
      end
      """

      assert issues(if_on_arg_field(), source, @context) == []
    end
  end

  defp if_on_arg_field, do: check("NoIfOnArgField")
  defp acronym, do: check("AcronymModuleCase")
  defp alias_group, do: check("MultilineAliasGroup")
  defp do_colon, do: check("MultilineDoColon")
  defp blank_directives, do: check("NoBlankBetweenDirectives")
  defp bound_tuple, do: check("NoBoundTupleReturn")
  defp capture_closure, do: check("PreferCaptureClosure")
  defp pipe_in_branch_head, do: check("NoPipeInBranchHead")
  defp short_bindings, do: check("ShortBindings")
end
