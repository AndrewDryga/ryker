defmodule Ryker.Settings.Environment do
  @moduledoc """
  A named bundle of what work in it may use.

  Its repositories are a set: every session in the environment mounts all of
  them, the one its work changes as the working copy and every other one
  read-only under its own ref. Each repository is read and write, which a
  task may change, or read only, which work only reads (Andrew, 2026-09-27:
  "can we here limit read or read/write access per repo?"). Each piece of
  work chooses the read and write repository it changes; the default, the
  first, is the one it changes unless it picks another, so the default is
  always read and write. It may name one Emisar account. At most one
  environment is the default, which Chat and every conversation without its
  own setting use. Slack channels and webhook sources select an environment;
  GitHub events run in the environment `for_repository/2` names.

  Writes take `repositories` as a list of repository refs, the default first,
  and `access` as a map of repository ref to `:read_only` or `:read_write`. A
  repository `access` does not name keeps the access it has; one new to the
  environment is read and write, as every repository was before access could
  be limited. The snapshot carries them as
  `%EnvironmentRepository{repository_ref, position, access}` rows, the
  default first.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Ryker.Repo
  alias Ryker.Settings.{EnvironmentRepository, Validation}

  @primary_key {:ref, :string, autogenerate: false}
  @fields ~w(ref display_name description emisar_connection_ref is_default parallel_goal_limit repositories access)a
  @ref ~r/\A[a-z0-9][a-z0-9-]{0,63}\z/
  # Coop mounts a read-only repository under its own name: 1 to 48 characters,
  # never "primary", and at most 32 of them beside the working copy. In an
  # environment with several repositories any of them may be mounted that way.
  @companion ~r/\A[a-z0-9][a-z0-9_-]{0,47}\z/
  @maximum_repositories 33

  @type t :: %__MODULE__{
          ref: String.t(),
          display_name: String.t(),
          description: String.t() | nil,
          emisar_connection_ref: String.t() | nil,
          is_default: boolean(),
          parallel_goal_limit: 1..3,
          repositories: [EnvironmentRepository.t()]
        }

  schema "environment_settings" do
    field(:display_name, :string)
    field(:description, :string)
    field(:emisar_connection_ref, :string)
    field(:is_default, :boolean, default: false)
    field(:parallel_goal_limit, :integer, default: 3)
    # The repositories a save writes, the default first: [{ref, access}].
    field(:repository_rows, {:array, :any}, virtual: true)

    has_many(:repositories, EnvironmentRepository,
      foreign_key: :environment_ref,
      references: :ref,
      preload_order: [asc: :position]
    )

    timestamps(type: :utc_datetime_usec)
  end

  def fields, do: @fields
  def ref_pattern, do: @ref
  def new(_snapshot), do: %__MODULE__{repositories: []}
  def find(snapshot, :ref, ref), do: Enum.find(snapshot.environments, &(&1.ref == ref))

  @doc "The default environment of a settings snapshot, or nil when none is chosen."
  @spec default(map()) :: t() | nil
  def default(snapshot), do: Enum.find(snapshot.environments, & &1.is_default)

  @doc "The environment's repository refs, the default first."
  @spec repository_refs(t()) :: [String.t()]
  def repository_refs(%__MODULE__{repositories: repositories}),
    do: Enum.map(repositories, & &1.repository_ref)

  @doc "The repositories a task in the environment may change, the default first."
  @spec writable_refs(t()) :: [String.t()]
  def writable_refs(%__MODULE__{repositories: repositories}),
    do: for(%{access: :read_write} = row <- repositories, do: row.repository_ref)

  @doc "The repositories work in the environment only reads."
  @spec read_only_refs(t()) :: [String.t()]
  def read_only_refs(%__MODULE__{repositories: repositories}),
    do: for(%{access: :read_only} = row <- repositories, do: row.repository_ref)

  @doc """
  The environment GitHub events for a repository run in.

  The first environment (by ref) whose default repository it is, else the
  first that may change it, else the first that holds it, else nil: the
  repository then runs on its own.
  """
  @spec for_repository([t()], String.t()) :: t() | nil
  def for_repository(environments, repository_ref) do
    ordered = Enum.sort_by(environments, & &1.ref)

    Enum.find(ordered, &(List.first(repository_refs(&1)) == repository_ref)) ||
      Enum.find(ordered, &(repository_ref in writable_refs(&1))) ||
      Enum.find(ordered, &(repository_ref in repository_refs(&1)))
  end

  def changeset(current, attributes, snapshot) do
    {repositories, attributes} = Map.pop(attributes, :repositories)
    {access, attributes} = Map.pop(attributes, :access)

    current
    |> cast(attributes, @fields -- [:repositories, :access])
    |> validate_required([:ref, :display_name, :is_default, :parallel_goal_limit])
    |> validate_format(:ref, @ref)
    |> validate_length(:display_name, min: 1, max: 80)
    |> validate_length(:description, min: 1, max: 500)
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

    if taken?,
      do:
        add_error(changeset, :display_name, "is used by another environment", validation: :taken),
      else: changeset
  end

  defp comparable_name(name) when is_binary(name), do: name |> String.trim() |> String.downcase()
  defp comparable_name(_name), do: nil

  defp put_repositories(changeset, nil, nil, _current, _snapshot), do: changeset

  defp put_repositories(changeset, nil, access, current, snapshot),
    do: put_repositories(changeset, repository_refs(current), access, current, snapshot)

  defp put_repositories(changeset, refs, access, current, snapshot) do
    cond do
      not ordered_list?(refs) ->
        add_error(changeset, :repositories, "must be a unique ordered list", validation: :list)

      not known_repositories?(refs, snapshot) ->
        add_error(changeset, :repositories, "names an unknown repository",
          validation: :unknown_repository
        )

      not mountable_together?(refs) ->
        add_error(changeset, :repositories, "names a repository Coop cannot mount read-only",
          validation: :companion_name
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

  defp put_rows([{_default, :read_only} | _rest], changeset, _current),
    do:
      add_error(changeset, :access, "the default repository has to be read and write",
        validation: :default_read_only
      )

  defp put_rows(rows, changeset, current) do
    if rows == Enum.map(current.repositories, &{&1.repository_ref, &1.access}),
      do: changeset,
      else: put_change(changeset, :repository_rows, rows)
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

  # With several repositories any of them may be mounted read-only beside the
  # one a task changes; alone, a repository is always the working copy.
  defp mountable_together?([_alone]), do: true
  defp mountable_together?(refs), do: Enum.all?(refs, &companion?/1)

  defp companion?(ref), do: ref != "primary" and Regex.match?(@companion, ref)

  @doc """
  An environment a Slack channel or a webhook source selects is refused, and
  the refusal counts who selects it. Channels live in the Slack tables, so they
  are counted there rather than read from the settings snapshot.
  """
  def deletable(environment, snapshot) do
    channels =
      Repo.aggregate(
        from(configuration in "slack_channel_configurations",
          where: configuration.environment_ref == ^environment.ref
        ),
        :count
      )

    webhook_sources =
      Enum.count(snapshot.webhook_sources, &(&1.environment_ref == environment.ref))

    if channels + webhook_sources == 0,
      do: :ok,
      else:
        {:error, [ref: {:referenced, %{channels: channels, webhook_sources: webhook_sources}}]}
  end
end
