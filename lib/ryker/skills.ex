defmodule Ryker.Skills do
  @moduledoc "Bundled and locally installed Work skills."
  alias Ryker.CanonicalJSON

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
      (installed |> Map.values() |> Enum.reject(&is_nil/1) |> Enum.sort_by(& &1["name"]))
  end

  defdelegate preview(url), to: Ryker.Skills.GitHub

  @doc "Preview a pasted SKILL.md using the same document format as a GitHub import."
  def preview_paste(document) when is_binary(document) and byte_size(document) > 32_768,
    do: {:error, :skill_too_large}

  def preview_paste(document) do
    with {:ok, skill} <- Ryker.Skills.Document.parse(document) do
      {:ok, Map.put(skill, "origin", "paste")}
    end
  end

  def install(installed, %{"source" => _source} = preview),
    do: Ryker.Skills.GitHub.install(installed, preview)

  def install(installed, %{"origin" => "paste", "name" => name, "document" => document} = preview) do
    cond do
      preview_paste(document) != {:ok, preview} -> {:error, :invalid_skill}
      name in @files or Map.has_key?(installed, name) -> {:error, :skill_name_taken}
      true -> put_document(installed, preview)
    end
  end

  def install(_installed, _preview), do: {:error, :invalid_skill}

  @spec names(map()) :: [String.t()]
  def names(installed), do: Enum.map(catalog(installed), & &1["name"])

  def find(installed, name), do: Enum.find(catalog(installed), &(&1["name"] == name))

  # A nil override hides a bundled procedure on just this installation.
  def remove(installed, name) when name in @files, do: Map.put(installed, name, nil)
  def remove(installed, name), do: Map.delete(installed, name)

  def restore(installed, name) do
    if name in @files and Map.fetch(installed, name) == {:ok, nil},
      do: {:ok, Map.delete(installed, name)},
      else: {:error, :unknown_skill}
  end

  def edit(installed, name, document) do
    with %{} = original <- find(installed, name),
         {:ok, %{"name" => ^name} = edited} <- Ryker.Skills.Document.parse(document) do
      entry = original |> Map.merge(edited) |> Map.put("modified", true)
      put_document(installed, entry)
    else
      _invalid -> {:error, :invalid_skill}
    end
  end

  @doc "Keep the catalog within the installation's storage budget."
  def put_document(installed, skill) do
    updated = Map.put(installed, skill["name"], skill)

    case CanonicalJSON.validate(updated, max_bytes: 96 * 1024) do
      :ok -> {:ok, updated}
      _error -> {:error, :skill_limit}
    end
  end

  @doc "What the model sees before deciding to read a procedure."
  @spec descriptions([map()]) :: [map()]
  def descriptions(skills), do: Enum.map(skills, &Map.drop(&1, ["document", "origin"]))
end
