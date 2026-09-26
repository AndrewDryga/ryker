defmodule Ryker.GitHub.Client.Fields do
  @moduledoc """
  The checks the GitHub client applies before it spends a request, and to the
  fields GitHub sends back.

  A check of a request argument returns `:ok` or `{:error,
  {:invalid_github_api_request, field}}`, because the caller asked for
  something it may not; a reply field that fails its check is a
  `{:github_protocol_error, field}`, because GitHub answered a well-formed
  request with something Ryker will not pass on. Predicates return a boolean
  and leave the error to their caller.
  """

  @repository ~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/
  @maximum_context_pages 10
  @maximum_context_page_size 20
  @maximum_context_text_bytes 12_000

  # --- request arguments ----------------------------------------------------

  @spec target(term(), term()) :: :ok | {:error, {:invalid_github_api_request, :target}}
  def target(repository, id) do
    with true <- is_binary(repository) and Regex.match?(@repository, repository),
         :ok <- positive_id(id) do
      :ok
    else
      _invalid -> {:error, {:invalid_github_api_request, :target}}
    end
  end

  @spec repository(term()) :: :ok | {:error, {:invalid_github_api_request, :repository}}
  def repository(value) do
    if is_binary(value) and Regex.match?(@repository, value),
      do: :ok,
      else: {:error, {:invalid_github_api_request, :repository}}
  end

  @spec ref_component(term()) :: :ok | {:error, {:invalid_github_api_request, :ref}}
  def ref_component(value) do
    valid =
      is_binary(value) and byte_size(value) in 1..240 and
        not String.starts_with?(value, ["-", "/"]) and
        not String.ends_with?(value, ["/", "."]) and
        not String.contains?(value, [
          "..",
          "@{",
          " ",
          "~",
          "^",
          ":",
          "?",
          "*",
          "[",
          "\\",
          "\r",
          "\n",
          "\t"
        ])

    if valid, do: :ok, else: {:error, {:invalid_github_api_request, :ref}}
  end

  @spec sha(term()) :: :ok | {:error, {:invalid_github_api_request, :sha}}
  def sha(value) do
    if git_identity?(value),
      do: :ok,
      else: {:error, {:invalid_github_api_request, :sha}}
  end

  @spec positive_id(term()) :: :ok | {:error, {:invalid_github_api_request, :target}}
  def positive_id(value) when is_integer(value) and value > 0, do: :ok
  def positive_id(_value), do: {:error, {:invalid_github_api_request, :target}}

  @spec text(term()) :: :ok | {:error, {:invalid_github_api_request, :text}}
  def text(value) do
    if is_binary(value) and String.valid?(value) and byte_size(value) > 0 and
         byte_size(value) <= 256 * 1_024,
       do: :ok,
       else: {:error, {:invalid_github_api_request, :text}}
  end

  # --- the pages the model reads --------------------------------------------

  @doc "A page number within the bounded continuation the model may follow."
  @spec context_page?(term()) :: boolean()
  def context_page?(value), do: is_integer(value) and value in 1..@maximum_context_pages

  @doc "A page size the model may ask for."
  @spec context_limit?(term()) :: boolean()
  def context_limit?(value), do: is_integer(value) and value in 1..@maximum_context_page_size

  @doc "Whether this is the last page the continuation reaches."
  @spec last_context_page?(pos_integer()) :: boolean()
  def last_context_page?(page), do: page == @maximum_context_pages

  @doc "The cursor to the next page: only after a full page, and never past the bound."
  @spec next_cursor([term()] | non_neg_integer(), pos_integer(), pos_integer()) ::
          String.t() | nil
  def next_cursor(items, page, limit) when is_list(items),
    do: next_cursor(length(items), page, limit)

  def next_cursor(item_count, page, limit) when is_integer(item_count) do
    if item_count == limit and page < @maximum_context_pages,
      do: "page:#{page + 1}",
      else: nil
  end

  # --- what GitHub sent back ------------------------------------------------

  @spec context_actor(term()) :: {:ok, map()} | {:error, {:github_protocol_error, :actor}}
  def context_actor(%{"id" => id, "login" => login, "type" => type})
      when is_integer(id) and id > 0 and is_binary(login) and is_binary(type) and
             byte_size(login) in 1..256 and byte_size(type) in 1..64,
      do: {:ok, %{"id" => id, "login" => login, "type" => type}}

  def context_actor(_actor), do: {:error, {:github_protocol_error, :actor}}

  @doc "Provider text cut to the context bound, with whether it was cut."
  @spec context_text(term(), boolean()) ::
          {:ok, String.t() | nil, boolean()} | {:error, {:github_protocol_error, :text}}
  def context_text(nil, true), do: {:ok, nil, false}

  def context_text(value, nullable) when is_binary(value) do
    if String.valid?(value) and (nullable or String.trim(value) != "") do
      truncated = byte_size(value) > @maximum_context_text_bytes
      {:ok, String.byte_slice(value, 0, @maximum_context_text_bytes), truncated}
    else
      {:error, {:github_protocol_error, :text}}
    end
  end

  def context_text(_value, _nullable), do: {:error, {:github_protocol_error, :text}}

  @doc "Optional provider text cut to the context bound, or nil when it is absent or not text."
  @spec bounded_optional_text(term()) :: String.t() | nil
  def bounded_optional_text(value) when is_binary(value) and byte_size(value) > 0,
    do: String.byte_slice(value, 0, @maximum_context_text_bytes)

  def bounded_optional_text(_value), do: nil

  @spec context_url(term()) :: :ok | {:error, {:github_protocol_error, :url}}
  def context_url(value) when is_binary(value) and byte_size(value) in 1..2_048 do
    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: host}} when is_binary(host) -> :ok
      _invalid -> {:error, {:github_protocol_error, :url}}
    end
  end

  def context_url(_value), do: {:error, {:github_protocol_error, :url}}

  @spec context_datetime(term()) :: :ok | {:error, {:github_protocol_error, :datetime}}
  def context_datetime(value) do
    case DateTime.from_iso8601(value || "") do
      {:ok, _datetime, 0} -> :ok
      _invalid -> {:error, {:github_protocol_error, :datetime}}
    end
  end

  @spec git_identity?(term()) :: boolean()
  def git_identity?(value),
    do: is_binary(value) and Regex.match?(~r/\A(?:[a-f0-9]{40}|[a-f0-9]{64})\z/, value)

  @spec positive_id?(term()) :: boolean()
  def positive_id?(value), do: is_integer(value) and value > 0
end
