defmodule Ryker.CoopFleet.PresetCatalog do
  @moduledoc """
  The Coop recipes approved by the installation operator. Each file is the
  output of `coop presets NAME --export-job`, outside any source checkout.
  New jobs read the current file. A pinned job already carries its contents.
  """
  alias Ryker.Config
  alias Ryker.CoopFleet.JobPreset
  alias Ryker.Maps
  alias Ryker.Settings

  @limit 256 * 1024

  def names do
    with {:ok, root} <- directory(),
         {:ok, files} <- File.ls(root) do
      for file <- files,
          Path.extname(file) == ".json",
          name = Path.rootname(file),
          JobPreset.name?(name),
          regular?(Path.join(root, file)),
          do: name
    else
      _unavailable -> []
    end
    |> Enum.sort()
  end

  def choices(accounts) do
    for name <- names(), {:ok, recipe} <- [resolve(name, accounts, false)] do
      roles = Enum.map(recipe["preset"]["roles"], &Map.take(&1, ~w(name mode targets)))

      %{
        name: name,
        targets: recipe["targets"],
        roles: roles,
        read_only: Enum.all?(roles, &(&1["mode"] != "delegate"))
      }
    end
  end

  # The operator owns the absolute directory. JobPreset.name?/1 allows one basename,
  # and regular?/1 checks the directory entry itself before the bounded read.
  # sobelow_skip ["Traversal.FileModule"]
  def resolve(name, accounts, read_only) do
    with true <- JobPreset.name?(name),
         {:ok, root} <- directory(),
         path = Path.join(root, name <> ".json"),
         true <- regular?(path),
         {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= @limit <-
           File.open(path, [:read, :binary], &IO.binread(&1, @limit + 1)) do
      decode(bytes, name, accounts, read_only)
    else
      _unavailable -> {:error, {:coop_job_preset, name, :unavailable}}
    end
  end

  defp decode(bytes, name, accounts, read_only) do
    with {:ok, %{"preset" => %{"name" => ^name} = preset, "targets" => targets} = document} <-
           Jason.decode(bytes),
         true <- Maps.exact_keys?(document, ~w(preset targets)),
         true <- JobPreset.valid?(Map.put(document, "repository_read_only", read_only)) do
      requested = targets ++ Enum.flat_map(preset["roles"], & &1["targets"])

      if Enum.all?(requested, &(Settings.Work.account(&1) in accounts)),
        do: {:ok, document},
        else: {:error, {:coop_job_preset, name, :account_unavailable}}
    else
      _invalid -> {:error, {:coop_job_preset, name, :invalid}}
    end
  end

  defp directory do
    root = Config.get_env(:coop_job_presets_dir, "/var/lib/ryker/presets")

    if Path.type(root) == :absolute and
         match?({:ok, %File.Stat{type: :directory}}, File.lstat(root)),
       do: {:ok, root},
       else: :unavailable
  end

  defp regular?(path) do
    match?({:ok, %File.Stat{type: :regular, size: size}} when size <= @limit, File.lstat(path))
  end
end
