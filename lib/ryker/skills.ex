defmodule Ryker.Skills do
  @moduledoc "Reviewed Work procedures bundled with this Ryker release."

  # Explicit membership makes adding a procedure a release decision. Only these
  # files are read, at compile time. Tool arguments never select a filesystem path.
  @files ~w(verify-rollout)
  @catalog Enum.map(@files, fn name ->
             path = Path.expand("../../priv/skills/#{name}/SKILL.md", __DIR__)
             @external_resource path
             {:ok, %{"name" => ^name} = skill} =
               path |> File.read!() |> Ryker.Skills.Document.parse()

             skill
           end)

  @doc "Bundled procedures followed by the installation's reviewed imports in name order."
  @spec catalog(map()) :: [map()]
  def catalog(installed) do
    Enum.reject(@catalog, &Map.has_key?(installed, &1["name"])) ++
      Enum.sort_by(Map.values(installed), & &1["name"])
  end

  defdelegate preview(url), to: Ryker.Skills.GitHub

  @spec names(map()) :: [String.t()]
  def names(installed), do: Enum.uniq(@files ++ Map.keys(installed))

  @doc "What the model sees before deciding to read a procedure."
  @spec descriptions([map()]) :: [map()]
  def descriptions(skills), do: Enum.map(skills, &Map.delete(&1, "document"))
end
