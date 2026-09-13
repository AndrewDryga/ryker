defmodule Ryker.StateTools.AutomationTools do
  @moduledoc false

  alias Ryker.Repo
  alias Ryker.State.Automations
  alias Ryker.StateTools.RecordWriter

  @spec list_automations(map(), map()) :: {:ok, map()} | {:error, term()}
  def list_automations(arguments, binding) do
    with :ok <- automation_list_channel(arguments["channel_ref"], binding) do
      automations =
        binding.episode
        |> Automations.list_for_episode()
        |> filter_automations(arguments)
        |> Enum.take(Map.get(arguments, "limit", 50))

      {:ok, %{"automations" => automations, "cursor" => nil}}
    end
  end

  @spec get_automation(map(), map()) :: {:ok, map()} | {:error, term()}
  def get_automation(arguments, binding) do
    case Automations.fetch_for_episode(binding.episode, arguments["automation_id"]) do
      {:ok, automation} ->
        {:ok, %{"automation" => Automations.detail(automation, arguments["run_limit"])}}

      :error ->
        {:error, :not_found}
    end
  end

  @spec propose_automation(map(), map()) :: {:ok, map()} | {:error, term()}
  def propose_automation(arguments, binding) do
    proposals = arguments["proposals"]

    Repo.transaction(fn ->
      Enum.with_index(proposals)
      |> Enum.reduce_while([], &prepare_automation_record(&1, &2, binding))
      |> Enum.reverse()
    end)
    |> case do
      {:ok, records} -> {:ok, %{"proposals" => records}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_automation_record({proposal, index}, records, binding) do
    case automation_record(binding, proposal, index) do
      {:ok, record} -> {:cont, [record | records]}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp automation_record(
         binding,
         %{"action" => "create", "trigger" => %{"type" => "source_event"} = trigger} = proposal,
         index
       ) do
    with :ok <- automation_capability("source_event", binding),
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
        "propose_automation:#{index}",
        proposal,
        "standing_assignment_offer",
        payload,
        "automation_offer"
      )
    end
  end

  defp automation_record(binding, %{"action" => "create"} = proposal, index) do
    with :ok <- automation_capability("time", binding) do
      recurrence = automation_recurrence(proposal["trigger"])

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
        "propose_automation:#{index}",
        proposal,
        "schedule_offer",
        payload,
        "automation_offer"
      )
    end
  end

  defp automation_record(binding, %{"action" => action} = proposal, index)
       when action in ~w(update pause resume delete) do
    with {:ok, payload} <- Automations.prepare_change(binding.episode, proposal),
         :ok <- automation_capability(payload["automation_kind"], binding) do
      RecordWriter.create_public_record(
        binding,
        "propose_automation:#{index}",
        proposal,
        "automation_change_offer",
        payload,
        "automation_offer"
      )
    end
  end

  defp automation_record(_binding, _proposal, _index), do: {:error, :not_configured}

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

  defp automation_recurrence(%{"type" => "time", "recurrence" => "once", "at" => at}),
    do: %{"at" => at, "kind" => "once"}

  defp automation_recurrence(%{"type" => "time", "recurrence" => "daily", "time" => time}),
    do: %{"kind" => "daily", "time" => time}

  defp automation_recurrence(%{
         "type" => "time",
         "recurrence" => "weekly",
         "time" => time,
         "weekday" => weekday
       }),
       do: %{"kind" => "weekly", "time" => time, "weekday" => weekday}

  defp automation_recurrence(%{
         "type" => "time",
         "recurrence" => "monthly",
         "day" => day,
         "time" => time
       }),
       do: %{"day" => day, "kind" => "monthly", "time" => time}

  defp automation_recurrence(
         %{
           "type" => "time",
           "recurrence" => "interval",
           "every_seconds" => every_seconds
         } = trigger
       ),
       do: %{
         "every_seconds" => every_seconds,
         "kind" => "interval",
         "starts_at" => trigger["starts_at"]
       }

  defp automation_recurrence(trigger), do: %{"kind" => "source_event", "trigger" => trigger}
end
