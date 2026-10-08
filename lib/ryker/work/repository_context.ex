defmodule Ryker.Work.RepositoryContext do
  @moduledoc false
  alias Ryker.CanonicalJSON
  alias Ryker.Maps
  alias Ryker.Reference

  @fields [:context_ref, :parallel_goal_limit, :primary_repository, :read_only_repositories]
  @document_fields Enum.map(@fields, &Atom.to_string/1)

  @type t :: %{
          context_ref: String.t(),
          parallel_goal_limit: 1..3,
          primary_repository: String.t(),
          read_only_repositories: [String.t()]
        }

  @spec prepare(t() | nil, String.t() | nil) :: {:ok, t() | nil} | {:error, :invalid}
  def prepare(nil, _repository_ref), do: {:ok, nil}

  def prepare(
        %{
          context_ref: context_ref,
          parallel_goal_limit: parallel_goal_limit,
          primary_repository: primary_repository,
          read_only_repositories: read_only_repositories
        } = context,
        repository_ref
      )
      when map_size(context) == 4 do
    if valid?(
         context_ref,
         parallel_goal_limit,
         primary_repository,
         read_only_repositories,
         repository_ref
       ),
       do: {:ok, context},
       else: {:error, :invalid}
  end

  def prepare(_context, _repository_ref), do: {:error, :invalid}

  @spec restore(map() | nil, String.t() | nil) :: {:ok, t() | nil} | {:error, :invalid}
  def restore(nil, _repository_ref), do: {:ok, nil}

  def restore(
        %{
          "context_ref" => context_ref,
          "parallel_goal_limit" => parallel_goal_limit,
          "primary_repository" => primary_repository,
          "read_only_repositories" => read_only_repositories
        } = context,
        repository_ref
      )
      when map_size(context) == 4 do
    if Maps.exact_keys?(context, @document_fields) do
      prepare(
        %{
          context_ref: context_ref,
          parallel_goal_limit: parallel_goal_limit,
          primary_repository: primary_repository,
          read_only_repositories: read_only_repositories
        },
        repository_ref
      )
    else
      {:error, :invalid}
    end
  end

  def restore(_context, _repository_ref), do: {:error, :invalid}

  @spec document(t() | nil) :: map() | nil
  def document(nil), do: nil

  def document(context) do
    %{
      "context_ref" => context.context_ref,
      "parallel_goal_limit" => context.parallel_goal_limit,
      "primary_repository" => context.primary_repository,
      "read_only_repositories" => context.read_only_repositories
    }
  end

  defp valid?(context_ref, parallel_goal_limit, primary, read_only, repository_ref) do
    Reference.valid?(context_ref, 256) and primary == repository_ref and
      Reference.valid?(primary, 1_024) and valid_limit?(parallel_goal_limit) and
      valid_companions?(read_only, primary) and
      CanonicalJSON.validate(
        document(%{
          context_ref: context_ref,
          parallel_goal_limit: parallel_goal_limit,
          primary_repository: primary,
          read_only_repositories: read_only
        }),
        max_bytes: 16 * 1_024
      ) == :ok
  end

  defp valid_limit?(limit), do: is_integer(limit) and limit in 1..3

  defp valid_companions?(repositories, primary) do
    is_list(repositories) and length(repositories) <= 32 and
      repositories == Enum.uniq(repositories) and primary not in repositories and
      Enum.all?(repositories, &Reference.valid?(&1, 1_024))
  end

  @doc """
  `changeset` refused when its `repository_context` is not a bounded set of
  repositories that `restore/2` would read back for its `repository_ref`.
  """
  @spec validate(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate(changeset) do
    Ecto.Changeset.validate_change(changeset, :repository_context, fn :repository_context,
                                                                      value ->
      case restore(value, Ecto.Changeset.get_field(changeset, :repository_ref)) do
        {:ok, _context} -> []
        {:error, :invalid} -> [repository_context: "is not a bounded repository set"]
      end
    end)
  end
end
