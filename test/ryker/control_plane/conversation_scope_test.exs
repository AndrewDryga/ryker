defmodule Ryker.ControlPlane.ConversationScopeTest do
  @moduledoc """
  The link from a request to every request of its conversation says what that
  conversation is. "All 7 requests in this conversation" opened every thread
  of a Slack channel and read as one thread (Andrew, 2026-10-16): a channel is
  named, a direct message says so, and anything else stays a conversation.
  """
  # Slack's names are one globally named cache, so this module runs on its own.
  use Ryker.DataCase, async: false
  alias Ryker.ControlPlane.Activity
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Slack.Names

  @workspace "T0SCOPE001"

  setup do
    start_supervised!(
      {Names,
       workspace: @workspace,
       workspace_url: "https://acme.slack.com",
       fetch: fn _ref -> {:error, :not_asked} end}
    )

    :ok = Names.remember([{@workspace, "C0NAMED001", "emisar-test"}])
    :ok
  end

  test "a channel's requests across its threads are all the requests in #channel" do
    conversation = "slack:#{@workspace}:C0NAMED001"
    admit!(conversation, "1788562304.000100")
    admit!(conversation, "1788562399.000200")

    assert %{label: "All 2 requests in #emisar-test", href: href} =
             Activity.conversation_link("slack", conversation)

    refute href =~ "thread="
  end

  test "an unnamed channel, a direct message and anything else say what they are without an ID" do
    for {conversation, phrase} <- [
          {"slack:#{@workspace}:C0UNNAMED1", "this channel"},
          {"slack:#{@workspace}:D0DIRECT01", "this direct message"},
          {"github:pr:42", "this conversation"}
        ] do
      transport = if String.starts_with?(conversation, "github"), do: "github", else: "slack"
      admit!(conversation, "1788562304.000100", transport)
      admit!(conversation, "1788562399.000200", transport)

      assert %{label: label} = Activity.conversation_link(transport, conversation)
      assert label == "All 2 requests in #{phrase}"
    end
  end

  defp admit!(conversation, thread, transport \\ "slack") do
    id = Ecto.UUID.generate()

    {:ok, _} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          destination: %{conversation_ref: conversation, thread_ref: thread, transport: transport},
          episode_id: id,
          episode_key: "scope:#{id}",
          native_input_id: "scope:#{id}",
          turn_ref: "scope-turn:#{id}"
        })
      )
  end
end
