defmodule Ryker.GitHub.CapabilityTools.Arguments do
  @moduledoc """
  Validates the arguments of every GitHub capability tool into the exact
  document the host acts on, refusing anything outside the published schema
  before a repository or credential is chosen.
  """

  alias Ryker.GitHub.{InertText, SourceRef}

  @emoji_names ~w(+1 -1 confused eyes heart hooray laugh rocket)
  @reaction_fields ~w(emoji item_ref)
  @context_fields ~w(cursor limit section)
  @repository_context_fields ~w(cursor limit number review_root_id section)
  @search_fields ~w(cursor kind limit query state)
  @ci_fields ~w(attempt run_id)
  @review_fields ~w(body comments event head_sha number)
  @context_sections ~w(subject issue_comments reviews review_comments review_thread files)
  @page_size 20

  @doc "The reactions set_github_reaction may add."
  @spec emoji_names() :: [String.t()]
  def emoji_names, do: @emoji_names

  @doc "The sections a conversation or pull request read may ask for."
  @spec context_sections() :: [String.t()]
  def context_sections, do: @context_sections

  @doc """
  The arguments a tool's schema requires. A repository-bound tool also takes
  an optional `repository`.
  """
  @spec required(:ci | :context | :reaction | :repository_context | :review | :search) ::
          [String.t()]
  def required(:ci), do: @ci_fields
  def required(:context), do: @context_fields
  def required(:reaction), do: @reaction_fields
  def required(:repository_context), do: @repository_context_fields
  def required(:review), do: @review_fields
  def required(:search), do: @search_fields

  @spec reaction_document(term()) :: {:ok, map(), String.t()} | {:error, atom()}
  def reaction_document(%{} = arguments) do
    with true <- Map.keys(arguments) |> Enum.sort() == @reaction_fields,
         {:ok, source} <- SourceRef.parse(arguments["item_ref"]),
         emoji_name when emoji_name in @emoji_names <- arguments["emoji"] do
      {:ok, source, emoji_name}
    else
      {:error, :invalid_github_source_ref} -> {:error, :unauthorized}
      _invalid -> {:error, :invalid_arguments}
    end
  end

  def reaction_document(_arguments), do: {:error, :invalid_arguments}

  @spec context_document(term()) :: {:ok, map()} | {:error, :invalid_arguments}
  def context_document(%{} = arguments) do
    with true <- Enum.sort(Map.keys(arguments)) == Enum.sort(@context_fields),
         {:ok, page} <- cursor(arguments["cursor"]),
         {:ok, limit} <- page_size(arguments["limit"]),
         section when section in @context_sections <- arguments["section"] do
      {:ok, %{limit: limit, page: page, section: section}}
    else
      _invalid -> {:error, :invalid_arguments}
    end
  end

  def context_document(_arguments), do: {:error, :invalid_arguments}

  @spec repository_context_document(term()) :: {:ok, map()} | {:error, :invalid_arguments}
  def repository_context_document(%{} = arguments) do
    with true <- exact_keys?(arguments, @repository_context_fields),
         {:ok, repository} <- repository_argument(arguments["repository"]),
         {:ok, page} <- cursor(arguments["cursor"]),
         {:ok, limit} <- page_size(arguments["limit"]),
         number when is_integer(number) and number > 0 <- arguments["number"],
         root when is_nil(root) or (is_integer(root) and root > 0) <- arguments["review_root_id"],
         section when section in @context_sections <- arguments["section"],
         true <- section != "review_thread" or is_integer(root) do
      {:ok,
       %{
         limit: limit,
         number: number,
         page: page,
         repository: repository,
         review_root_id: root,
         section: section
       }}
    else
      _invalid -> {:error, :invalid_arguments}
    end
  end

  def repository_context_document(_arguments), do: {:error, :invalid_arguments}

  @spec ci_document(term()) :: {:ok, map()} | {:error, :invalid_arguments}
  def ci_document(%{} = arguments) do
    with true <- exact_keys?(arguments, @ci_fields),
         {:ok, repository} <- repository_argument(arguments["repository"]),
         attempt when is_integer(attempt) and attempt > 0 <- arguments["attempt"],
         run_id when is_integer(run_id) and run_id > 0 <- arguments["run_id"] do
      {:ok, %{attempt: attempt, repository: repository, run_id: run_id}}
    else
      _invalid -> {:error, :invalid_arguments}
    end
  end

  def ci_document(_arguments), do: {:error, :invalid_arguments}

  @spec review_document(term()) :: {:ok, map()} | {:error, :invalid_arguments}
  def review_document(%{} = arguments) do
    with true <- exact_keys?(arguments, @review_fields),
         {:ok, repository} <- repository_argument(arguments["repository"]),
         body when is_binary(body) and byte_size(body) in 1..12_000 <- arguments["body"],
         comments when is_list(comments) and length(comments) <= 20 <- arguments["comments"],
         true <- Enum.all?(comments, &review_comment?/1),
         event when event in ~w(comment request_changes approve) <- arguments["event"],
         sha when is_binary(sha) and byte_size(sha) == 40 <- arguments["head_sha"],
         true <- Regex.match?(~r/\A[a-f0-9]{40}\z/, sha),
         number when is_integer(number) and number > 0 <- arguments["number"] do
      # The review is the model's own words, so it mentions nobody and links
      # no issue (`InertText`); it went to GitHub as written.
      {:ok,
       %{
         body: InertText.inert(body),
         comments:
           Enum.map(comments, &Map.update!(&1, "body", fn text -> InertText.inert(text) end)),
         event: event,
         head_sha: sha,
         number: number,
         repository: repository
       }}
    else
      _invalid -> {:error, :invalid_arguments}
    end
  end

  def review_document(_arguments), do: {:error, :invalid_arguments}

  @spec search_document(term()) :: {:ok, map()} | {:error, :invalid_arguments}
  def search_document(%{} = arguments) do
    with true <- exact_keys?(arguments, @search_fields),
         {:ok, repository} <- repository_argument(arguments["repository"]),
         {:ok, page} <- cursor(arguments["cursor"]),
         kind when kind in ~w(issues pull_requests all) <- arguments["kind"],
         {:ok, limit} <- page_size(arguments["limit"]),
         query when is_binary(query) and byte_size(query) in 1..1_000 <- arguments["query"],
         true <- String.valid?(query) and String.trim(query) != "",
         state when state in ~w(open closed all) <- arguments["state"] do
      {:ok,
       %{
         kind: kind,
         limit: limit,
         page: page,
         query: query,
         repository: repository,
         state: state
       }}
    else
      _invalid -> {:error, :invalid_arguments}
    end
  end

  def search_document(_arguments), do: {:error, :invalid_arguments}

  # A page size grants nothing: more than one page reads one full page, with the cursor for the
  # rest. On emisar#87 (2026-09-30) the model asked for 50, was refused, and asked again for 20.
  defp page_size(limit) when is_integer(limit) and limit >= 1, do: {:ok, min(limit, @page_size)}
  defp page_size(_limit), do: {:error, :invalid_arguments}

  # Every repository-bound tool takes an optional repository of the session's
  # environment; the exact key set is otherwise unchanged.
  defp exact_keys?(arguments, fields) do
    keys = Enum.sort(Map.keys(arguments))
    keys == Enum.sort(fields) or keys == Enum.sort(["repository" | fields])
  end

  defp repository_argument(nil), do: {:ok, nil}

  defp repository_argument(value) when is_binary(value) and byte_size(value) in 1..256 do
    if String.valid?(value) and String.trim(value) != "",
      do: {:ok, value},
      else: {:error, :invalid_arguments}
  end

  defp repository_argument(_value), do: {:error, :invalid_arguments}

  defp cursor(nil), do: {:ok, 1}

  defp cursor("page:" <> value) do
    case Integer.parse(value) do
      {page, ""} when page in 2..10 -> {:ok, page}
      _invalid -> {:error, :invalid_arguments}
    end
  end

  defp cursor(_value), do: {:error, :invalid_arguments}

  defp review_comment?(
         %{"body" => body, "line" => line, "path" => path, "side" => side} = comment
       ) do
    Enum.sort(Map.keys(comment)) == ~w(body line path side) and is_binary(body) and
      byte_size(body) in 1..12_000 and is_integer(line) and line > 0 and is_binary(path) and
      byte_size(path) in 1..1_024 and side in ["LEFT", "RIGHT"]
  end

  defp review_comment?(_comment), do: false
end
