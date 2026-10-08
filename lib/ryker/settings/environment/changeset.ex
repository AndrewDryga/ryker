defmodule Ryker.Settings.Environment.Changeset do
  @moduledoc """
  Adding an environment and changing a saved one (`Ryker.Settings.Environment`).

  A save takes `repositories` as a list of repository refs, the default
  first, and `access` as a map of repository ref to `:read_only` or
  `:read_write`. A repository `access` does not name keeps the access it
  has; one new to the environment is read and write, as every repository was
  before access could be limited.
  """
  @behaviour Ryker.Settings.Section.Changeset
  use Ryker, :changeset
  alias Ryker.Settings.{Environment, Validation}

  @fields ~w(ref display_name description emisar_connection_ref is_default parallel_goal_limit repositories access)a
  # A save's repositories and their access become rows (`repository_rows`);
  # neither is a column to cast.
  @cast_fields @fields -- [:repositories, :access]
  # Coop mounts a read-only repository under its own name: 1 to 48 characters,
  # never "primary", and at most 32 of them beside the working copy. A writable
  # repository needs that name only if another writable one can take its place.
  @companion ~r/\A[a-z0-9][a-z0-9_-]{0,47}\z/
  @maximum_repositories 33

  @impl true
  def fields, do: @fields

  @impl true
  def insert(attributes, snapshot),
    do: changeset(%Environment{repositories: []}, attributes, snapshot)

  @impl true
  def update(%Environment{} = environment, attributes, snapshot),
    do: changeset(environment, attributes, snapshot)

  defp changeset(current, attributes, snapshot) do
    {repositories, attributes} = Map.pop(attributes, :repositories)
    {access, attributes} = Map.pop(attributes, :access)

    current
    |> cast(attributes, @cast_fields)
    |> validate_required([:ref, :display_name, :is_default, :parallel_goal_limit])
    |> validate_format(:ref, Environment.ref_pattern())
    |> validate_length(:display_name, min: 1, max: 80, count: :codepoints)
    |> validate_length(:description, min: 1, max: 500, count: :codepoints)
    |> Validation.validate_known(
      :emisar_connection_ref,
      Enum.map(snapshot.emisar_connections, & &1.ref),
      :unknown_connection
    )
    |> validate_inclusion(:parallel_goal_limit, 1..3)
    |> validate_unique_name(snapshot)
    |> put_repositories(repositories, access, current, snapshot)
  end

  # Chat's picker, channel settings and every list name an environment by its
  # name alone, so two with one name could not be told apart (manual testing,
  # 2026-09-26, found a second "Production" saved beside the first).
  defp validate_unique_name(changeset, snapshot) do
    ref = get_field(changeset, :ref)
    name = comparable_name(get_field(changeset, :display_name))

    taken? =
      name != nil and
        Enum.any?(
          snapshot.environments,
          &(&1.ref != ref and comparable_name(&1.display_name) == name)
        )

    if taken? do
      add_error(changeset, :display_name, "is used by another environment", validation: :taken)
    else
      changeset
    end
  end

  defp comparable_name(name) when is_binary(name), do: name |> String.trim() |> String.downcase()
  defp comparable_name(_name), do: nil

  defp put_repositories(changeset, nil, nil, _current, _snapshot), do: changeset

  defp put_repositories(changeset, nil, access, current, snapshot) do
    put_repositories(changeset, Environment.repository_refs(current), access, current, snapshot)
  end

  defp put_repositories(changeset, refs, access, current, snapshot) do
    cond do
      not ordered_list?(refs) ->
        add_error(changeset, :repositories, "must be a unique ordered list", validation: :list)

      not known_repositories?(refs, snapshot) ->
        add_error(changeset, :repositories, "names an unknown repository",
          validation: :unknown_repository
        )

      true ->
        put_access(changeset, refs, access, current)
    end
  end

  # Each repository's access as the write names it, else as the environment
  # has it, else read and write; the default has to be read and write.
  defp put_access(changeset, refs, access, current) do
    case named_access(access, refs) do
      {:ok, named} ->
        held = Map.new(current.repositories, &{&1.repository_ref, &1.access})

        refs
        |> Enum.map(&{&1, Map.get(named, &1) || Map.get(held, &1) || :read_write})
        |> put_rows(changeset, current)

      {:error, reason} ->
        add_error(changeset, :access, "must give each repository of the environment an access",
          validation: reason
        )
    end
  end

  defp put_rows([{_default, :read_only} | _rest], changeset, _current) do
    add_error(changeset, :access, "the default repository has to be read and write",
      validation: :default_read_only
    )
  end

  defp put_rows(rows, changeset, current) do
    cond do
      not mountable_together?(rows) ->
        add_error(changeset, :repositories, "names a repository Coop cannot mount read-only",
          validation: :companion_name
        )

      rows == Enum.map(current.repositories, &{&1.repository_ref, &1.access}) ->
        changeset

      true ->
        put_change(changeset, :repository_rows, rows)
    end
  end

  defp named_access(nil, _refs), do: {:ok, %{}}

  defp named_access(access, refs) when is_map(access) do
    Enum.reduce_while(access, {:ok, %{}}, fn {ref, value}, {:ok, named} ->
      case {ref in refs, cast_access(value)} do
        {false, _access} -> {:halt, {:error, :unknown_repository}}
        {true, nil} -> {:halt, {:error, :access}}
        {true, access} -> {:cont, {:ok, Map.put(named, ref, access)}}
      end
    end)
  end

  defp named_access(_access, _refs), do: {:error, :access}

  defp cast_access(value) when value in [:read_only, :read_write], do: value
  defp cast_access("read_only"), do: :read_only
  defp cast_access("read_write"), do: :read_write
  defp cast_access(_value), do: nil

  defp ordered_list?(refs),
    do: is_list(refs) and Enum.uniq(refs) == refs and length(refs) <= @maximum_repositories

  defp known_repositories?(refs, snapshot) do
    known = MapSet.new(snapshot.repositories, & &1.ref)
    Enum.all?(refs, &(is_binary(&1) and MapSet.member?(known, &1)))
  end

  # A repository is a companion only when a different writable one is chosen.
  defp mountable_together?(rows) do
    writable = for {ref, :read_write} <- rows, do: ref
    Enum.all?(rows, fn {ref, _access} -> writable == [ref] or companion?(ref) end)
  end

  defp companion?(ref), do: ref != "primary" and Regex.match?(@companion, ref)
end
