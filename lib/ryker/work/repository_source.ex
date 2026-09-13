defmodule Ryker.Work.RepositorySource do
  @moduledoc """
  The one frozen request union and immutable binding for repository sources.

  A model or worker may select only *which* source inside the repository the
  host already authorized: the configured default, a branch, a pull request, or
  an exact object id. It can never name a repository, filesystem path, remote,
  URL, credential, or raw ref, and selecting a source grants no publication
  authority.

  The request union is exactly:

      {"kind":"default"}
      {"kind":"branch","name":"feature/payments"}
      {"kind":"pull_request","number":514}
      {"kind":"commit","sha":"0123456789abcdef0123456789abcdef01234567"}

  Coop resolves it against the policy-configured remote and returns the
  version-1 binding this module validates as the session's `source`. Ryker
  persists the request before remote creation, sends the identical value as
  `source` through create, fence, replay, rotation, and checkpoint, and refuses
  any binding that answers a different request.
  """

  @kinds ~w(default branch pull_request commit)
  @maximum_branch_bytes 255
  @maximum_pull_request_number 10_000_000
  @maximum_remote_identity_bytes 256
  @maximum_ref_bytes 512
  @binding_fields ~w(
    base_commit default_commit default_ref kind remote_identity
    requested resolved_at selected_commit selected_ref version
  )
  # Checked under their own names after the field set: `admitted_tree` must be
  # present, the pull-request fields only when the request is a pull request.
  @binding_optional_fields ~w(admitted_tree pull_request_expected_head pull_request_number)
  @object_id_regex ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @branch_charset_regex ~r/\A[\x21-\x7E]+\z/
  @branch_schema_pattern "^[A-Za-z0-9][A-Za-z0-9._/-]*$"

  @type request :: %{required(String.t()) => term()}
  @type binding :: %{required(String.t()) => term()}

  @doc "The source every new repository-backed session gets when nobody chooses another."
  @spec default() :: request()
  def default, do: %{"kind" => "default"}

  @doc """
  Normalizes one caller-supplied selector, or refuses it.

  Validation is exact: unknown kinds, extra keys, unbounded branch names,
  non-positive or oversized pull-request numbers, and abbreviated, uppercase,
  symbolic, or otherwise partial object ids are all refused rather than
  repaired.
  """
  @spec parse(term()) :: {:ok, request()} | {:error, term()}
  def parse(%{"kind" => kind} = value) when kind in @kinds do
    with :ok <- exact_fields(value, kind) do
      parse_kind(kind, value)
    end
  end

  def parse(_value), do: invalid(:kind)

  @doc "Parses an optional selector; `nil` means workspace-free work with no source."
  @spec parse_optional(term()) :: {:ok, request() | nil} | {:error, term()}
  def parse_optional(nil), do: {:ok, nil}
  def parse_optional(value), do: parse(value)

  @doc "The single remote ref a selector derives, or `nil` when it names no ref."
  @spec derived_ref(request()) :: String.t() | nil
  def derived_ref(%{"kind" => "branch", "name" => name}), do: "refs/heads/" <> name
  def derived_ref(%{"kind" => "pull_request", "number" => number}), do: "refs/pull/#{number}/head"
  def derived_ref(%{"kind" => _kind}), do: nil

  @doc """
  Whether two selectors are the same requested source.

  Create idempotency, fence requests, rotation, and checkpoint validation all
  compare through this: the same operation identity carrying another selector is
  a conflict, never a rebind.
  """
  @spec same?(request() | nil, request() | nil) :: boolean()
  def same?(nil, nil), do: true
  def same?(nil, _other), do: false
  def same?(_source, nil), do: false
  def same?(source, other), do: source == other

  @doc "A compact human-readable identity used in prompts and operator surfaces."
  @spec describe(request() | nil) :: String.t() | nil
  def describe(nil), do: nil
  def describe(%{"kind" => "default"}), do: "default"
  def describe(%{"kind" => "branch", "name" => name}), do: "branch #{name}"
  def describe(%{"kind" => "pull_request", "number" => number}), do: "pull request ##{number}"
  def describe(%{"kind" => "commit", "sha" => sha}), do: "commit #{sha}"

  @doc """
  Validates the version-1 immutable binding Coop resolved and journaled.

  Every field is checked against the request it claims to answer: the derived
  ref, the pinned default and selected commits, the comparison base, the
  admitted tree, the remote identity, and the resolution time. A trusted
  expected pull-request head that disagrees with the resolved head fails closed.

  `admitted_tree` is required: every binding Coop resolves under this contract
  records the tree it admitted.
  """
  @spec parse_binding(term()) :: {:ok, binding()} | {:error, term()}
  def parse_binding(%{} = value) do
    with :ok <- exact_binding_fields(value),
         :ok <- binding_version(value["version"]),
         {:ok, requested, expected_head} <- binding_requested(value["requested"]),
         :ok <- binding_kind(value["kind"], requested),
         :ok <-
           bounded_binding(
             value["remote_identity"],
             @maximum_remote_identity_bytes,
             :remote_identity
           ),
         :ok <- binding_ref(value["default_ref"], :default_ref),
         :ok <- binding_object_id(value["default_commit"], :default_commit),
         :ok <- binding_object_id(value["selected_commit"], :selected_commit),
         :ok <- binding_object_id(value["base_commit"], :base_commit),
         :ok <- binding_object_id(value["admitted_tree"], :admitted_tree),
         {:ok, resolved_at} <- binding_timestamp(value["resolved_at"]),
         :ok <- binding_selection(requested, value),
         :ok <- binding_expected_head(requested, value, expected_head) do
      {:ok, value |> Map.put("requested", requested) |> Map.put("resolved_at", resolved_at)}
    end
  end

  def parse_binding(_value), do: invalid_binding(:fields)

  @doc """
  Validates a binding and proves it answers the exact persisted request.

  A workspace-free session persists no request and is never re-resolved, so a
  binding it reports is checked for internal consistency alone.
  """
  @spec reconcile(term(), request() | nil) :: {:ok, binding() | nil} | {:error, term()}
  def reconcile(nil, nil), do: {:ok, nil}
  def reconcile(nil, _requested), do: invalid_binding(:fields)

  def reconcile(value, nil), do: parse_binding(value)

  def reconcile(value, requested) do
    with {:ok, binding} <- parse_binding(value) do
      if same?(binding["requested"], requested),
        do: {:ok, binding},
        else: invalid_binding(:requested)
    end
  end

  @doc "The bounded JSON Schema fragment offered to the model and to `request_task`."
  @spec json_schema() :: map()
  def json_schema do
    %{
      "oneOf" => [
        %{
          "additionalProperties" => false,
          "properties" => %{"kind" => %{"const" => "default"}},
          "required" => ["kind"],
          "type" => "object"
        },
        %{
          "additionalProperties" => false,
          "properties" => %{
            "kind" => %{"const" => "branch"},
            "name" => %{
              "maxLength" => @maximum_branch_bytes,
              "minLength" => 1,
              "pattern" => @branch_schema_pattern,
              "type" => "string"
            }
          },
          "required" => ["kind", "name"],
          "type" => "object"
        },
        %{
          "additionalProperties" => false,
          "properties" => %{
            "kind" => %{"const" => "pull_request"},
            "number" => %{
              "maximum" => @maximum_pull_request_number,
              "minimum" => 1,
              "type" => "integer"
            }
          },
          "required" => ["kind", "number"],
          "type" => "object"
        },
        %{
          "additionalProperties" => false,
          "properties" => %{
            "kind" => %{"const" => "commit"},
            "sha" => %{"pattern" => "^(?:[0-9a-f]{40}|[0-9a-f]{64})$", "type" => "string"}
          },
          "required" => ["kind", "sha"],
          "type" => "object"
        }
      ],
      "type" => "object"
    }
  end

  @doc "The prose the model reads beside the schema, so facts are not read as authority."
  @spec instructions() :: String.t()
  def instructions do
    """
    repository_source selects which source inside the already authorized repository a new
    repository-backed episode starts from. Use null unless the event names one. Choose
    {"kind":"default"} for the configured default branch, {"kind":"branch","name":"<branch>"} for a
    named branch, {"kind":"pull_request","number":<n>} for a pull request, or
    {"kind":"commit","sha":"<full 40 or 64 character lowercase object id>"} for one exact commit.
    You cannot choose a repository, remote, URL, path, tag, or raw ref, and selecting a human branch
    or pull request never authorizes pushing to it. Only a new repository-backed episode may choose;
    continuing, replying, reacting, and ignoring keep whatever source their work already pinned.
    """
  end

  defp parse_kind("default", _value), do: {:ok, %{"kind" => "default"}}

  defp parse_kind("branch", %{"name" => name}) do
    if branch_name?(name),
      do: {:ok, %{"kind" => "branch", "name" => name}},
      else: invalid(:name)
  end

  defp parse_kind("pull_request", %{"number" => number}) do
    if is_integer(number) and number in 1..@maximum_pull_request_number,
      do: {:ok, %{"kind" => "pull_request", "number" => number}},
      else: invalid(:number)
  end

  defp parse_kind("commit", %{"sha" => sha}) do
    if object_id?(sha),
      do: {:ok, %{"kind" => "commit", "sha" => sha}},
      else: invalid(:sha)
  end

  defp exact_fields(value, kind) do
    if Map.keys(value) |> Enum.sort() == kind_fields(kind),
      do: :ok,
      else: invalid(:fields)
  end

  defp kind_fields("default"), do: ["kind"]
  defp kind_fields("branch"), do: ["kind", "name"]
  defp kind_fields("pull_request"), do: ["kind", "number"]
  defp kind_fields("commit"), do: ["kind", "sha"]

  # Git's own branch rules, plus a raw-ref guard: a caller naming `refs/...`
  # is supplying a ref namespace, which is host authority and not a selection.
  defp branch_name?(name) do
    is_binary(name) and byte_size(name) in 1..@maximum_branch_bytes and
      Regex.match?(@branch_charset_regex, name) and
      not String.starts_with?(name, ["-", "/", "refs/"]) and
      not String.ends_with?(name, ["/", ".", ".lock"]) and
      not String.contains?(name, ["..", "@{", "//", "~", "^", ":", "?", "*", "[", "\\"]) and
      name != "@" and Enum.all?(String.split(name, "/"), &branch_component?/1)
  end

  defp branch_component?(component) do
    component != "" and not String.starts_with?(component, ".") and
      not String.ends_with?(component, ".lock")
  end

  defp object_id?(value), do: is_binary(value) and Regex.match?(@object_id_regex, value)

  defp exact_binding_fields(value) do
    keys = Map.keys(value)

    if Enum.all?(@binding_fields, &(&1 in keys)) and
         keys -- (@binding_fields ++ @binding_optional_fields) == [],
       do: :ok,
       else: invalid_binding(:fields)
  end

  defp binding_version(1), do: :ok
  defp binding_version(_version), do: invalid_binding(:version)

  # Coop echoes the request it resolved. Trusted ingress may have attached an
  # expected pull-request head to that request as host-owned evidence; it is not
  # part of the selector identity and is checked against the resolved head.
  defp binding_requested(%{"kind" => "pull_request"} = value) do
    {expected_head, request} = Map.pop(value, "expected_head_commit")

    case parse(request) do
      {:ok, requested} -> {:ok, requested, expected_head}
      {:error, _reason} -> invalid_binding(:requested)
    end
  end

  defp binding_requested(value) do
    case parse(value) do
      {:ok, requested} -> {:ok, requested, nil}
      {:error, _reason} -> invalid_binding(:requested)
    end
  end

  defp binding_kind(kind, %{"kind" => kind}), do: :ok
  defp binding_kind(_kind, _requested), do: invalid_binding(:kind)

  defp bounded_binding(value, maximum, field) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
         String.trim(value) != "" and :binary.match(value, <<0>>) == :nomatch,
       do: :ok,
       else: invalid_binding(field)
  end

  defp binding_ref(value, field) do
    with :ok <- bounded_binding(value, @maximum_ref_bytes, field) do
      if String.starts_with?(value, "refs/") and Regex.match?(@branch_charset_regex, value),
        do: :ok,
        else: invalid_binding(field)
    end
  end

  defp binding_object_id(value, field) do
    if object_id?(value), do: :ok, else: invalid_binding(field)
  end

  defp binding_timestamp(value) when is_binary(value) and byte_size(value) <= 64 do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, 0} -> {:ok, DateTime.to_iso8601(timestamp)}
      _invalid -> invalid_binding(:resolved_at)
    end
  end

  defp binding_timestamp(_value), do: invalid_binding(:resolved_at)

  defp binding_selection(%{"kind" => "default"}, binding) do
    cond do
      binding["selected_ref"] != binding["default_ref"] -> invalid_binding(:selected_ref)
      binding["selected_commit"] != binding["default_commit"] -> invalid_binding(:selected_commit)
      Map.has_key?(binding, "pull_request_number") -> invalid_binding(:pull_request_number)
      true -> :ok
    end
  end

  defp binding_selection(%{"kind" => "commit", "sha" => sha}, binding) do
    cond do
      not is_nil(binding["selected_ref"]) -> invalid_binding(:selected_ref)
      binding["selected_commit"] != sha -> invalid_binding(:selected_commit)
      Map.has_key?(binding, "pull_request_number") -> invalid_binding(:pull_request_number)
      true -> :ok
    end
  end

  defp binding_selection(%{"kind" => "branch"} = requested, binding) do
    cond do
      binding["selected_ref"] != derived_ref(requested) -> invalid_binding(:selected_ref)
      Map.has_key?(binding, "pull_request_number") -> invalid_binding(:pull_request_number)
      true -> :ok
    end
  end

  defp binding_selection(%{"kind" => "pull_request", "number" => number} = requested, binding) do
    cond do
      binding["selected_ref"] != derived_ref(requested) -> invalid_binding(:selected_ref)
      Map.get(binding, "pull_request_number") != number -> invalid_binding(:pull_request_number)
      true -> :ok
    end
  end

  defp binding_expected_head(%{"kind" => "pull_request"}, binding, requested_head) do
    Enum.reduce_while(
      [requested_head, Map.get(binding, "pull_request_expected_head")],
      :ok,
      fn
        nil, :ok ->
          {:cont, :ok}

        expected, :ok ->
          if object_id?(expected) and expected == binding["selected_commit"],
            do: {:cont, :ok},
            else: {:halt, invalid_binding(:pull_request_expected_head)}
      end
    )
  end

  defp binding_expected_head(_requested, binding, _requested_head) do
    if Map.has_key?(binding, "pull_request_expected_head"),
      do: invalid_binding(:pull_request_expected_head),
      else: :ok
  end

  defp invalid(field), do: {:error, {:invalid_repository_source, field}}
  defp invalid_binding(field), do: {:error, {:invalid_repository_source_binding, field}}
end
