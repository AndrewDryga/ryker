defmodule Ryker.ControlPlane.ThreadContext do
  @moduledoc """
  The way from one Slack message to every message of its thread: Activity,
  narrowed to that thread, linked from the header of the message's page and
  of the request's.

  A message's page used to close with the twenty messages nearest it as a
  chapter of its own. Andrew, 2026-09-28: "drop this, just add link here to
  show all messages in thread too".
  """
  alias Ryker.ControlPlane.Activity
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo

  @label "All messages in this thread"

  @doc """
  The link to every message of `entry`'s Slack thread, or nil when the
  message is not in a thread or is the only message there.
  """
  @spec link(Entry.t()) :: %{href: String.t(), label: String.t()} | nil
  def link(%Entry{destination_transport: "slack", destination_thread_ref: thread} = entry)
      when is_binary(thread) do
    others? = Repo.exists?(Entry.Query.others_in_thread(entry))

    if others?, do: thread_link("slack", entry.destination_conversation_ref, thread)
  end

  def link(_entry), do: nil

  @doc "The link to a Slack thread's messages, for a request that has one."
  @spec thread_link(String.t(), String.t(), String.t()) :: %{href: String.t(), label: String.t()}
  def thread_link(transport, conversation, thread),
    do: %{href: Activity.conversation_path(transport, conversation, thread), label: @label}
end
