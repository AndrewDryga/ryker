defmodule Ryker.Admission.DecisionTest do
  use ExUnit.Case, async: true

  alias Ryker.Admission.Decision

  test "parses each supported generic admission action" do
    cases = [
      {%{"action" => "start_episode", "episode_ref" => nil, "relation" => "unrelated"},
       :start_episode},
      {%{
         "action" => "continue_episode",
         "episode_ref" => "candidate-1",
         "relation" => "same_work"
       }, :continue_episode},
      {%{"action" => "reply", "episode_ref" => nil, "relation" => "unrelated"}, :reply},
      {%{
         "action" => "react",
         "episode_ref" => nil,
         "reaction" => %{"emoji_name" => "eyes"},
         "relation" => "unrelated"
       }, :react},
      {%{"action" => "ignore", "episode_ref" => nil, "relation" => "unrelated"}, :ignore}
    ]

    for {fields, expected_action} <- cases do
      assert {:ok, decision} =
               fields
               |> Map.put_new("reaction", nil)
               |> Map.put_new("repository_source", nil)
               |> Map.put("work_class", work_class(expected_action))
               |> Map.put("reason", "A short factual reason.")
               |> Decision.parse()

      assert decision.action == expected_action
    end
  end

  test "permits a new episode to carry history without reusing its destination" do
    assert {:ok, decision} =
             Decision.parse(%{
               "action" => "start_episode",
               "episode_ref" => "candidate-older-cycle",
               "reaction" => nil,
               "relation" => "history_only",
               "reason" => "This is a new lifecycle related to the older work.",
               "repository_source" => nil,
               "work_class" => "standard"
             })

    assert decision.relation == :history_only
    assert decision.episode_ref == "candidate-older-cycle"
  end

  test "rejects unknown fields and inconsistent action shapes" do
    assert {:error, {:invalid_decision, :fields}} =
             Decision.parse(%{
               "action" => "ignore",
               "episode_ref" => nil,
               "reaction" => nil,
               "relation" => "unrelated",
               "reason" => "Duplicate event.",
               "repository_source" => nil,
               "work_class" => nil,
               "thread_ts" => "the model cannot route"
             })

    assert {:error, {:invalid_decision, :episode_ref}} =
             Decision.parse(%{
               "action" => "continue_episode",
               "episode_ref" => nil,
               "reaction" => nil,
               "relation" => "same_work",
               "reason" => "Continue it.",
               "repository_source" => nil,
               "work_class" => "standard"
             })

    assert {:error, {:invalid_decision, :relation}} =
             Decision.parse(%{
               "action" => "ignore",
               "episode_ref" => "candidate-1",
               "reaction" => nil,
               "relation" => "same_work",
               "reason" => "Ignore it.",
               "repository_source" => nil,
               "work_class" => nil
             })
  end

  test "publishes an exact JSON schema for model self-validation" do
    schema = Decision.json_schema()

    assert schema["additionalProperties"] == false

    assert schema["required"] ==
             [
               "action",
               "episode_ref",
               "message",
               "reaction",
               "relation",
               "reason",
               "repository",
               "repository_source",
               "work_class"
             ]

    assert schema["properties"]["action"]["enum"] ==
             ~w(start_episode continue_episode reply quick_reply react ignore)

    assert schema["properties"]["relation"]["enum"] ==
             ~w(same_work history_only unrelated)

    assert schema["properties"]["work_class"] == %{
             "anyOf" => [
               %{"enum" => ~w(conversational standard deep), "type" => "string"},
               %{"type" => "null"}
             ]
           }

    assert length(schema["oneOf"]) == 9
  end

  test "routing answers a simple message itself, with the words it sends" do
    # Andrew, 2026-09-26: routing may give quick, simple replies without
    # starting the work model ("hi" gets "hi" back), while it still decides
    # every time whether a message starts or continues work. Routing took
    # about 27 s of a 66 s first reply before the work model even started.
    greeting = "Hi! What can I help with?"

    assert {:ok, decision} =
             Decision.parse(quick_reply(greeting))

    assert decision.action == :quick_reply
    assert decision.message == greeting
    assert Decision.document(decision)["message"] == greeting

    # Only a quick reply carries words, and it always does; it continues no
    # work and needs no class of work.
    for document <- [
          quick_reply(nil),
          quick_reply("   "),
          quick_reply(String.duplicate("a", 1_001)),
          decision_document(action: "reply", message: greeting),
          decision_document(action: "ignore", work_class: nil, message: greeting),
          Map.put(quick_reply(greeting), "work_class", "conversational"),
          Map.merge(quick_reply(greeting), %{
            "episode_ref" => "candidate-1",
            "relation" => "same_work"
          })
        ] do
      assert {:error, {:invalid_decision, _field}} = Decision.parse(document)
    end

    # A decision recorded before quick replies has no message and still reads.
    assert {:ok, %{message: nil}} =
             decision_document([]) |> Map.delete("message") |> Decision.parse()

    # A retry that only rephrases the reply is the same decision.
    assert {:ok, rephrased} = Decision.parse(quick_reply("Hello! How can I help?"))
    assert Decision.fingerprint(decision) == Decision.fingerprint(rephrased)

    # The published schema offers it with its words, and only where offered.
    schema = Decision.json_schema([:quick_reply, :ignore])
    assert schema["properties"]["action"]["enum"] == ~w(quick_reply ignore)

    assert [%{"properties" => %{"message" => message}} | _rest] =
             Enum.filter(schema["oneOf"], &(&1["properties"]["action"]["const"] == "quick_reply"))

    assert message["type"] == "string"
    assert message["maxLength"] == 1_000
  end

  test "schema-valid Unicode and text boundaries are accepted by the host parser" do
    schema = JSV.build!(Decision.json_schema())

    valid = decision_document(reason: String.duplicate("🙂", 512))
    assert {:ok, ^valid} = JSV.validate(valid, schema, cast: false)
    assert {:ok, _decision} = Decision.parse(valid)

    for reason <- ["", " \n\t", <<0>>, String.duplicate("x", 513)] do
      document = decision_document(reason: reason)
      assert {:error, _validation_error} = JSV.validate(document, schema, cast: false)
      assert {:error, {:invalid_decision, :reason}} = Decision.parse(document)
    end
  end

  test "a reaction is complete enough for the Slack gateway to execute" do
    assert {:ok, decision} =
             Decision.parse(%{
               "action" => "react",
               "episode_ref" => nil,
               "reaction" => %{"emoji_name" => "white_check_mark"},
               "relation" => "unrelated",
               "reason" => "Acknowledge the update without adding another message.",
               "repository_source" => nil,
               "work_class" => nil
             })

    assert decision.reaction == %{emoji_name: "white_check_mark"}

    assert {:error, {:invalid_decision, :reaction}} =
             Decision.parse(%{
               "action" => "react",
               "episode_ref" => nil,
               "reaction" => nil,
               "relation" => "unrelated",
               "reason" => "This cannot be delivered without an emoji name.",
               "repository_source" => nil,
               "work_class" => nil
             })
  end

  test "retry identity ignores prose but retains every executable choice" do
    assert {:ok, first} =
             Decision.parse(%{
               "action" => "react",
               "episode_ref" => nil,
               "reaction" => %{"emoji_name" => "eyes"},
               "relation" => "unrelated",
               "reason" => "Acknowledge this update.",
               "repository_source" => nil,
               "work_class" => nil
             })

    paraphrased = %{first | reason: "The update only needs an acknowledgement."}
    different = %{first | reaction: %{emoji_name: "thumbsup"}}

    assert Decision.fingerprint(first) == Decision.fingerprint(paraphrased)
    refute Decision.fingerprint(first) == Decision.fingerprint(different)
  end

  test "rejects every malformed executable shape without raising" do
    cases = [
      {decision_document(action: "unknown"), :action},
      {decision_document(relation: "unknown"), :relation},
      {decision_document(episode_ref: " "), :episode_ref},
      {decision_document(reaction: %{"emoji_name" => "Eyes!"}), :reaction},
      {decision_document(action: "start_episode", reaction: %{"emoji_name" => "eyes"}),
       :reaction},
      {decision_document(action: "start_episode", relation: "history_only"), :episode_ref},
      {decision_document(action: "reply", relation: "history_only"), :episode_ref},
      {decision_document(
         action: "react",
         episode_ref: "candidate-1",
         reaction: %{"emoji_name" => "eyes"}
       ), :relation},
      {decision_document(action: "reply", work_class: "standard"), :work_class},
      {decision_document(action: "start_episode", work_class: "conversational"), :work_class},
      {decision_document(action: "ignore", work_class: "deep"), :work_class}
    ]

    for {document, field} <- cases do
      assert {:error, {:invalid_decision, ^field}} = Decision.parse(document)
    end

    assert {:error, {:invalid_decision, :type}} = Decision.parse("not an object")
    assert {:error, {:invalid_decision, :type}} = Decision.prepare(%{})
  end

  test "limits the published action enum to the source capabilities" do
    schema = Decision.json_schema([:start_episode, :reply, :ignore])
    assert schema["properties"]["action"]["enum"] == ~w(start_episode reply ignore)
    assert length(schema["oneOf"]) == 6
  end

  test "limits reactions to the names issued by the source adapter" do
    schema = Decision.json_schema([:start_episode, :react, :ignore], ~w(+1 eyes heart))

    assert schema["properties"]["reaction"]["anyOf"] |> hd() == %{
             "additionalProperties" => false,
             "properties" => %{
               "emoji_name" => %{"enum" => ~w(+1 eyes heart), "type" => "string"}
             },
             "required" => ["emoji_name"],
             "type" => "object"
           }

    built = JSV.build!(schema)

    assert {:ok, _document} =
             JSV.validate(
               decision_document(
                 action: "react",
                 reaction: %{"emoji_name" => "heart"},
                 work_class: nil
               ),
               built,
               cast: false
             )

    assert {:error, _validation_error} =
             JSV.validate(
               decision_document(
                 action: "react",
                 reaction: %{"emoji_name" => "white_check_mark"},
                 work_class: nil
               ),
               built,
               cast: false
             )
  end

  test "only a new repository-backed episode may select a repository source" do
    branch = %{"kind" => "branch", "name" => "feature/payments"}

    assert {:ok, decision} =
             Decision.parse(%{
               "action" => "start_episode",
               "episode_ref" => nil,
               "reaction" => nil,
               "relation" => "unrelated",
               "reason" => "Review the named branch.",
               "repository_source" => branch,
               "work_class" => "standard"
             })

    assert decision.repository_source == branch
    assert Decision.document(decision)["repository_source"] == branch

    rebinding = [
      {"continue_episode", "candidate-1", "same_work", "standard"},
      {"reply", "candidate-1", "same_work", "conversational"},
      {"reply", nil, "unrelated", "conversational"},
      {"react", nil, "unrelated", nil},
      {"ignore", nil, "unrelated", nil}
    ]

    for {action, episode_ref, relation, work_class} <- rebinding do
      document = %{
        "action" => action,
        "episode_ref" => episode_ref,
        "reaction" => if(action == "react", do: %{"emoji_name" => "eyes"}, else: nil),
        "relation" => relation,
        "reason" => "A short factual reason.",
        "repository_source" => branch,
        "work_class" => work_class
      }

      assert Decision.parse(document) == {:error, {:invalid_decision, :repository_source}},
             "expected #{action} to be unable to rebind source"
    end
  end

  test "a malformed selector is refused as a decision field, not repaired" do
    for invalid <- [
          %{"kind" => "tag", "name" => "v1"},
          %{"kind" => "branch", "name" => "refs/heads/main"},
          %{"kind" => "commit", "sha" => String.duplicate("A", 40)},
          %{"kind" => "pull_request", "number" => 0},
          "main"
        ] do
      document = %{
        "action" => "start_episode",
        "episode_ref" => nil,
        "reaction" => nil,
        "relation" => "unrelated",
        "reason" => "Review the named source.",
        "repository_source" => invalid,
        "work_class" => "standard"
      }

      assert Decision.parse(document) == {:error, {:invalid_decision, :repository_source}}
    end
  end

  test "a retry that changes only the selector is a different durable decision" do
    document = fn source ->
      %{
        "action" => "start_episode",
        "episode_ref" => nil,
        "reaction" => nil,
        "relation" => "unrelated",
        "reason" => "Review the named branch.",
        "repository_source" => source,
        "work_class" => "standard"
      }
    end

    assert {:ok, branch} = Decision.parse(document.(%{"kind" => "branch", "name" => "one"}))
    assert {:ok, other} = Decision.parse(document.(%{"kind" => "branch", "name" => "two"}))
    assert {:ok, none} = Decision.parse(document.(nil))

    assert Decision.fingerprint(branch) != Decision.fingerprint(other)
    assert Decision.fingerprint(branch) != Decision.fingerprint(none)
  end

  test "a route without a repository publishes a null-only selector" do
    schema = Decision.json_schema([:start_episode, :reply, :ignore], :any)
    assert schema["properties"]["repository_source"] == %{"type" => "null"}

    built = JSV.build!(schema)

    assert {:error, _invalid} =
             JSV.validate(
               decision_document(
                 action: "start_episode",
                 relation: "unrelated",
                 repository_source: %{"kind" => "default"},
                 work_class: "standard"
               ),
               built,
               cast: false
             )
  end

  test "a repository-backed route publishes the selector only on a new episode" do
    schema = Decision.json_schema([:start_episode, :continue_episode, :reply], :any, true)
    built = JSV.build!(schema)

    assert {:ok, _valid} =
             JSV.validate(
               decision_document(
                 action: "start_episode",
                 relation: "unrelated",
                 repository_source: %{"kind" => "branch", "name" => "feature/payments"},
                 work_class: "standard"
               ),
               built,
               cast: false
             )

    assert {:error, _invalid} =
             JSV.validate(
               decision_document(
                 action: "continue_episode",
                 episode_ref: "candidate-1",
                 relation: "same_work",
                 repository_source: %{"kind" => "branch", "name" => "feature/payments"},
                 work_class: "standard"
               ),
               built,
               cast: false
             )

    assert {:ok, _valid} =
             JSV.validate(
               decision_document(
                 action: "continue_episode",
                 episode_ref: "candidate-1",
                 relation: "same_work",
                 work_class: "standard"
               ),
               built,
               cast: false
             )
  end

  # A route in an environment with several repositories offers them, and a new
  # episode names the one its work changes. Before, every episode in such an
  # environment changed the environment's first repository whatever the event
  # was about, so a task on any other repository ran against the wrong working
  # copy; the choice is the model's because only the event says which
  # repository it concerns.
  test "a new episode names which offered repository it changes, and nothing else may" do
    chosen =
      decision_document(
        action: "start_episode",
        relation: "unrelated",
        repository: "billing",
        work_class: "standard"
      )

    assert {:ok, decision} = Decision.parse(chosen)
    assert decision.repository == "billing"
    assert Decision.document(decision)["repository"] == "billing"

    assert Decision.fingerprint(decision) !=
             Decision.fingerprint(%{decision | repository: "ledger"})

    # Every other action keeps the repository its work already pinned.
    for document <- [
          decision_document(repository: "billing"),
          decision_document(
            action: "continue_episode",
            episode_ref: "candidate-1",
            relation: "same_work",
            repository: "billing",
            work_class: "standard"
          ),
          decision_document(action: "ignore", repository: "billing", work_class: nil)
        ] do
      assert Decision.parse(document) == {:error, {:invalid_decision, :repository}}
    end

    for invalid <- ["", " ", 7, %{"ref" => "billing"}] do
      assert Decision.parse(Map.put(chosen, "repository", invalid)) ==
               {:error, {:invalid_decision, :repository}}
    end

    # A decision recorded before the field existed carries no key: it chose
    # nothing, the same as null. Recorded answers are history, not rewritten.
    assert {:ok, %Decision{repository: nil}} = Decision.parse(Map.delete(chosen, "repository"))

    # The published contract offers exactly the route's repositories, on a new
    # episode only, and requires the choice there.
    schema =
      Decision.json_schema([:start_episode, :reply, :ignore], :any, true, ["billing", "ledger"])

    assert "repository" in schema["required"]

    assert schema["properties"]["repository"] == %{
             "anyOf" => [
               %{"enum" => ["billing", "ledger"], "type" => "string"},
               %{"type" => "null"}
             ]
           }

    built = JSV.build!(schema)
    assert {:ok, _valid} = JSV.validate(chosen, built, cast: false)

    for refused <- [
          Map.put(chosen, "repository", nil),
          Map.put(chosen, "repository", "elsewhere"),
          decision_document(repository: "billing")
        ] do
      assert {:error, _invalid} = JSV.validate(refused, built, cast: false)
    end

    assert {:ok, _valid} = JSV.validate(decision_document([]), built, cast: false)

    # With one repository or none there is nothing to choose.
    schema = Decision.json_schema([:start_episode, :reply, :ignore], :any, true)
    assert schema["properties"]["repository"] == %{"type" => "null"}
    assert {:error, _invalid} = JSV.validate(chosen, JSV.build!(schema), cast: false)
  end

  defp decision_document(overrides) do
    defaults = %{
      "action" => "reply",
      "episode_ref" => nil,
      "message" => nil,
      "reaction" => nil,
      "relation" => "unrelated",
      "reason" => "Answer directly.",
      "repository" => nil,
      "repository_source" => nil,
      "work_class" => "conversational"
    }

    Enum.reduce(overrides, defaults, fn {key, value}, document ->
      Map.put(document, Atom.to_string(key), value)
    end)
  end

  defp quick_reply(message),
    do: decision_document(action: "quick_reply", work_class: nil, message: message)

  defp work_class(action) when action in [:react, :ignore], do: nil
  defp work_class(:reply), do: "conversational"
  defp work_class(_action), do: "standard"
end
