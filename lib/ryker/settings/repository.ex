defmodule Ryker.Settings.Repository do
  @moduledoc "A connected repository: display metadata, base branch and publication checkout."
  use Ecto.Schema
  import Ecto.Changeset
  alias Ryker.Settings.Validation

  @primary_key {:ref, :string, autogenerate: false}
  @fields ~w(
    ref display_name description github_repository base_branch publication_checkout_path
    github_access onboarding_state onboarding_error source_commit knowledge_pull_request_url
    last_github_event_at materialized_at knowledge_content knowledge_status knowledge_source_commit knowledge_sha256
  )a

  schema "repository_settings" do
    field(:display_name, :string)
    field(:description, :string)
    field(:github_repository, :string)
    field(:base_branch, :string, default: "main")
    field(:publication_checkout_path, :string)

    field(:github_access, Ecto.Enum,
      values: [:available, :suspended, :removed],
      default: :available
    )

    field(:onboarding_state, Ecto.Enum,
      values: [:pending, :cloning, :scanning, :publishing, :ready, :blocked],
      default: :pending
    )

    field(:onboarding_error, :string)
    field(:source_commit, :string)
    field(:knowledge_pull_request_url, :string)
    field(:knowledge_content, :string)
    field(:knowledge_status, Ecto.Enum, values: [:accepted, :proposed])
    field(:knowledge_source_commit, :string)
    field(:knowledge_sha256, :string)
    field(:last_github_event_at, :utc_datetime_usec)
    field(:materialized_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  def fields, do: @fields
  def new(_snapshot), do: %__MODULE__{}
  def find(snapshot, :ref, ref), do: Enum.find(snapshot.repositories, &(&1.ref == ref))

  def changeset(current, attributes, snapshot) do
    contexts = Enum.map(snapshot.contexts, & &1.ref)

    current
    |> cast(attributes, @fields)
    |> validate_required([:ref, :base_branch])
    |> Validation.validate_reference(:ref)
    |> validate_exclusion(:ref, contexts)
    |> validate_length(:display_name, min: 1, max: 120)
    |> validate_length(:description, min: 1, max: 1_000)
    |> validate_format(:github_repository, Validation.github_repository_pattern())
    |> Validation.validate_git_ref(:base_branch)
    |> Validation.validate_absolute_path(:publication_checkout_path)
    |> validate_length(:onboarding_error, max: 1_024)
    |> validate_length(:knowledge_content, max: 128_000)
    |> validate_format(:source_commit, ~r/\A[0-9a-f]{40}\z/)
    |> validate_format(:knowledge_source_commit, ~r/\A[0-9a-f]{40}\z/)
    |> validate_format(:knowledge_sha256, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:knowledge_pull_request_url, ~r/\Ahttps:\/\//)
    |> check_constraint(:github_access, name: :repository_github_state_valid)
  end

  def deletable(repository, snapshot) do
    referenced = Enum.any?(references(snapshot, repository.ref))

    if referenced, do: {:error, [{:ref, :referenced}]}, else: :ok
  end

  defp references(snapshot, repository_ref) do
    [
      Enum.any?(snapshot.contexts, &context_reference?(&1, repository_ref)),
      Enum.any?(snapshot.github_bindings, &(&1.repository_ref == repository_ref)),
      Enum.any?(snapshot.policy_bindings, &scoped_reference?(&1, repository_ref)),
      Enum.any?(snapshot.emisar_bindings, &scoped_reference?(&1, repository_ref)),
      Enum.any?(snapshot.webhook_sources, &(&1.context_ref == repository_ref)),
      snapshot.slack.default_repository_ref == repository_ref
    ]
  end

  defp context_reference?(context, repository_ref),
    do:
      context.primary_repository_ref == repository_ref or
        repository_ref in context.read_only_repository_refs

  defp scoped_reference?(binding, repository_ref),
    do: binding.scope_kind == :repository and binding.scope_ref == repository_ref
end
