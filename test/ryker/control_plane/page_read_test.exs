defmodule Ryker.ControlPlane.PageReadTest do
  @moduledoc """
  What every part of a console page asks for, read once a page read.
  """
  use Ryker.DataCase, async: true
  alias Ryker.ControlPlane.{ConsolePeople, PageRead, RepositoryNames, SettingsView}
  alias Ryker.QueryWork
  alias Ryker.Settings

  @people ~w(tailscale:andrew@example.com tailscale:dev@example.com cloudflare:ops@tenant.example)

  # Each part of a page asked again: the shell, the page and its header each
  # read the settings view, about 40 queries; each list read every
  # repository's name; and a page named each person with a query a row
  # (2026-10-04 review).
  test "a page read reads what its parts share once" do
    {:ok, _snapshot} = Settings.initialize("control-plane:local")

    {names, statements} =
      QueryWork.statements(fn ->
        PageRead.run(fn ->
          for _part <- 1..3 do
            {:ok, _view} = SettingsView.fetch()
            RepositoryNames.all()
          end

          for login <- @people, do: ConsolePeople.person("control_plane:user:" <> login).name
        end)
      end)

    assert names == @people |> Enum.map(&(&1 |> String.split(":", parts: 2) |> List.last()))
    assert QueryWork.count(statements, "integration_credentials") == 1
    assert QueryWork.count(statements, "removed_repository_names") == 1
    assert QueryWork.count(statements, "control_plane_people") == 1
  end

  test "outside a page read every read is fresh" do
    {_names, statements} =
      QueryWork.statements(fn ->
        RepositoryNames.all()
        RepositoryNames.all()
      end)

    assert QueryWork.count(statements, "removed_repository_names") == 2
  end
end
