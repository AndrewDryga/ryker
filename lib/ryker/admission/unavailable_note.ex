defmodule Ryker.Admission.UnavailableNote do
  @moduledoc """
  What a person hears when Ryker cannot read their message because the model
  account it runs on needs attention.

  On 2026-09-26 that account ran out of usage for three days: every message
  stopped on Failures, and a person who asked Ryker something in Slack heard
  nothing at all. A person who mentioned Ryker or wrote to it directly is now
  told, in fixed words and at most once a thread a day. An app's message, a
  message not meant for Ryker and any failure a retry may cure are left
  alone.
  """
  alias Ryker.Delivery
  alias Ryker.Ingress
  alias Ryker.Work

  @message "I can't reply right now: the AI model account I run on needs attention. " <>
             "The people who manage me can see this in Ryker, and once it's fixed they " <>
             "can have me read your message again."

  @doc """
  The note for this input and the saved error that stopped it, or nil when
  nothing should be said. Its reference names the thread and the day, so the
  publisher finds a note it already posted there instead of posting another.
  """
  @spec note(Ingress.Inbox.Entry.t(), String.t(), DateTime.t()) :: Delivery.HostNote.t() | nil
  def note(%Ingress.Inbox.Entry{} = entry, detail, %DateTime{} = now) do
    if addressed_person?(entry) and Work.FailureCause.account_problem?(detail) do
      %Delivery.HostNote{
        conversation_ref: entry.destination_conversation_ref,
        execution_mode: entry.execution_mode,
        message: @message,
        ref:
          "model-unavailable:#{entry.destination_conversation_ref}:" <>
            "#{entry.destination_thread_ref}:#{Date.to_iso8601(DateTime.to_date(now))}",
        thread_ref: entry.destination_thread_ref,
        transport: entry.destination_transport
      }
    end
  end

  defp addressed_person?(%Ingress.Inbox.Entry{
         source_kind: "slack",
         destination_transport: "slack",
         actor_kind: :user,
         execution_mode: :live,
         slack_audience: audience
       })
       when audience in [:mention, :direct],
       do: true

  defp addressed_person?(_entry), do: false
end
