defmodule Responder.Admission.PromptTest do
  use ExUnit.Case, async: true

  alias Responder.Admission.{Candidate, Context, Prompt}
  alias Responder.Episodes.Episode
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Ingress.Input
  alias Responder.Slack.Input, as: SlackInput

  test "gives every provider the same generic decision instructions without duplicating its schema" do
    input = input!()

    context = %Context{
      active_episode_fingerprint: Responder.CanonicalJSON.digest([]),
      built_at: ~U[2026-08-27 12:00:01.000000Z],
      candidates: [],
      conversation_episode_count: 0,
      input: input,
      input_entry: %Entry{id: Ecto.UUID.generate()}
    }

    request = Prompt.build(context)

    assert request["context"] == %{
             "allowed_actions" => [
               "start_episode",
               "continue_episode",
               "reply",
               "react",
               "ignore"
             ],
             "candidates" => [],
             "input" => Input.model_document(input)
           }

    assert Map.keys(request) |> Enum.sort() == ["context", "instructions"]
    assert request["instructions"] =~ "Interpret the event itself"
    assert request["instructions"] =~ "Never ignore a request"
    assert request["instructions"] =~ "directed\n  at Responder."
    assert request["instructions"] =~ "history_only"
    refute request["instructions"] =~ "Grafana"
    refute request["instructions"] =~ "Terraform"
  end

  test "keeps the complete admission request within one bounded model context" do
    input = input!(%{"text" => String.duplicate("x", 45_000)})

    endpoint = %{
      occurred_at: ~U[2026-08-27 11:00:00.000000Z],
      payload: %{
        "payload" => %{
          "actor" => %{"kind" => "app", "ref" => "A123"},
          "content" => %{"text" => String.duplicate("p", 20_000)},
          "event_kind" => "message"
        }
      }
    }

    candidates =
      for _index <- 1..8 do
        episode = %Episode{
          destination_thread_ref: "older-thread",
          id: Ecto.UUID.generate(),
          state: :working,
          updated_at: ~U[2026-08-27 12:00:00.000000Z]
        }

        Candidate.new(
          episode,
          %{first: endpoint, latest: endpoint},
          "current-thread",
          ~U[2026-08-27 12:00:01.000000Z],
          1_800
        )
      end

    context = %Context{
      active_episode_fingerprint: Responder.CanonicalJSON.digest([]),
      built_at: ~U[2026-08-27 12:00:01.000000Z],
      candidates: candidates,
      conversation_episode_count: 0,
      input: input,
      input_entry: %Entry{id: Ecto.UUID.generate()}
    }

    assert Prompt.build(context) |> Jason.encode!() |> byte_size() <= 65_536
  end

  test "does not offer Slack reactions to sources that cannot perform them" do
    input = %{
      input!()
      | can_react: false,
        source: %{kind: :webhook, ref: "universal"}
    }

    context = %Context{
      active_episode_fingerprint: Responder.CanonicalJSON.digest([]),
      built_at: ~U[2026-08-27 12:00:01.000000Z],
      candidates: [],
      conversation_episode_count: 0,
      input: input,
      input_entry: %Entry{id: Ecto.UUID.generate()}
    }

    request = Prompt.build(context)

    refute "react" in request["context"]["allowed_actions"]
  end

  test "the prompt bound includes worst-case JSON escaping" do
    input = input!(%{"text" => String.duplicate("\\", 22_000)})

    endpoint = %{
      occurred_at: ~U[2026-08-27 11:00:00.000000Z],
      payload: %{
        "payload" => %{
          "actor" => %{"kind" => "app", "ref" => "A123"},
          "content" => %{"text" => String.duplicate("\\", 20_000)},
          "event_kind" => "message"
        }
      }
    }

    candidates =
      for _index <- 1..8 do
        episode = %Episode{
          destination_thread_ref: "older-thread",
          id: Ecto.UUID.generate(),
          state: :working,
          updated_at: ~U[2026-08-27 12:00:00.000000Z]
        }

        Candidate.new(
          episode,
          %{first: endpoint, latest: endpoint},
          "current-thread",
          ~U[2026-08-27 12:00:01.000000Z],
          1_800
        )
      end

    context = %Context{
      active_episode_fingerprint: Responder.CanonicalJSON.digest([]),
      built_at: ~U[2026-08-27 12:00:01.000000Z],
      candidates: candidates,
      conversation_episode_count: 0,
      input: input,
      input_entry: %Entry{id: Ecto.UUID.generate()}
    }

    assert Prompt.build(context) |> Jason.encode!() |> byte_size() <= 65_536
  end

  defp input!(content \\ %{"text" => "A message in a format added tomorrow"}) do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :app, ref: "A123"},
               channel_ref: "C456",
               content: content,
               event_kind: :message,
               event_ref: "Ev123",
               message_ref: "1787832000.000100",
               occurred_at: ~U[2026-08-27 12:00:00.000000Z],
               revision: 1,
               thread_ref: nil,
               workspace_ref: "T123"
             })

    input
  end
end
