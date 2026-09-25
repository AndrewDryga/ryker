defmodule Ryker.Settings.Environment do
  @moduledoc """
  A named bundle of what work in it may use.

  Its repositories are ordered: work in the environment changes the first one
  and mounts every other one read-only under its own ref. It may name one
  Emisar account. At most one environment is the default, which Chat and every
  conversation without its own setting use. Slack channels and webhook sources
  select an environment; GitHub events run in the environment `for_repository/2`
  names.

  Writes take `repositories` as an ordered list of repository refs. The
  snapshot carries them as `%EnvironmentRepository{repository_ref, position}`
  rows ordered by position.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Ryker.Repo
  alias Ryker.Settings.{EnvironmentRepository, Validation}

  @primary_key {:ref, :string, autogenerate: false}
  @fields ~w(ref display_name description emisar_connection_ref is_default parallel_goal_limit repositories)a
  @ref ~r/\A[a-z0-9][a-z0-9-]{0,63}\z/
  # Coop mounts a read-only repository under its own name: 1 to 48 characters,
  # never "primary", and at most 32 of them beside the writable one.
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
    field(:repository_refs, {:array, :string}, virtual: true)

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

  @doc "The environment's repository refs in order; the first is the one work changes."
  @spec repository_refs(t()) :: [String.t()]
  def repository_refs(%__MODULE__{repositories: repositories}),
    do: Enum.map(repositories, & &1.repository_ref)

  @doc "The repository work in the environment changes, or nil for an environment without one."
  @spec writable_repository(t()) :: String.t() | nil
  def writable_repository(environment), do: environment |> repository_refs() |> List.first()

  @doc "The repositories work in the environment only reads."
  @spec read_only_repositories(t()) :: [String.t()]
  def read_only_repositories(environment), do: environment |> repository_refs() |> Enum.drop(1)

  @doc """
  The environment GitHub events for a repository run in.

  The first environment (by ref) whose writable repository it is, else the
  first that reads it, else nil: the repository then runs on its own.
  """
  @spec for_repository([t()], String.t()) :: t() | nil
  def for_repository(environments, repository_ref) do
    ordered = Enum.sort_by(environments, & &1.ref)

    Enum.find(ordered, &(writable_repository(&1) == repository_ref)) ||
      Enum.find(ordered, &(repository_ref in repository_refs(&1)))
  end

  def changeset(current, attributes, snapshot) do
    {repositories, attributes} = Map.pop(attributes, :repositories)

    current
    |> cast(attributes, @fields -- [:repositories])
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
    |> put_repositories(repositories, current, snapshot)
  end

  defp put_repositories(changeset, nil, _current, _snapshot), do: changeset

  defp put_repositories(changeset, refs, current, snapshot) do
    known = MapSet.new(snapshot.repositories, & &1.ref)

    cond do
      not is_list(refs) or Enum.uniq(refs) != refs or length(refs) > @maximum_repositories ->
        add_error(changeset, :repositories, "must be a unique ordered list", validation: :list)

      not Enum.all?(refs, &(is_binary(&1) and MapSet.member?(known, &1))) ->
        add_error(changeset, :repositories, "names an unknown repository",
          validation: :unknown_repository
        )

      not Enum.all?(Enum.drop(refs, 1), &companion?/1) ->
        add_error(changeset, :repositories, "names a repository Coop cannot mount read-only",
          validation: :companion_name
        )

      refs == repository_refs(current) ->
        changeset

      true ->
        put_change(changeset, :repository_refs, refs)
    end
  end

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
