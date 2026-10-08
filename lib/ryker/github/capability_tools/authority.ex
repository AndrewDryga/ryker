defmodule Ryker.GitHub.CapabilityTools.Authority do
  @moduledoc """
  What a GitHub capability call is allowed to touch.

  A session reads the repository it changes, or another repository of its
  environment mounted read-only beside it; it writes only to its own. A
  request that came from GitHub is bound to its issue or pull request; the
  repository's grants decide reviews and CI; and the episode's active inputs
  name the comment a reaction may answer.
  """
  alias Ryker.Episodes
  alias Ryker.GitHub.CapabilityTools.Arguments
  alias Ryker.Repo

  @doc """
  The issue or pull request a request that came from GitHub is bound to, and
  the client configured for its repository.
  """
  @spec bound_target(map(), map()) :: {:ok, map(), map()} | {:error, atom()}
  def bound_target(%{episode: %Episodes.Episode{} = episode}, options) do
    with {:ok, binding, repository_id} <- conversation(episode.destination_conversation_ref),
         true <- episode.destination_transport == "github",
         true <- MapSet.member?(options.bindings, binding),
         {:ok, configured} <- Map.fetch(options.clients, binding),
         true <- configured.repository_id == repository_id,
         {:ok, thread} <- thread(episode.destination_thread_ref, binding) do
      {:ok, thread, configured}
    else
      :error -> {:error, :not_configured}
      false -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  def bound_target(_binding, _options), do: {:error, :unauthorized}

  @doc """
  The repository a read goes to: the one the session changes, unless
  `requested` names another repository of its environment, one mounted
  read-only beside its own. A repository outside the environment is not
  readable from it, however well Ryker knows it.
  """
  @spec repository_target(map(), map(), String.t() | nil) ::
          {:ok, map() | nil, map()} | {:error, atom()}
  def repository_target(binding, options, nil), do: session_target(binding, options)

  def repository_target(binding, options, requested) do
    cond do
      requested == session_repository(binding) -> session_target(binding, options)
      requested in companion_repositories(binding) -> companion_target(requested, options)
      true -> {:error, :unauthorized}
    end
  end

  @doc "`repository_target/3` for a write: never a read-only companion."
  @spec mutation_repository_target(map(), map(), String.t() | nil) ::
          {:ok, map() | nil, map()} | {:error, atom()}
  def mutation_repository_target(binding, options, requested) do
    case repository_target(binding, options, requested) do
      {:ok, _thread, %{repository_ref: repository_ref}} = target ->
        if repository_ref in companion_repositories(binding),
          do: {:error, :unauthorized},
          else: target

      other ->
        other
    end
  end

  @doc """
  Whether pull request `number` may be read or reviewed: a request that came
  from GitHub reaches only its own subject.
  """
  @spec number_authorized(map(), map() | nil, pos_integer()) :: :ok | {:error, :unauthorized}
  def number_authorized(
        %{episode: %Episodes.Episode{destination_transport: "github"}},
        %{number: number},
        number
      ),
      do: :ok

  def number_authorized(
        %{episode: %Episodes.Episode{destination_transport: "github"}},
        nil,
        _number
      ),
      do: :ok

  def number_authorized(
        %{episode: %Episodes.Episode{destination_transport: "github"}},
        _current,
        _number
      ),
      do: {:error, :unauthorized}

  def number_authorized(_binding, _current, _number), do: :ok

  @doc "Whether `section` exists for the subject `target` names."
  @spec section_authorized(String.t(), map()) :: :ok | {:error, :invalid_arguments}
  def section_authorized(section, %{subject_kind: "issue"})
      when section in ~w(subject issue_comments),
      do: :ok

  def section_authorized("review_thread", %{review_root_id: root}) when is_integer(root),
    do: :ok

  def section_authorized(section, %{subject_kind: "pull"}) do
    if section in Arguments.context_sections() and section != "review_thread",
      do: :ok,
      else: {:error, :invalid_arguments}
  end

  def section_authorized(_section, _target), do: {:error, :invalid_arguments}

  @doc "Whether the repository's grants include `grant`."
  @spec grant(map(), String.t()) :: :ok | {:error, :unauthorized}
  def grant(%{grants: grants}, grant) do
    if MapSet.member?(grants, grant), do: :ok, else: {:error, :unauthorized}
  end

  @doc "The grant a CI action needs."
  @spec ci_grant(map(), :read | :rerun | :cancel) :: :ok | {:error, :unauthorized}
  def ci_grant(configured, :read), do: grant(configured, "read")
  def ci_grant(configured, :rerun), do: grant(configured, "rerun_ci")
  def ci_grant(configured, :cancel), do: grant(configured, "cancel_ci")

  @doc "The grants a review needs: an approval is a grant of its own."
  @spec review_grant(map(), String.t()) :: :ok | {:error, :unauthorized}
  def review_grant(configured, "approve") do
    with :ok <- grant(configured, "review"), do: grant(configured, "approve")
  end

  def review_grant(configured, _event), do: grant(configured, "review")

  @doc """
  The active GitHub input whose comment `source` names, which a reaction may
  answer: a person's or a bot's, from the same binding, where GitHub takes
  reactions.
  """
  @spec current_input(map(), map()) :: {:ok, map()} | {:error, :unauthorized}
  def current_input(%{episode: %Episodes.Episode{} = episode}, source) do
    source_item_ref = "github:#{source.item_kind}:#{source.item_id}"

    episode
    |> active_input_events()
    |> Enum.find_value({:error, :unauthorized}, fn event ->
      case event.payload do
        %{
          "payload" =>
            %{
              "actor" => %{"kind" => actor_kind},
              "destination" => %{"transport" => "github"},
              "source" => %{"kind" => "github", "ref" => binding},
              "source_capabilities" => %{"react" => %{"emoji_names" => emoji_names}},
              "source_item_ref" => ^source_item_ref
            } = input
        }
        when actor_kind in ["user", "bot"] and binding == source.binding and
               is_list(emoji_names) ->
          {:ok, input}

        _other ->
          nil
      end
    end)
  end

  def current_input(_binding, _source), do: {:error, :unauthorized}

  defp session_target(
         %{episode: %Episodes.Episode{destination_transport: "github"}} = binding,
         options
       ),
       do: bound_target(binding, options)

  defp session_target(
         %{
           episode: %Episodes.Episode{destination_transport: transport},
           session: %{repository_ref: repository_ref}
         },
         options
       )
       when transport in ["slack", "control_plane"] and is_binary(repository_ref) do
    case Enum.find(options.clients, fn {_name, configured} ->
           configured.repository_ref == repository_ref
         end) do
      {_name, configured} -> {:ok, nil, configured}
      nil -> {:error, :not_configured}
    end
  end

  defp session_target(_binding, _options), do: {:error, :unauthorized}

  defp session_repository(%{session: %{repository_ref: repository_ref}}), do: repository_ref
  defp session_repository(_binding), do: nil

  defp companion_repositories(%{
         session: %{repository_context: %{"read_only_repositories" => repositories}}
       })
       when is_list(repositories),
       do: repositories

  defp companion_repositories(_binding), do: []

  # A companion repository has no current subject; its pull requests are read
  # by number.
  defp companion_target(repository_ref, options) do
    case Enum.find(options.clients, fn {_name, configured} ->
           configured.repository_ref == repository_ref
         end) do
      {_name, configured} -> {:ok, nil, configured}
      nil -> {:error, :not_configured}
    end
  end

  defp conversation(value) when is_binary(value) do
    case String.split(value, ":") do
      ["github", binding, "repository", id] ->
        case Integer.parse(id) do
          {repository_id, ""} when repository_id > 0 -> {:ok, binding, repository_id}
          _invalid -> {:error, :unauthorized}
        end

      _invalid ->
        {:error, :unauthorized}
    end
  end

  defp conversation(_value), do: {:error, :unauthorized}

  defp thread(value, binding) when is_binary(value) do
    case String.split(value, ":") do
      ["github", ^binding, kind, number] when kind in ["issue", "pull"] ->
        thread_number(kind, number)

      ["github", ^binding, "pull", number, "review-thread", root] ->
        with {:ok, target} <- thread_number("pull", number),
             {root_id, ""} when root_id > 0 <- Integer.parse(root) do
          {:ok, %{target | review_root_id: root_id}}
        else
          _invalid -> {:error, :unauthorized}
        end

      _invalid ->
        {:error, :unauthorized}
    end
  end

  defp thread(_value, _binding), do: {:error, :unauthorized}

  defp thread_number(kind, value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 ->
        {:ok, %{number: number, review_root_id: nil, subject_kind: kind}}

      _invalid ->
        {:error, :unauthorized}
    end
  end

  defp active_input_events(%Episodes.Episode{id: episode_id, active_input_refs: refs}) do
    refs = Enum.uniq(refs)

    if refs == [] do
      []
    else
      episode_id
      |> Episodes.Event.Query.by_episode_id()
      |> Episodes.Event.Query.admitted_inputs(refs)
      |> Episodes.Event.Query.ordered_by_sequence_desc()
      |> Repo.all()
    end
  end
end
