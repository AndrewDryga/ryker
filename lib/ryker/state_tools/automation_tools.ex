defmodule Ryker.StateTools.AutomationTools do
  @moduledoc false
  alias Ryker.Behaviors
  alias Ryker.Repo
  alias Ryker.Schedules
  alias Ryker.Settings
  alias Ryker.StateTools.RecordWriter

  @spec list_automations(map(), map()) :: {:ok, map()} | {:error, term()}
  def list_automations(arguments, binding) do
    with :ok <- automation_list_channel(arguments["channel_ref"], binding) do
      matching =
        binding.episode
        |> Behaviors.Automations.list_for_episode()
        |> filter_automations(arguments)

      limit = Map.get(arguments, "limit", 50)

      # Narrow by query, state or trigger to reach the rest when not complete.
      {:ok,
       %{"automations" => Enum.take(matching, limit), "complete" => length(matching) <= limit}}
    end
  end

  @spec get_automation(map(), map()) :: {:ok, map()} | {:error, term()}
  def get_automation(arguments, binding) do
    case Behaviors.Automations.fetch_for_episode(binding.episode, arguments["automation_id"]) do
      {:ok, automation} ->
        {:ok, %{"automation" => Behaviors.Automations.detail(automation, arguments["run_limit"])}}

      :error ->
        {:error, :not_found}
    end
  end

  @spec propose_automation(map(), map()) :: {:ok, map()} | {:error, term()}
  def propose_automation(arguments, binding) do
    proposals = arguments["proposals"]

    Repo.transaction(fn ->
      proposals
      |> Enum.reduce_while([], &prepare_automation_record(&1, &2, binding))
      |> Enum.reverse()
    end)
    |> case do
      {:ok, records} -> {:ok, %{"proposals" => records}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Each proposal is its own offer, keyed by its content: repeating one returns
  # the same offer, and a corrected one in the same turn is a new offer.
  defp prepare_automation_record(proposal, records, binding) do
    case automation_record(binding, proposal) do
      {:ok, record} -> {:cont, [record | records]}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp automation_record(
         binding,
         %{"action" => "create", "trigger" => %{"type" => "source_event"} = trigger} = proposal
       ) do
    with :ok <- automation_capability("source_event", binding),
         :ok <- automation_repository(proposal["repository"], binding),
         {:ok, context_channel} <- automation_channel(proposal["context_channel"], binding),
         {:ok, delivery_channel} <- automation_channel(proposal["delivery_channel"], binding),
         :ok <- source_event_hold(proposal["hold"]) do
      payload = %{
        "context_channel" => context_channel,
        "delivery_channel" => delivery_channel,
        "expires_at" => proposal["expires_at"],
        "filter" => trigger["filter"] || %{},
        "hold" => nil,
        "repository" => proposal["repository"],
        "source_kind" => trigger["source_kind"],
        "task" => proposal["prompt"],
        "title" => proposal["title"]
      }

      RecordWriter.create_public_record(
        binding,
        "propose_automation",
        proposal,
        "standing_assignment_offer",
        payload,
        "automation_offer"
      )
    end
  end

  defp automation_record(binding, %{"action" => "create"} = proposal) do
    with :ok <- automation_capability("time", binding),
         :ok <- automation_repository(proposal["repository"], binding),
         {:ok, recurrence} <- Schedules.ScheduleRecurrence.from_trigger(proposal["trigger"]) do
      payload = %{
        "authority" => if(proposal["repository"], do: "repository_write", else: "read_only"),
        "expires_at" => proposal["expires_at"],
        "recurrence" => recurrence,
        "repository" => proposal["repository"],
        "task" => proposal["prompt"],
        "timezone" => proposal["trigger"]["timezone"] || "Etc/UTC",
        "title" => proposal["title"]
      }

      RecordWriter.create_public_record(
        binding,
        "propose_automation",
        proposal,
        "schedule_offer",
        payload,
        "automation_offer"
      )
    end
  end

  defp automation_record(binding, %{"action" => action} = proposal)
       when action in ~w(update pause resume delete) do
    with {:ok, payload} <- Behaviors.Automations.prepare_change(binding.episode, proposal),
         :ok <- automation_capability(payload["automation_kind"], binding) do
      RecordWriter.create_public_record(
        binding,
        "propose_automation",
        proposal,
        "automation_change_offer",
        payload,
        "automation_offer"
      )
    end
  end

  defp automation_record(_binding, _proposal), do: {:error, :not_configured}

  # A schedule runs with write access to the repository it names, so an
  # automation may name only one this work could change. Any configured
  # repository was copied unchecked (2026-10-04 review).
  defp automation_repository(nil, _binding), do: :ok

  defp automation_repository(repository, %{session: session}) do
    writable =
      case Settings.fetch() do
        {:ok, snapshot} ->
          Settings.writable_repositories(
            snapshot,
            session.environment_ref,
            session.repository_ref
          )

        {:error, _reason} ->
          [session.repository_ref]
      end

    if repository in writable, do: :ok, else: {:error, :automation_repository_not_writable}
  end

  defp automation_capability("source_event", _binding), do: :ok

  defp automation_capability("time", binding) do
    if :schedules in binding.capabilities, do: :ok, else: {:error, :not_configured}
  end

  defp automation_channel(nil, binding),
    do: {:ok, binding.episode.destination_conversation_ref}

  defp automation_channel(channel, binding)
       when channel == binding.episode.destination_conversation_ref,
       do: {:ok, channel}

  defp automation_channel(_channel, _binding), do: {:error, :unauthorized}

  defp automation_list_channel(nil, _binding), do: :ok

  defp automation_list_channel(channel, binding)
       when channel == binding.episode.destination_conversation_ref,
       do: :ok

  defp automation_list_channel(_channel, _binding), do: {:error, :unauthorized}

  defp source_event_hold(nil), do: :ok
  defp source_event_hold(_hold), do: {:error, :not_configured}

  defp filter_automations(automations, arguments) do
    automations
    |> Enum.filter(fn automation ->
      enabled = arguments["enabled"]
      enabled_match = is_nil(enabled) or enabled == (automation["status"] == "active")
      trigger_match = trigger_matches?(automation, arguments["trigger_type"])
      query_match = query_matches?(automation, arguments["query"])
      enabled_match and trigger_match and query_match
    end)
  end

  defp trigger_matches?(_automation, nil), do: true

  defp trigger_matches?(automation, "time"),
    do: automation["trigger"]["type"] == "time"

  defp trigger_matches?(automation, "source_event"),
    do: automation["trigger"]["type"] == "source_event"

  defp query_matches?(_automation, nil), do: true

  defp query_matches?(automation, query) do
    String.contains?(String.downcase(automation["title"]), String.downcase(query))
  end
end
