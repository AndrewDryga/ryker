defmodule Ryker.Settings.CIRepairTest do
  use Ryker.DataCase, async: false
  alias Ryker.Settings

  @actor "control-plane:local"

  test "new repositories require an explicit CI repair choice and reject unknown policies" do
    {:ok, settings} = Settings.initialize(@actor)

    {:ok, settings} =
      Settings.put_repository(
        %{ref: "widget", github_repository: "acme/widget"},
        settings.installation.revision,
        @actor
      )

    repository = Enum.find(settings.repositories, &(&1.ref == "widget"))
    assert repository.github_ci_repair == :off

    for choice <- [:own, :all, :off] do
      {:ok, settings} =
        Settings.put_repository(
          %{ref: "widget", github_ci_repair: choice},
          Settings.fetch!().installation.revision,
          @actor
        )

      assert Enum.find(settings.repositories, &(&1.ref == "widget")).github_ci_repair == choice
    end

    assert {:error, _invalid} =
             Settings.put_repository(
               %{ref: "widget", github_ci_repair: "force"},
               Settings.fetch!().installation.revision,
               @actor
             )
  end
end
