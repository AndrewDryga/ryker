defmodule Responder.Publication.Request do
  @moduledoc """
  Immutable host-authorized input to one draft-pull-request publisher.

  The request carries the exact Coop review and verified complete patch. The
  trusted publisher binding, not this value, owns checkout paths, credentials,
  base branches, and GitHub installation authority.
  """

  alias Responder.CanonicalJSON
  alias Responder.Publication.{Publication, Review}

  @enforce_keys [
    :approval_ref,
    :approved_at,
    :approved_by_actor_ref,
    :body,
    :existing_pull_request,
    :patch,
    :publication_ref,
    :repository,
    :review,
    :title
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          approval_ref: String.t(),
          approved_at: DateTime.t(),
          approved_by_actor_ref: String.t(),
          body: String.t(),
          existing_pull_request: nil | map(),
          patch: binary(),
          publication_ref: String.t(),
          repository: String.t(),
          review: map(),
          title: String.t()
        }

  @spec new(Publication.t()) :: {:ok, t()} | {:error, term()}
  def new(%Publication{status: :publish_pending} = publication) do
    request = %__MODULE__{
      approval_ref: publication.approval_ref,
      approved_at: publication.approved_at,
      approved_by_actor_ref: publication.approved_by_actor_ref,
      body: publication.body,
      existing_pull_request: existing_pull_request(publication),
      patch: publication.review_patch,
      publication_ref: publication.ref,
      repository: publication.repository,
      review: publication.review_document,
      title: publication.title
    }

    with :ok <- reference(request.publication_ref, :publication_ref),
         :ok <- reference(request.approval_ref, :approval_ref),
         :ok <- reference(request.approved_by_actor_ref, :approved_by_actor_ref),
         true <- is_struct(request.approved_at, DateTime),
         :ok <- text(request.repository, 256, :repository),
         :ok <- text(request.title, 120, :title),
         :ok <- text(request.body, 8_000, :body),
         :ok <- validate_existing_pull_request(request.existing_pull_request),
         true <- is_map(request.review) and Review.publishable?(request.review),
         true <- is_binary(request.patch) and request.patch != "",
         true <- byte_size(request.patch) == request.review["patch_bytes"],
         true <- digest(request.patch) == request.review["patch_digest"],
         :ok <- CanonicalJSON.validate(document(request), max_bytes: 512 * 1_024) do
      {:ok, request}
    else
      false -> {:error, {:invalid_publication_request, :identity}}
      {:error, _reason} = error -> error
    end
  end

  def new(%Publication{}), do: {:error, :publication_not_approved}
  def new(_publication), do: {:error, {:invalid_publication_request, :publication}}

  @spec document(t()) :: map()
  def document(%__MODULE__{} = request) do
    %{
      "approval_ref" => request.approval_ref,
      "approved_at" => DateTime.to_iso8601(request.approved_at),
      "approved_by_actor_ref" => request.approved_by_actor_ref,
      "body" => request.body,
      "existing_pull_request" => request.existing_pull_request,
      "patch_digest" => digest(request.patch),
      "publication_ref" => request.publication_ref,
      "repository" => request.repository,
      "review" => request.review,
      "title" => request.title
    }
  end

  defp reference(value, field), do: text(value, 1_024, field)

  defp validate_existing_pull_request(nil), do: :ok

  defp validate_existing_pull_request(
         %{
           "head_commit" => head_commit,
           "number" => number,
           "ref" => ref,
           "url" => url
         } = pull_request
       )
       when map_size(pull_request) == 4 and is_integer(number) and number > 0 do
    with true <- git_identity?(head_commit),
         true <- branch_ref?(ref),
         true <- github_pull_url?(url, number) do
      :ok
    else
      false -> {:error, {:invalid_publication_request, :existing_pull_request}}
    end
  end

  defp validate_existing_pull_request(_pull_request),
    do: {:error, {:invalid_publication_request, :existing_pull_request}}

  defp existing_pull_request(%Publication{expected_remote_head_sha: nil}), do: nil

  defp existing_pull_request(%Publication{} = publication) do
    %{
      "head_commit" => publication.expected_remote_head_sha,
      "number" => publication.pull_request_number,
      "ref" => publication.branch_ref,
      "url" => publication.pull_request_url
    }
  end

  defp git_identity?(value),
    do: is_binary(value) and Regex.match?(~r/\A[a-f0-9]{40}([a-f0-9]{24})?\z/, value)

  defp branch_ref?(value),
    do:
      is_binary(value) and
        Regex.match?(~r/\Arefs\/heads\/[A-Za-z0-9._\/-]{1,240}\z/, value)

  defp github_pull_url?(value, number) when is_binary(value) and byte_size(value) <= 2_048 do
    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: "github.com", path: path}} ->
        is_binary(path) and String.ends_with?(path, "/pull/#{number}") and
          Regex.match?(~r/\A\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pull\/[1-9][0-9]*\z/, path)

      _invalid ->
        false
    end
  end

  defp github_pull_url?(_value, _number), do: false

  defp text(value, maximum, field) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
         :binary.match(value, <<0>>) == :nomatch and String.trim(value) != "",
       do: :ok,
       else: {:error, {:invalid_publication_request, field}}
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
