defmodule Ryker.ControlPlane.TemplateHygieneTest do
  # Emisar's `elixir-nil-is-not-an-empty-list`, for the templates Credo cannot
  # read: a `~H` body is a string to it.
  use ExUnit.Case, async: true

  @raw_walk ~r/:for=\{[^}]*<-[^}]*\["[a-z_]+"\]/

  # Emisar's run page walked a stored definition's list that rows saved under
  # an earlier shape did not have, and failed on every render: 49 errors
  # before anyone saw them. The console walks what its projections built; a
  # comprehension over a raw string-keyed subscript would read stored data as
  # if its shape were guaranteed.
  test "a template comprehension walks what a projection built, never a raw subscript" do
    assert Regex.match?(@raw_walk, ~s(<li :for={input <- @runbook.definition["inputs"]}>))

    offenders =
      for path <- Path.wildcard("lib/**/*.ex"),
          {line, number} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          Regex.match?(@raw_walk, line),
          do: "#{path}:#{number}: #{String.trim(line)}"

    assert offenders == []
  end
end
