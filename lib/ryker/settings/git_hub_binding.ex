defmodule Ryker.Settings.GitHubBinding do
  @moduledoc "Exact verified GitHub installation identity for one connected repository."
  use Ryker, :schema

  @primary_key {:name, :string, autogenerate: false}
  # What the App's permissions let Ryker's tools do here, each one a tool
  # checks. Approving a pull request is not among them: it is the repository's
  # own choice (`approvals_allowed`). Coop's worker opens and updates pull
  # requests under a publication's own approval.
  @action_grants ~w(read review rerun_ci cancel_ci)

  schema "github_binding_settings" do
    field(:repository_ref, :string)
    field(:installation_id, :integer)
    field(:repository_id, :integer)
    field(:ryker_actor_id, :integer)

    field(:action_grants, {:array, :string}, default: ~w(read review rerun_ci))

    field(:granted_permissions, :map, default: %{})
    field(:approvals_allowed, :boolean, default: false)
    timestamps()
  end

  @type t :: %__MODULE__{}

  def action_grants, do: @action_grants

  @doc """
  What Ryker may do in the repository: its App's grants, and approving pull
  requests when the repository allows it and Ryker can review there.
  """
  @spec grants(t()) :: [String.t()]
  def grants(%__MODULE__{action_grants: grants, approvals_allowed: true}) do
    if "review" in grants, do: grants ++ ["approve"], else: grants
  end

  def grants(%__MODULE__{action_grants: grants}), do: grants
end
