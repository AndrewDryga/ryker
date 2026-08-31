defmodule Responder.Slack.ActionTokensTest do
  use ExUnit.Case, async: true

  alias Responder.Slack.ActionTokens

  test "keeps a Slack action token only in memory for one logical turn and three searches" do
    clock = start_supervised!({Agent, fn -> 1_000 end})

    tokens =
      start_supervised!({
        ActionTokens,
        clock: fn -> Agent.get(clock, & &1) end, name: nil, ttl_ms: 60_000
      })

    assert ActionTokens.remember(tokens, "Ev-1", "xact-secret") == :ok

    for _call <- 1..3 do
      assert ActionTokens.checkout(tokens, "Ev-1", "turn-1") == {:ok, "xact-secret"}
    end

    assert ActionTokens.checkout(tokens, "Ev-1", "turn-1") ==
             {:error, :slack_search_budget_exhausted}

    assert ActionTokens.checkout(tokens, "Ev-1", "turn-2") ==
             {:error, :slack_action_token_not_authorized}

    Agent.update(clock, &(&1 + 60_001))

    assert ActionTokens.checkout(tokens, "Ev-1", "turn-1") ==
             {:error, :slack_action_token_unavailable}
  end

  test "reconciles exact event retries and rejects crossed token identity" do
    tokens = start_supervised!({ActionTokens, name: nil})

    assert ActionTokens.remember(tokens, "Ev-1", "xact-secret") == :ok
    assert ActionTokens.remember(tokens, "Ev-1", "xact-secret") == :ok

    assert ActionTokens.remember(tokens, "Ev-1", "different-secret") ==
             {:error, :slack_action_token_conflict}

    assert ActionTokens.remember(tokens, "", "xact-secret") ==
             {:error, :invalid_slack_action_token}

    assert ActionTokens.remember(tokens, "Ev-2", String.duplicate("x", 4_097)) ==
             {:error, :invalid_slack_action_token}
  end

  test "default and malformed action-token configuration stays bounded" do
    tokens = start_supervised!({ActionTokens, name: nil})

    assert ActionTokens.checkout(tokens, "missing-event", "turn-1") ==
             {:error, :slack_action_token_unavailable}

    assert ActionTokens.checkout(tokens, "", "turn-1") ==
             {:error, :slack_action_token_unavailable}

    assert ActionTokens.checkout(tokens, "event-1", :invalid) ==
             {:error, :slack_action_token_unavailable}

    assert_raise ArgumentError, ~r/options are invalid/, fn ->
      ActionTokens.options!(:invalid)
    end

    assert_raise ArgumentError, ~r/options are invalid/, fn ->
      ActionTokens.options!(ttl_ms: 1_000, ttl_ms: 2_000)
    end

    assert_raise ArgumentError, ~r/options are invalid/, fn ->
      ActionTokens.options!(unknown: true)
    end

    assert_raise ArgumentError, ~r/clock is invalid/, fn ->
      ActionTokens.options!(clock: :invalid)
    end

    assert_raise ArgumentError, ~r/name is invalid/, fn ->
      ActionTokens.options!(name: "invalid")
    end

    assert_raise ArgumentError, ~r/lifetime is invalid/, fn ->
      ActionTokens.options!(ttl_ms: 999)
    end
  end
end
