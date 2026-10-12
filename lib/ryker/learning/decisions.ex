defmodule Ryker.Learning.Decisions do
  @moduledoc """
  A decision a person makes without writing a message, kept where learning
  reads.

  Learning reads what people said in a conversation. A person who confirms an
  offer or pauses an automation with a button says nothing, so what learning
  kept stayed as the last message left it: a topic still said a memory offer
  "remains pending" after it was confirmed, and another called a reminder's
  pause "unverified" after it was paused (2026-10-11). Each such decision is
  now recorded as a message from Ryker in the conversation the offer or
  automation came from, in the same learning scope as that conversation's
  messages. Routing settles it without a model and starts no work
  (`Ryker.Admission.Executor`); the conversation's next learning pass reads it
  like any message and corrects what it kept.

  It is written after the decision commits, never inside it: a decision a
  person made stands even when this record of it cannot be kept.
  """
  alias Ryker.Ingress
  alias Ryker.Repo
  require Logger

  @kind "decision_receipt"
  @source %{kind: "system", ref: "ryker"}
  # The fields an offer's words are found in, in the order they read best.
  @described ~w(title summary text message task value key)

  @doc "Whether `input` is a decision this module recorded."
  @spec receipt?(Ingress.Input.t()) :: boolean()
  def receipt?(%Ingress.Input{source: @source, content: %{"kind" => @kind}}), do: true
  def receipt?(_input), do: false

  @doc """
  Records, once the open transaction commits, that `record`, an offer of
  `kind`, was confirmed at `at`.
  """
  @spec offer_confirmed(map(), DateTime.t()) :: :ok
  def offer_confirmed(%{episode_id: episode_id, kind: kind, payload: payload, ref: ref}, at) do
    record_after_commit(episode_id, "offer-confirmed:#{ref}", at, %{
      "decision" => "confirmed",
      "record_ref" => ref,
      "text" => "The offer was confirmed (#{offer_words(kind)}): #{described(payload)}"
    })
  end

  @doc """
  Records, once the open transaction commits, that `schedule` was paused,
  resumed or deleted, as revision `revision`.
  """
  @spec automation_changed(map(), :paused | :active | :deleted) :: :ok
  def automation_changed(
        %{source_episode_id: episode_id, ref: ref, revision: revision, title: title},
        status
      ) do
    record_after_commit(episode_id, "automation-#{status}:#{ref}:#{revision}", nil, %{
      "decision" => Atom.to_string(status),
      "record_ref" => ref,
      "text" => ~s(The automation "#{title}" was #{status_words(status)}.)
    })
  end

  defp record_after_commit(nil, _native_input_id, _at, _content), do: :ok

  defp record_after_commit(episode_id, native_input_id, at, content) do
    Repo.after_commit(fn -> record(episode_id, native_input_id, at, content) end)
  end

  defp record(episode_id, native_input_id, at, content) do
    occurred_at = at || Repo.now!()

    with %Ingress.Inbox.Entry{} = entry <- latest_entry(episode_id),
         {:ok, profile} <- work_profile(entry.work_profile),
         {:ok, input} <- input(entry, native_input_id, occurred_at, content),
         {:ok, _receipt} <-
           Ingress.Inbox.record(input,
             execution_mode: entry.execution_mode,
             work_profile: profile
           ) do
      :ok
    else
      nil -> :ok
      {:error, reason} -> log(reason)
    end
  end

  # The conversation's own last message places the decision in the same
  # learning scope: its destination, repository and execution mode.
  defp latest_entry(episode_id) do
    episode_id
    |> Ingress.Inbox.Entry.Query.by_episode_id()
    |> Ingress.Inbox.Entry.Query.ordered_by_occurred_at_desc()
    |> Ingress.Inbox.Entry.Query.limit_to(1)
    |> Repo.peek()
  end

  defp work_profile(nil), do: {:ok, nil}
  defp work_profile(document), do: Ingress.WorkProfile.restore(document)

  defp input(entry, native_input_id, occurred_at, content) do
    Ingress.Input.new(%{
      actor: %{kind: :system, ref: "ryker"},
      content: Map.put(content, "kind", @kind),
      destination: %{
        conversation_ref: entry.destination_conversation_ref,
        thread_ref: entry.destination_thread_ref,
        transport: entry.destination_transport
      },
      event_kind: :event,
      event_ref: native_input_id,
      native_input_id: "decision:#{native_input_id}",
      occurred_at: occurred_at,
      occurred_at_source: :source,
      revision: 1,
      source: @source,
      source_capabilities: %{},
      source_item_ref: nil
    })
  end

  defp described(%{"subject" => subject, "value" => value})
       when is_binary(subject) and is_binary(value),
       do: "#{subject}: #{value}"

  defp described(%{"action" => action, "automation_kind" => _kind}) when is_binary(action),
    do: "#{action} the automation"

  defp described(payload) when is_map(payload) do
    Enum.find_value(@described, "no details", fn field ->
      case payload[field] do
        value when is_binary(value) and value != "" -> value
        _other -> nil
      end
    end)
  end

  defp offer_words("memory_offer"), do: "to remember something"
  defp offer_words("preference_offer"), do: "a preference"
  defp offer_words("guidance_offer"), do: "guidance to follow"
  defp offer_words("schedule_offer"), do: "an automation"
  defp offer_words("standing_assignment_offer"), do: "a standing assignment"
  defp offer_words("slack_post_offer"), do: "a Slack post"
  defp offer_words("automation_change_offer"), do: "a change to an automation"
  defp offer_words(_kind), do: "a change"

  defp status_words(:paused), do: "paused"
  defp status_words(:active), do: "resumed"
  defp status_words(:deleted), do: "deleted"

  defp log(reason) do
    Logger.warning("a decision was not kept for learning: #{inspect(reason, limit: 5)}")
    :ok
  end
end
