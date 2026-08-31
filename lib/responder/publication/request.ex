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
      "patch_digest" => digest(request.patch),
      "publication_ref" => request.publication_ref,
      "repository" => request.repository,
      "review" => request.review,
      "title" => request.title
    }
  end

  defp reference(value, field), do: text(value, 1_024, field)

  defp text(value, maximum, field) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
         :binary.match(value, <<0>>) == :nomatch and String.trim(value) != "",
       do: :ok,
       else: {:error, {:invalid_publication_request, field}}
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
