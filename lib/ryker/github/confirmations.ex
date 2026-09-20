defmodule Ryker.GitHub.Confirmations do
  @moduledoc """
  Applies an authenticated GitHub comment command to one exact delivered offer.

  The command is deliberately textual so it works in issue and pull-request
  discussions without granting the model a write credential. The host derives
  the actor and discussion from the signed webhook, reloads the original
  delivery target, and delegates the durable transition to the same state
  services used by Slack and Chat.
  """

  import Ecto.Query

  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Input
  alias Ryker.Repo
  alias Ryker.State.{Automations, Behaviors, Memories, Record, Schedules, TaskOffers}
  alias Ryker.Work.Turn

  @command_prefix "/ryker confirm"
  @command ~r/\A\/ryker confirm ([A-Za-z0-9_.:-]{1,256})\z/
  @digest ~r/\A[0-9a-f]{64}\z/
  @reference ~r/\A[A-Za-z0-9_.:-]{1,256}\z/
  @supported_kinds ~w(task_offer schedule_offer automation_change_offer memory_offer preference_offer guidance_offer standing_assignment_offer)

  @type options :: %{repositories: %{String.t() => %{name: String.t(), digest: String.t()}}}

  @spec options!(keyword() | map()) :: options()
  def options!(options) do
    options = exact_options!(options)
    repositories = Map.fetch!(options, :repositories)

    unless is_map(repositories) and map_size(repositories) > 0 do
      raise ArgumentError, "GitHub confirmation repositories must be a non-empty map"
    end

    %{repositories: Map.new(repositories, &repository!/1)}
  end

  @spec apply(Input.t(), options() | nil) ::
          {:ok, :not_confirmation | map()} | {:error, term()}
  def apply(%Input{} = input, %{repositories: repositories}) when is_map(repositories) do
    case command(input) do
      :not_confirmation ->
        {:ok, :not_confirmation}

      :invalid ->
        invalid()

      {:ok, record_ref} ->
        apply_record(input, record_ref, repositories)
    end
  rescue
    _error -> {:error, :github_confirmation_unavailable}
  end

  def apply(%Input{} = input, nil) do
    case command(input) do
      :not_confirmation -> {:ok, :not_confirmation}
      _confirmation_command -> invalid()
    end
  end

  def apply(_input, _options), do: {:error, :invalid_github_confirmation_options}

  defp command(%Input{
         content: %{
           "event_name" => "issue_comment",
           "payload" => %{"comment" => %{"body" => body}}
         },
         event_kind: :message
       })
       when is_binary(body) do
    body = String.trim(body)

    case Regex.run(@command, body, capture: :all_but_first) do
      [record_ref] -> {:ok, record_ref}
      nil -> if String.starts_with?(body, @command_prefix), do: :invalid, else: :not_confirmation
    end
  end

  defp command(%Input{}), do: :not_confirmation

  defp apply_record(input, record_ref, repositories) do
    with {:ok, record, episode, turn} <- offer(record_ref),
         true <- record.kind in @supported_kinds,
         :ok <- exact_discussion(input, episode),
         {:ok, target} <- delivered_target(episode, turn),
         {:ok, confirmation} <-
           confirm(record, input, target, repositories),
         {:ok, resource_ref, status} <- resource(confirmation) do
      {:ok,
       %{
         "kind" => record.kind,
         "record_ref" => record.ref,
         "resource_ref" => resource_ref,
         "status" => Atom.to_string(status)
       }}
    else
      _invalid -> invalid()
    end
  end

  defp offer(record_ref) do
    query =
      from(record in Record,
        join: episode in Episode,
        on: episode.id == record.episode_id,
        join: turn in Turn,
        on: turn.id == record.turn_id and turn.episode_id == record.episode_id,
        where: record.ref == ^record_ref,
        select: {record, episode, turn}
      )

    case Repo.one(query) do
      {%Record{} = record, %Episode{} = episode, %Turn{} = turn} ->
        {:ok, record, episode, turn}

      nil ->
        {:error, :not_found}
    end
  end

  defp exact_discussion(
         %Input{
           destination: %{
             conversation_ref: conversation_ref,
             thread_ref: thread_ref,
             transport: "github"
           }
         },
         %Episode{
           destination_conversation_ref: conversation_ref,
           destination_thread_ref: thread_ref,
           destination_transport: "github"
         }
       ),
       do: :ok

  defp exact_discussion(_input, _episode), do: {:error, :discussion_mismatch}

  defp delivered_target(
         %Episode{} = episode,
         %Turn{status: :settled, external_receipt: %{"message_ref" => message_ref} = receipt}
       )
       when is_binary(message_ref) do
    if receipt["conversation_ref"] == episode.destination_conversation_ref and
         receipt["thread_ref"] == episode.destination_thread_ref and
         receipt["transport"] == episode.destination_transport do
      {:ok,
       %{
         conversation_ref: episode.destination_conversation_ref,
         message_ref: message_ref,
         thread_ref: episode.destination_thread_ref,
         transport: episode.destination_transport
       }}
    else
      {:error, :delivery_mismatch}
    end
  end

  defp delivered_target(_episode, _turn), do: {:error, :not_delivered}

  defp confirm(
         %Record{kind: "task_offer", payload: %{"kind" => "engineering"} = payload} = record,
         input,
         target,
         repositories
       ) do
    with repository when is_binary(repository) <- payload["repository"],
         {:ok, policy} <- Map.fetch(repositories, repository) do
      TaskOffers.confirm(attributes(record, input, target) |> Map.put(:policy, policy))
    else
      _invalid -> {:error, :task_policy_not_configured}
    end
  end

  defp confirm(%Record{kind: "task_offer"}, _input, _target, _repositories),
    do: {:error, :unsupported_task_offer}

  defp confirm(%Record{kind: "memory_offer"} = record, input, target, _repositories),
    do: Memories.confirm(attributes(record, input, target))

  defp confirm(%Record{kind: kind} = record, input, target, _repositories)
       when kind in ["preference_offer", "guidance_offer", "standing_assignment_offer"],
       do: Behaviors.confirm(attributes(record, input, target))

  defp confirm(%Record{kind: "schedule_offer"} = record, input, target, _repositories),
    do: Schedules.confirm(attributes(record, input, target))

  defp confirm(%Record{kind: "automation_change_offer"} = record, input, target, _repositories),
    do: Automations.confirm(attributes(record, input, target))

  defp confirm(_record, _input, _target, _repositories), do: {:error, :unsupported_offer}

  defp attributes(record, input, target) do
    %{
      actor_ref: Input.actor_ref(input),
      confirmation_ref: input.event_ref,
      occurred_at: input.occurred_at,
      record_ref: record.ref,
      target: target
    }
  end

  defp resource(%{episode: %Episode{id: id}, status: status})
       when is_binary(id) and status in [:confirmed, :duplicate],
       do: {:ok, id, status}

  defp resource(%{memory: %{ref: ref}, status: status})
       when is_binary(ref) and status in [:confirmed, :duplicate],
       do: {:ok, ref, status}

  defp resource(%{behavior: %{ref: ref}, status: status})
       when is_binary(ref) and status in [:confirmed, :duplicate],
       do: {:ok, ref, status}

  defp resource(%{schedule: %{ref: ref}, status: status})
       when is_binary(ref) and status in [:confirmed, :duplicate],
       do: {:ok, ref, status}

  defp resource(%{automation: %{"automation_id" => ref}, status: status})
       when is_binary(ref) and status in [:confirmed, :duplicate],
       do: {:ok, ref, status}

  defp resource(_confirmation), do: {:error, :invalid_confirmation_result}

  defp exact_options!(options) when is_list(options) do
    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options),
      do: options |> Map.new() |> exact_options!(),
      else: raise(ArgumentError, "GitHub confirmation options must use unique known fields")
  end

  defp exact_options!(%{} = options) do
    if Map.keys(options) == [:repositories],
      do: options,
      else: raise(ArgumentError, "GitHub confirmation options must contain repositories")
  end

  defp exact_options!(_options),
    do: raise(ArgumentError, "GitHub confirmation options must be a map or keyword list")

  defp repository!({repository, %{contributor_policy: policy}}) when is_binary(repository) do
    unless Regex.match?(@reference, repository),
      do: raise(ArgumentError, "GitHub confirmation repository is invalid")

    {repository, policy!(policy)}
  end

  defp repository!({repository, %{name: _name, digest: _digest} = policy})
       when is_binary(repository) do
    unless Regex.match?(@reference, repository),
      do: raise(ArgumentError, "GitHub confirmation repository is invalid")

    {repository, policy!(policy)}
  end

  defp repository!(_entry),
    do: raise(ArgumentError, "GitHub confirmation repository policy is invalid")

  defp policy!(%{name: name, digest: digest} = source)
       when is_binary(name) and is_binary(digest) do
    if Regex.match?(@reference, name) and Regex.match?(@digest, digest) do
      %{name: name, digest: digest}
      |> maybe_put(:repository_ref, Map.get(source, :repository_ref))
      |> maybe_put(:repository_context, Map.get(source, :repository_context))
    else
      raise ArgumentError, "GitHub confirmation contributor policy is invalid"
    end
  end

  defp policy!(_policy),
    do: raise(ArgumentError, "GitHub confirmation contributor policy is invalid")

  defp invalid, do: {:ok, %{"status" => "invalid"}}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
