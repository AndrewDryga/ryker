defmodule Ryker.Publication.Request do
  @moduledoc """
  Immutable host-authorized input to one draft-pull-request publisher.

  The request identifies the immutable candidate retained by Coop. Code and
  credentials never pass through this value or Ryker's publication database.
  """

  alias Ryker.CanonicalJSON
  alias Ryker.Publication.{Publication, Review}

  @enforce_keys [
    :approval_ref,
    :approved_at,
    :approved_by_actor_ref,
    :body,
    :existing_pull_request,
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
         true <- is_map(request.review) and Review.draft_shareable?(request.review),
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
      "publication_ref" => request.publication_ref,
      "repository" => request.repository,
      "review" => request.review,
      "title" => request.title
    }
  end

  def worker_body(%__MODULE__{} = request, repositories) do
    case repositories[request.repository] do
      %{base_branch: base, branch_prefix: prefix} ->
        existing = request.existing_pull_request || request.review["pull_request"]

        {:ok,
         %{
           "authorization_ref" => request.approval_ref,
           "candidate_head" => request.review["candidate_head"],
           "candidate_tree" => request.review["candidate_tree"],
           "branch" => publication_branch(request, existing, prefix),
           "base_branch" => String.replace_prefix(base, "refs/heads/", ""),
           "expected_head" => if(existing, do: existing["head_commit"], else: ""),
           "pull_request_number" => if(existing, do: existing["number"], else: 0),
           "title" => safe_text(request.title),
           "body" => pull_request_body(request)
         }}

      _missing ->
        {:error, {:publication_repository_not_configured, request.repository}}
    end
  end

  defp reference(value, field), do: text(value, 1_024, field)

  defp publication_branch(_request, %{"ref" => ref}, _prefix),
    do: String.replace_prefix(ref, "refs/heads/", "")

  defp publication_branch(request, nil, prefix) do
    slug =
      request.title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 42)
      |> String.trim_trailing("-")

    slug = if slug == "", do: "change", else: slug
    suffix = request.publication_ref |> String.split(":") |> List.last() |> String.slice(-10, 10)
    "#{prefix}/#{slug}-#{suffix}"
  end

  defp pull_request_body(request) do
    """
    ## Ryker task

    #{safe_text(request.body)}

    ## Publication proof

    - Coop session: `#{request.review["session_id"]}`
    - Reviewed parent: `#{request.review["parent_head"]}`
    - Reviewed tree: `#{request.review["candidate_tree"]}`
    - Publication commit: `#{request.review["candidate_head"]}`
    - Gate: `#{request.review["gate"]}`
    - Rebase: `#{request.review["rebase"]}`
    """
    |> String.trim()
  end

  defp safe_text(value) do
    value
    |> String.replace(~r/[\x00-\x1f\x7f]/u, " ")
    |> String.replace("@", "@\u200B")
    |> String.split()
    |> Enum.join(" ")
  end

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

  defp existing_pull_request(%Publication{pull_request_number: nil}), do: nil

  # Every publication that already opened a pull request carries it into its
  # next generation, so a corrected candidate updates that exact draft instead
  # of searching by branch and opening a second one. `head_commit` is the head
  # Ryker last put on its own branch — the head observed when it drifted
  # outside the publication, otherwise the commit this publication published —
  # and Git pushes with a force-with-lease against it, so a branch somebody else
  # moved fails closed rather than being overwritten.
  defp existing_pull_request(%Publication{} = publication) do
    %{
      "head_commit" => publication.expected_remote_head_sha || publication.commit_sha,
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
end
