defmodule Responder.Slack.HomeSubmissionTest do
  use ExUnit.Case, async: true

  alias Responder.Slack.HomeSubmission

  @now ~U[2026-09-04 12:00:00.000000Z]

  test "accepts only the exact host-owned memory editor submission" do
    assert {:ok, submission} = HomeSubmission.from_socket(envelope(), "T123", @now)

    assert submission.action == :edit_memory_review
    assert submission.actor_ref == "U123"
    assert submission.event_ref == "interaction:env-home-edit"
    assert submission.resource_ref == "memory-review:abc-123"

    assert submission.replacement == %{
             "subject" => "checkout-api",
             "value" => "Inspect the production SLO first."
           }

    assert envelope()
           |> put_in(["payload", "team", "id"], "T999")
           |> HomeSubmission.from_socket("T123", @now) == :ignore

    assert envelope()
           |> put_in(["payload", "view", "callback_id"], "model_owned_editor")
           |> HomeSubmission.from_socket("T123", @now) == :ignore

    assert envelope()
           |> put_in(["payload", "view", "private_metadata"], "not-json")
           |> HomeSubmission.from_socket("T123", @now) == :ignore

    assert envelope()
           |> put_in(
             ["payload", "view", "private_metadata"],
             Jason.encode!(%{"review_ref" => "memory-review:abc-123", "foreign" => true})
           )
           |> HomeSubmission.from_socket("T123", @now) == :ignore

    assert envelope()
           |> put_in(
             ["payload", "view", "state", "values", "foreign"],
             %{"value" => %{"type" => "plain_text_input", "value" => "surprise"}}
           )
           |> HomeSubmission.from_socket("T123", @now) == :ignore

    assert envelope()
           |> put_in(["payload", "view", "private_metadata"], %{})
           |> HomeSubmission.from_socket("T123", @now) == :ignore

    assert envelope()
           |> put_in(["payload", "view", "state", "values"], [])
           |> HomeSubmission.from_socket("T123", @now) == :ignore

    assert envelope()
           |> put_in(
             ["payload", "view", "state", "values", "memory_value", "value"],
             %{"type" => "plain_text_input", "selected_option" => nil}
           )
           |> HomeSubmission.from_socket("T123", @now) ==
             {:error,
              %{
                "memory_value" => "Enter non-empty guidance of at most 4000 characters."
              }}

    unicode =
      envelope()
      |> put_in(
        ["payload", "view", "state", "values", "memory_subject", "subject", "value"],
        String.duplicate("é", 120)
      )
      |> put_in(
        ["payload", "view", "state", "values", "memory_value", "value", "value"],
        String.duplicate("🙂", 4_000)
      )

    assert {:ok, unicode_submission} = HomeSubmission.from_socket(unicode, "T123", @now)
    assert String.length(unicode_submission.replacement["subject"]) == 120
    assert String.length(unicode_submission.replacement["value"]) == 4_000
  end

  defp envelope do
    %{
      "envelope_id" => "env-home-edit",
      "payload" => %{
        "team" => %{"id" => "T123"},
        "type" => "view_submission",
        "user" => %{"id" => "U123"},
        "view" => %{
          "callback_id" => "responder_home_edit_memory_review",
          "private_metadata" => Jason.encode!(%{"review_ref" => "memory-review:abc-123"}),
          "state" => %{
            "values" => %{
              "memory_subject" => %{
                "subject" => %{"type" => "plain_text_input", "value" => " checkout-api "}
              },
              "memory_value" => %{
                "value" => %{
                  "type" => "plain_text_input",
                  "value" => " Inspect the production SLO first. "
                }
              }
            }
          },
          "type" => "modal"
        }
      },
      "type" => "interactive"
    }
  end
end
