defmodule Ryker.Slack.Client.FieldsTest do
  # The model's tool arguments and the Slack client each held these bounds
  # until 2026-10-08.
  use ExUnit.Case, async: true
  alias Ryker.Slack.Client.Fields

  test "a listing asks Slack for at most 200 conversations or 100 messages" do
    assert Fields.conversation_limit(200) == {:ok, 200}
    assert Fields.conversation_limit(201) == {:error, :limit}
    assert Fields.message_limit(100) == {:ok, 100}
    assert Fields.message_limit(0) == {:error, :limit}
    assert Fields.message_limit("5") == {:error, :limit}
    assert Fields.listing_boolean(true) == {:ok, true}
    assert Fields.listing_boolean("true") == {:error, :boolean}
  end
end
