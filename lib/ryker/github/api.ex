defmodule Ryker.GitHub.API do
  @moduledoc false

  @callback find_issue_comment(term(), String.t(), pos_integer(), String.t()) ::
              {:ok, pos_integer()} | :not_found | {:error, term()}
  @callback create_issue_comment(term(), String.t(), pos_integer(), String.t()) ::
              {:ok, pos_integer()} | {:error, term()}
  @callback update_issue_comment(term(), String.t(), pos_integer(), String.t()) ::
              :ok | {:error, term()}
  @callback find_pull_review(term(), String.t(), pos_integer(), String.t()) ::
              {:ok, pos_integer()} | :not_found | {:error, term()}
  @callback create_pull_review(term(), String.t(), pos_integer(), String.t()) ::
              {:ok, pos_integer()} | {:error, term()}
  @callback update_pull_review(
              term(),
              String.t(),
              pos_integer(),
              pos_integer(),
              String.t()
            ) :: :ok | {:error, term()}
  @callback find_review_reply(
              term(),
              String.t(),
              pos_integer(),
              pos_integer(),
              String.t()
            ) :: {:ok, pos_integer()} | :not_found | {:error, term()}
  @callback create_review_reply(
              term(),
              String.t(),
              pos_integer(),
              pos_integer(),
              String.t()
            ) :: {:ok, pos_integer()} | {:error, term()}
  @callback update_review_comment(term(), String.t(), pos_integer(), String.t()) ::
              :ok | {:error, term()}
  @callback add_issue_comment_reaction(term(), String.t(), pos_integer(), String.t()) ::
              :ok | {:error, term()}
  @callback add_review_comment_reaction(term(), String.t(), pos_integer(), String.t()) ::
              :ok | {:error, term()}

  @callback find_open_pull_request(
              term(),
              String.t(),
              String.t(),
              String.t()
            ) :: {:ok, map()} | :not_found | {:error, term()}
  @callback create_draft_pull_request(
              term(),
              String.t(),
              String.t(),
              String.t(),
              String.t(),
              String.t()
            ) :: {:ok, map()} | {:error, term()}
  @callback get_pull_request(term(), String.t(), pos_integer()) ::
              {:ok, map()} | {:error, term()}
  @callback get_publication_status(term(), String.t(), pos_integer()) ::
              {:ok, map()} | {:error, term()}
  @callback read_context(term(), map()) :: {:ok, map()} | {:error, term()}
  @callback search(term(), map()) :: {:ok, map()} | {:error, term()}

  @optional_callbacks find_open_pull_request: 4,
                      create_draft_pull_request: 6,
                      get_pull_request: 3,
                      get_publication_status: 3,
                      read_context: 2,
                      search: 2
end
