defmodule Ryker.Admission.DecisionTest do
  use ExUnit.Case, async: true

  alias Ryker.Admission.Decision

  test "parses each supported generic admission action" do
    cases = [
      {decision_document(action: "start_episode", work_class: "standard"), :start_episode},
      {decision_document(
         action: "continue_episode",
         episode_ref: "candidate-1",
         relation: "same_work",
         work_class: "standard"
       ), :continue_episode},
      {decision_document(action: "reply"), :reply},
      {decision_document(action: "quick_reply", messages: ["Hi!"], work_class: nil),
       :quick_reply},
      {decision_document(action: "react", reactions: ["eyes"], work_class: nil), :react},
      {decision_document(action: "ignore", work_class: nil), :ignore}
    ]

    for {document, expected_action} <- cases do
      assert {:ok, decision} = Decision.parse(document)
      assert decision.action == expected_action
    end
  end

  test "permits a new episode to carry history without reusing its destination" do
    assert {:ok, decision} =
             Decision.parse(
               decision_document(
                 action: "start_episode",
                 episode_ref: "candidate-older-cycle",
                 relation: "history_only",
                 reason: "This is a new lifecycle related to the older work.",
                 work_class: "standard"
               )
             )

    assert decision.relation == :history_only
    assert decision.episode_ref == "candidate-older-cycle"
  end

  test "rejects unknown fields and inconsistent action shapes" do
    assert {:error, {:invalid_decision, :fields}} =
             decision_document(action: "ignore", work_class: nil)
             |> Map.put("thread_ts", "the model cannot route")
             |> Decision.parse()

    assert {:error, {:invalid_decision, :episode_ref}} =
             Decision.parse(
               decision_document(
                 action: "continue_episode",
                 relation: "same_work",
                 work_class: "standard"
               )
             )

    assert {:error, {:invalid_decision, :relation}} =
             Decision.parse(
               decision_document(
                 action: "ignore",
                 episode_ref: "candidate-1",
                 relation: "same_work",
                 work_class: nil
               )
             )
  end

  # Andrew, 2026-09-26, wrote "Now both reply and add a reaction" to Ryker in
  # Slack. Routing could answer by itself with one message or one emoji, never
  # both, so it started a whole work run: 1 min 22 s for a greeting and a 👍.
  # A quick answer is now one to three messages sent in order, with up to three
  # emoji on the person's message; a reaction alone is one to three emoji.
  test "routing answers with a few messages and emoji, and refuses each shape in the field to fix" do
    both =
      decision_document(
        action: "quick_reply",
        messages: ["Hi again!", "Want me to look at the deploy too?"],
        reactions: ["thumbsup"],
        work_class: nil
      )

    assert {:ok, decision} = Decision.parse(both)
    assert decision.messages == ["Hi again!", "Want me to look at the deploy too?"]
    assert decision.reactions == ["thumbsup"]
    assert Decision.document(decision) == both

    # The emoji on a quick answer are optional; a reaction alone may carry a few.
    assert {:ok, %Decision{reactions: nil}} =
             Decision.parse(Map.put(both, "reactions", nil))

    assert {:ok, %Decision{reactions: ["eyes", "white_check_mark"]}} =
             Decision.parse(
               decision_document(
                 action: "react",
                 reactions: ["eyes", "white_check_mark"],
                 work_class: nil
               )
             )

    words = fn messages -> Map.put(both, "messages", messages) end
    emoji = fn reactions -> Map.put(both, "reactions", reactions) end

    refusals = [
      {words.(nil), :messages},
      {words.([]), :messages},
      {words.(["one", "two", "three", "four"]), :messages},
      {words.(["Hi!", "   "]), :messages},
      {words.([String.duplicate("a", 1_001)]), :messages},
      {words.("Hi again!"), :messages},
      {emoji.([]), :reactions},
      {emoji.(["eyes", "eyes"]), :reactions},
      {emoji.(["eyes", "heart", "rocket", "tada"]), :reactions},
      {emoji.(["Thumbs Up!"]), :reactions},
      {emoji.("thumbsup"), :reactions},
      {decision_document(action: "react", work_class: nil), :reactions},
      {decision_document(action: "react", reactions: ["eyes"], messages: ["Hi"], work_class: nil),
       :messages},
      {decision_document(action: "reply", messages: ["Hi"]), :messages},
      {decision_document(action: "start_episode", reactions: ["eyes"], work_class: "standard"),
       :reactions},
      {decision_document(action: "ignore", reactions: ["eyes"], work_class: nil), :reactions}
    ]

    for {document, field} <- refusals do
      assert Decision.parse(document) == {:error, {:invalid_decision, field}},
             "expected #{inspect(document["messages"])} / #{inspect(document["reactions"])} " <>
               "on #{document["action"]} to be refused as #{field}"
    end

    # A retry that only rephrases the words is the same decision; another emoji is not.
    assert {:ok, rephrased} = Decision.parse(words.(["Hello again!"]))
    assert {:ok, other_emoji} = Decision.parse(emoji.(["tada"]))
    assert Decision.fingerprint(decision) == Decision.fingerprint(rephrased)
    refute Decision.fingerprint(decision) == Decision.fingerprint(other_emoji)
  end

  test "the published contract offers several messages and emoji only where they are sent" do
    schema = Decision.json_schema([:quick_reply, :react, :ignore], :any)
    built = JSV.build!(schema)

    [quick_reply] = shapes(schema, "quick_reply")
    [react] = shapes(schema, "react")
    [ignore] = shapes(schema, "ignore")

    assert quick_reply["properties"]["messages"] == %{
             "items" => %{
               "maxLength" => 1_000,
               "minLength" => 1,
               "pattern" => "^[^\\x00]*[^\\s\\x00][^\\x00]*$",
               "type" => "string"
             },
             "maxItems" => 3,
             "minItems" => 1,
             "type" => "array"
           }

    assert %{"anyOf" => [reactions, %{"type" => "null"}]} = quick_reply["properties"]["reactions"]
    assert react["properties"]["reactions"] == reactions
    assert reactions["maxItems"] == 3 and reactions["minItems"] == 1
    assert reactions["uniqueItems"] == true
    assert react["properties"]["messages"] == %{"type" => "null"}
    assert ignore["properties"]["messages"] == %{"type" => "null"}
    assert ignore["properties"]["reactions"] == %{"type" => "null"}

    andrew =
      decision_document(
        action: "quick_reply",
        messages: ["Hi again!"],
        reactions: ["thumbsup"],
        work_class: nil
      )

    assert {:ok, _valid} = JSV.validate(andrew, built, cast: false)

    for refused <- [
          Map.put(andrew, "messages", ["one", "two", "three", "four"]),
          Map.put(andrew, "reactions", ["eyes", "eyes"]),
          decision_document(action: "ignore", reactions: ["eyes"], work_class: nil)
        ] do
      assert {:error, _invalid} = JSV.validate(refused, built, cast: false)
    end

    # A source that cannot take a reaction is offered a quick answer in words only.
    words_only = Decision.json_schema([:start_episode, :quick_reply, :ignore], nil)
    [quick_reply] = shapes(words_only, "quick_reply")
    assert quick_reply["properties"]["reactions"] == %{"type" => "null"}

    assert {:error, _invalid} = JSV.validate(andrew, JSV.build!(words_only), cast: false)

    # The source's own emoji names bound every reaction list.
    named = Decision.json_schema([:quick_reply, :react, :ignore], ~w(+1 eyes heart))
    [react] = shapes(named, "react")

    assert react["properties"]["reactions"]["items"] == %{
             "enum" => ~w(+1 eyes heart),
             "type" => "string"
           }

    assert {:ok, _valid} =
             JSV.validate(
               decision_document(action: "react", reactions: ["+1", "heart"], work_class: nil),
               JSV.build!(named),
               cast: false
             )

    assert {:error, _invalid} =
             JSV.validate(
               decision_document(action: "react", reactions: ["thumbsup"], work_class: nil),
               JSV.build!(named),
               cast: false
             )
  end

  # The decision documents stored before 2026-09-27 were rewritten into this
  # shape by the migration that introduced it, so nothing reads an older one:
  # a missing field, or `message` and `reaction` from before, is refused.
  test "a decision is read only in the shape routing answers in" do
    current = decision_document([])
    assert {:ok, _decision} = Decision.parse(current)

    for field <- ~w(messages reactions repository repository_source) do
      assert Decision.parse(Map.delete(current, field)) == {:error, {:invalid_decision, :fields}}
    end

    for {old, value} <- [{"message", nil}, {"reaction", nil}] do
      assert Decision.parse(Map.put(current, old, value)) ==
               {:error, {:invalid_decision, :fields}}
    end
  end

  test "publishes an exact JSON schema for model self-validation" do
    schema = Decision.json_schema()

    assert schema["additionalProperties"] == false

    assert schema["required"] ==
             [
               "action",
               "episode_ref",
               "messages",
               "reactions",
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

    assert {:ok, decision} = Decision.parse(quick_reply([greeting]))

    assert decision.action == :quick_reply
    assert decision.messages == [greeting]
    assert Decision.document(decision)["messages"] == [greeting]

    # Only a quick reply carries words, and it always does; it continues no
    # work and needs no class of work.
    for document <- [
          quick_reply(nil),
          quick_reply(["   "]),
          quick_reply([String.duplicate("a", 1_001)]),
          decision_document(action: "reply", messages: [greeting]),
          decision_document(action: "ignore", work_class: nil, messages: [greeting]),
          Map.put(quick_reply([greeting]), "work_class", "conversational"),
          Map.merge(quick_reply([greeting]), %{
            "episode_ref" => "candidate-1",
            "relation" => "same_work"
          })
        ] do
      assert {:error, {:invalid_decision, _field}} = Decision.parse(document)
    end

    # The published schema offers it with its words, and only where offered.
    schema = Decision.json_schema([:quick_reply, :ignore])
    assert schema["properties"]["action"]["enum"] == ~w(quick_reply ignore)

    assert [%{"properties" => %{"messages" => messages}}] = shapes(schema, "quick_reply")
    assert messages["type"] == "array"
    assert messages["items"]["maxLength"] == 1_000
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
             Decision.parse(
               decision_document(
                 action: "react",
                 reactions: ["white_check_mark"],
                 reason: "Acknowledge the update without adding another message.",
                 work_class: nil
               )
             )

    assert decision.reactions == ["white_check_mark"]

    assert {:error, {:invalid_decision, :reactions}} =
             Decision.parse(
               decision_document(
                 action: "react",
                 reason: "This cannot be delivered without an emoji name.",
                 work_class: nil
               )
             )
  end

  test "retry identity ignores prose but retains every executable choice" do
    assert {:ok, first} =
             Decision.parse(
               decision_document(
                 action: "react",
                 reactions: ["eyes"],
                 reason: "Acknowledge this update.",
                 work_class: nil
               )
             )

    paraphrased = %{first | reason: "The update only needs an acknowledgement."}
    different = %{first | reactions: ["thumbsup"]}

    assert Decision.fingerprint(first) == Decision.fingerprint(paraphrased)
    refute Decision.fingerprint(first) == Decision.fingerprint(different)
  end

  test "rejects every malformed executable shape without raising" do
    cases = [
      {decision_document(action: "unknown"), :action},
      {decision_document(relation: "unknown"), :relation},
      {decision_document(episode_ref: " "), :episode_ref},
      {decision_document(action: "react", reactions: ["Eyes!"], work_class: nil), :reactions},
      {decision_document(action: "start_episode", reactions: ["eyes"], work_class: "standard"),
       :reactions},
      {decision_document(action: "start_episode", relation: "history_only"), :episode_ref},
      {decision_document(action: "reply", relation: "history_only"), :episode_ref},
      {decision_document(
         action: "react",
         episode_ref: "candidate-1",
         reactions: ["eyes"],
         work_class: nil
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

    assert schema["properties"]["reactions"]["anyOf"] |> hd() == %{
             "items" => %{"enum" => ~w(+1 eyes heart), "type" => "string"},
             "maxItems" => 3,
             "minItems" => 1,
             "type" => "array",
             "uniqueItems" => true
           }

    built = JSV.build!(schema)

    assert {:ok, _document} =
             JSV.validate(
               decision_document(action: "react", reactions: ["heart"], work_class: nil),
               built,
               cast: false
             )

    assert {:error, _validation_error} =
             JSV.validate(
               decision_document(
                 action: "react",
                 reactions: ["white_check_mark"],
                 work_class: nil
               ),
               built,
               cast: false
             )
  end

  test "only a new repository-backed episode may select a repository source" do
    branch = %{"kind" => "branch", "name" => "feature/payments"}

    assert {:ok, decision} =
             Decision.parse(
               decision_document(
                 action: "start_episode",
                 reason: "Review the named branch.",
                 repository_source: branch,
                 work_class: "standard"
               )
             )

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
      document =
        decision_document(
          action: action,
          episode_ref: episode_ref,
          reactions: if(action == "react", do: ["eyes"]),
          relation: relation,
          reason: "A short factual reason.",
          repository_source: branch,
          work_class: work_class
        )

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
      document =
        decision_document(
          action: "start_episode",
          reason: "Review the named source.",
          repository_source: invalid,
          work_class: "standard"
        )

      assert Decision.parse(document) == {:error, {:invalid_decision, :repository_source}}
    end
  end

  test "a retry that changes only the selector is a different durable decision" do
    document = fn source ->
      decision_document(
        action: "start_episode",
        reason: "Review the named branch.",
        repository_source: source,
        work_class: "standard"
      )
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

  # Andrew, 2026-09-27: routing also reports how the sender feels about
  # Ryker's previous answer. The contract offers it beside the decision only
  # when asked, never requires it, and refuses no value of it: Coop checks the
  # whole result against this format, and a stricter sentiment would make a
  # mistyped feeling a reason to correct the routing decision.
  test "the contract offers a sentiment only when asked, and no value of it is refused" do
    assert Decision.json_schema([:reply, :ignore], :any, false, []) ==
             Decision.json_schema([:reply, :ignore], :any, false, [], false)

    refute Map.has_key?(Decision.json_schema()["properties"], "sentiment")

    schema = Decision.json_schema([:reply, :ignore], :any, false, [], true)
    assert schema["required"] == Decision.json_schema()["required"]

    assert %{"anyOf" => [asked, %{"type" => "null"}, _anything]} =
             schema["properties"]["sentiment"]

    assert asked["properties"]["feeling"]["enum"] == ~w(satisfied neutral frustrated angry)
    assert asked["required"] == ["feeling", "reason"]

    built = JSV.build!(schema)
    document = decision_document([])

    for sentiment <- [
          %{"feeling" => "angry", "reason" => "They are upset the deploy broke again."},
          nil,
          "angry",
          %{"feeling" => "furious"},
          %{"feeling" => "neutral", "reason" => String.duplicate("a", 400)}
        ] do
      result = Map.put(document, "sentiment", sentiment)
      assert {:ok, _valid} = JSV.validate(result, built, cast: false)
      assert {:ok, decision} = Decision.parse(result)

      assert Decision.fingerprint(decision) ==
               Decision.fingerprint(elem(Decision.parse(document), 1))
    end

    assert {:ok, %Decision{sentiment: %{feeling: :angry, reason: "Upset."}} = decision} =
             Decision.parse(
               Map.put(document, "sentiment", %{"feeling" => "angry", "reason" => "Upset."})
             )

    # Checked again the way the host holds it, the sentiment stays beside the
    # decision and out of its stored document.
    assert {:ok, %Decision{sentiment: %{feeling: :angry}}} = Decision.prepare(decision)
    refute Map.has_key?(Decision.document(decision), "sentiment")
    assert {:ok, %Decision{sentiment: nil}} = Decision.prepare(%{decision | sentiment: :furious})
  end

  defp decision_document(overrides) do
    defaults = %{
      "action" => "reply",
      "episode_ref" => nil,
      "messages" => nil,
      "reactions" => nil,
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

  defp quick_reply(messages),
    do: decision_document(action: "quick_reply", work_class: nil, messages: messages)

  defp shapes(schema, action),
    do: Enum.filter(schema["oneOf"], &(&1["properties"]["action"]["const"] == action))

  # Replaying a recorded routing decision under a changed contract needs the
  # contract its source was offered, rebuilt with today's shapes: the actions,
  # the emoji it takes, whether a repository source may be named and which
  # repositories a new request chooses from (`mix ryker.eval routing-replay`).
  test "a recorded decision contract is rebuilt exactly from what it offered" do
    for actions <- [
          [:start_episode, :continue_episode, :reply, :quick_reply, :react, :ignore],
          [:start_episode, :quick_reply, :ignore],
          [:continue_episode, :reply]
        ],
        reactions <- [:any, nil, ["eyes", "white_check_mark"]],
        source? <- [false, true],
        choices <- [[], ["ryker", "coop"]] do
      recorded = Decision.json_schema(actions, reactions, source?, choices)

      assert Decision.replay_schema(recorded, false) == {:ok, recorded},
             inspect({actions, reactions, source?, choices})

      # A recorded contract from before sentiment gains it where routing
      # offers it today.
      assert Decision.replay_schema(recorded, true) ==
               {:ok, Decision.json_schema(actions, reactions, source?, choices, true)}
    end

    assert Decision.replay_schema(%{"properties" => %{}}, false) ==
             {:error, {:invalid_decision, :schema}}

    assert Decision.replay_schema(
             %{
               "properties" => %{"action" => %{"enum" => ["launch_rockets"]}},
               "oneOf" => []
             },
             false
           ) == {:error, {:invalid_decision, :schema}}
  end
end
