defmodule Ryker.ControlPlane.LabPageTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.{Assets, LabPage}

  @now ~U[2026-09-13 14:32:00Z]

  # In the order the page groups them since 2026-09-19: Investigate, Build, Remember.
  @examples [
    "Investigate why this service keeps restarting.",
    "Summarize the attached log and identify likely causes.",
    "Ask me three questions to clarify this investigation.",
    "Review this change for bugs and missing tests.",
    "Help me turn this issue into an engineering task.",
    "Compare these two approaches and explain the trade-offs.",
    "Generate a small illustration of a rocket launch.",
    "Remind me tomorrow at 9:00 to check the deployment.",
    "Remember that I prefer concise incident updates.",
    "Show the automations active in this conversation."
  ]

  test "the examples are exactly the ten authored ones" do
    # Andrew approved these ten strings on 2026-09-09. They are UI copy, not
    # model fixtures: a generated or paraphrased eleventh example, or a missing
    # one, changes what an operator is invited to type.
    assert LabPage.examples() == @examples
  end

  test "the directory heads each day the way every list does, in one labelled timezone" do
    # Sept 13: the old list showed "3 inputs · 13 Sep, 12:58 UTC" on every row
    # and no grouping, so today's conversation and one from last week read the
    # same. Sept 25: "Earlier" then lumped last week with last year. Each day
    # now opens with the heading every Kit list uses (Today, Yesterday, a
    # weekday within the week, then the date), from the observed UTC clock,
    # and a row keeps its position inside its day.
    assert [
             {"Today", [%{id: "a"}, %{id: "b"}]},
             {"Yesterday", [%{id: "c"}]},
             {"Thursday", [%{id: "d"}]},
             {"6 September", [%{id: "e"}]}
           ] = LabPage.directory_days(directory(), @now)

    assert LabPage.directory_time(~U[2026-09-13 04:12:00Z], @now) == "04:12 UTC"
    assert LabPage.directory_time(~U[2026-09-12 23:59:00Z], @now) == "12 Sep, 23:59 UTC"
    assert LabPage.directory_time(~U[2026-09-06 23:04:00Z], @now) == "6 Sep, 23:04 UTC"
    assert LabPage.directory_days([], @now) == []
  end

  # Andrew, 2026-09-25, on Chat's conversation list: no vertical rhythm. An
  # uppercase TODAY and EARLIER, rows of uneven height, a date where a time
  # belonged, and a status dot of its own. Each row is now one line of title
  # with its clock time at the edge and its state under it as the Kit's dot
  # and word, and only the open conversation is marked. QA, 2026-09-25: the
  # time said UTC in Chat's messages but not in this list.
  test "each conversation is one steady row under its day: title, time, state" do
    document =
      render_component(&LabPage.render/1, lab_assigns(directory(), "c"))
      |> LazyHTML.from_fragment()

    days = LazyHTML.query(document, ".lab-directory-list > section.lab-directory-day")

    assert Enum.map(days, &(LazyHTML.query(&1, "h2") |> LazyHTML.text())) ==
             ["Today", "Yesterday", "Thursday", "6 September"]

    rows = LazyHTML.query(document, ".lab-directory-day > a.lab-directory-item")

    assert Enum.map(rows, fn row ->
             [time] = LazyHTML.query(row, "time.lab-directory-time") |> Enum.to_list()
             [state] = LazyHTML.query(row, ".lab-directory-meta .state-word") |> Enum.to_list()

             {LazyHTML.query(row, ".lab-directory-title") |> LazyHTML.text(), LazyHTML.text(time),
              LazyHTML.attribute(time, "title"), LazyHTML.attribute(state, "data-tone"),
              LazyHTML.text(state)}
           end) == [
             {"Read the automations", "04:12 UTC", ["04:12 UTC"], ["busy"], "Working"},
             {"Read the automations", "03:54 UTC", ["03:54 UTC"], ["off"], "Replied"},
             {"Yesterday's thread", "23:59 UTC", ["12 Sep, 23:59 UTC"], ["warn"],
              "Needs attention"},
             {"Deploy review", "18:20 UTC", ["10 Sep, 18:20 UTC"], ["warn"], "Waiting for you"},
             {"Check why Livebook has zero instances", "23:04 UTC", ["6 Sep, 23:04 UTC"],
              ["busy"], "Waiting"}
           ]

    assert LazyHTML.query(document, "a.lab-directory-item[aria-current=page]")
           |> LazyHTML.attribute("href") == ["/conversations/c"]

    # Search and New keep their places above the list.
    assert LazyHTML.query(document, ".lab-directory > .lab-directory-heading a.lab-new")
           |> Enum.count() == 1

    assert LazyHTML.query(
             document,
             ".lab-directory > form#lab-directory-search + .lab-directory-list"
           )
           |> Enum.count() == 1

    # Steady 12px rows with hairlines between them; day headings in the Kit's
    # sentence-case type, never uppercase.
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body
    [_, row] = Regex.run(~r/\n\.lab-directory-item \{([^}]+)\}/, css)
    assert row =~ "padding:12px 16px"

    [_, hairline] =
      Regex.run(~r/\n\.lab-directory-item \+ \.lab-directory-item \{([^}]+)\}/, css)

    assert hairline =~ "border-top:1px solid"
    [_, heading] = Regex.run(~r/\n\.lab-directory-day > h2 \{([^}]+)\}/, css)
    assert heading =~ "font-size:12px"
    refute heading =~ "uppercase"
  end

  # QA re-test, 2026-09-26: a reply with one shell block made the whole Chat
  # page 554 px wide on a 390 px phone, sliding the header and the composer
  # sideways. A code block keeps its lines and scrolls inside itself.
  test "a code block scrolls inside the message instead of widening the page" do
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body

    [_, block] = Regex.run(~r/\n\.md-code \{([^}]+)\}/, css)
    assert block =~ "max-width:100%"
    assert block =~ "overflow-x:auto"
    assert block =~ "box-sizing:border-box"
  end

  test "the browser's own controls never show beside Ryker's, and phone examples look tappable" do
    # QA 2026-09-25: "No file chosen" sat beside Attach files, a phone's More
    # showed the browser's triangle before its own chevron ("▶ More ›"), and
    # on a phone the example prompts were plain lines with nothing to say
    # they could be tapped.
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body

    [_, file] = Regex.run(~r/\n\.lab-native-composer input\[type=file\] \{([^}]+)\}/, css)
    assert file =~ "position:absolute"
    assert file =~ "clip:rect(0 0 0 0)"

    [_, summary] = Regex.run(~r/\n\.mobile-manage summary \{([^}]+)\}/, css)
    assert summary =~ "list-style:none"
    assert css =~ ".mobile-manage summary::-webkit-details-marker { display:none; }"
    assert css =~ ~s(.mobile-manage summary::marker { content:""; })

    [_, phone] = Regex.run(~r/@media \(hover:none\), \(max-width:800px\) \{(.*?)\n\}/s, css)
    [_, example] = Regex.run(~r/\.ryker-app \.lab-example \{([^}]+)\}/, phone)
    assert example =~ "border:1px solid"
  end

  defp directory do
    [
      %{
        id: "a",
        title: "Read the automations",
        updated_at: ~U[2026-09-13 04:12:00Z],
        status: :working
      },
      %{id: "b", title: "Read the automations", updated_at: ~U[2026-09-13 03:54:00Z]},
      %{
        id: "c",
        title: "Yesterday's thread",
        updated_at: ~U[2026-09-12 23:59:00Z],
        status: :attention
      },
      %{
        id: "d",
        title: "Deploy review",
        updated_at: ~U[2026-09-10 18:20:00Z],
        status: :waiting_for_you
      },
      %{
        id: "e",
        title: "Check why Livebook has zero instances",
        updated_at: ~U[2026-09-06 23:04:00Z],
        status: :waiting
      }
    ]
  end

  # Andrew, 2026-09-25: "Chat picks its environment." Every conversation ran
  # in the default environment and nothing on the page said so, so a question
  # about staging was answered from production's repositories and Emisar
  # account. The choice then sat in a head of its own above the messages, and
  # on 2026-09-27 Andrew asked for it to move: "this can be cleanly and nicely
  # moved to text input form or under it, so we don't waste space on top bar
  # with huge dropdown". It is a compact choice under the message box now, and
  # nothing sits above the messages.
  test "a conversation chooses its environment under the message box, with no head above" do
    environments = [
      %{
        ref: "production",
        name: "Production",
        default: true,
        repositories: ["acme/api", "acme/web"],
        emisar: true
      },
      %{
        ref: "staging",
        name: "Staging",
        default: false,
        repositories: ["acme/api"],
        emisar: false
      }
    ]

    head = fn assigns ->
      document =
        render_component(&LabPage.render/1, lab_assigns(directory(), "c") ++ assigns)
        |> LazyHTML.from_fragment()

      assert Enum.empty?(LazyHTML.query(document, ".lab-column header, .lab-column h2"))

      [foot] =
        LazyHTML.query(document, ".lab-composer-dock > .lab-composer-foot") |> Enum.to_list()

      foot
    end

    staging = head.(environments: environments, environment: "staging")
    refute LazyHTML.text(staging) =~ "Yesterday's thread"

    [form] = LazyHTML.query(staging, "form.lab-environment") |> Enum.to_list()
    assert LazyHTML.attribute(form, "phx-change") == ["select-conversation-environment"]
    assert LazyHTML.query(form, "label[for=lab-environment]") |> LazyHTML.text() == "Environment"

    assert Enum.map(
             LazyHTML.query(form, "select#lab-environment[name=environment] > option"),
             fn option ->
               {squish(LazyHTML.text(option)), LazyHTML.attribute(option, "value"),
                LazyHTML.attribute(option, "selected")}
             end
           ) == [
             {"Production", ["production"], []},
             {"Staging", ["staging"], [""]},
             {"No environment", [""], []}
           ]

    none = head.(environments: environments, environment: nil)

    assert LazyHTML.query(none, "option[selected]") |> LazyHTML.text() |> squish() ==
             "No environment"

    # With no environment to choose, it says so and where to add one, so the
    # choice can be found at all ("how can I select which environment to
    # use?", 2026-09-26).
    bare = head.(environments: [], environment: nil)
    assert Enum.empty?(LazyHTML.query(bare, "form.lab-environment, select"))
    assert squish(LazyHTML.text(bare)) =~ "Environment None yet"

    assert LazyHTML.query(bare, "a[href='/environments/new']") |> LazyHTML.text() ==
             "Add one"
  end

  # Andrew, 2026-09-26: while a new conversation is being written, the list
  # beside it shows it too, as the conversation being written, at the top and
  # marked as the one on screen ("you forgot to add a new dummy entry").
  test "a conversation being written shows at the top of the list as the one on screen" do
    draft = [
      snapshot: %{conversation_id: "draft", messages: [], admission_progress: [], draft: true}
    ]

    page =
      render_component(
        &LabPage.render/1,
        lab_assigns(directory(), "draft") ++
          draft ++ [environments: environments(), environment: "production"]
      )
      |> LazyHTML.from_fragment()

    [first | _rest] =
      LazyHTML.query(page, ".lab-directory-list .lab-directory-item") |> Enum.to_list()

    assert squish(LazyHTML.text(first)) =~ "New conversation"
    assert squish(LazyHTML.text(first)) =~ "Not sent yet"
    assert LazyHTML.attribute(first, "aria-current") == ["page"]

    # Every real conversation is still listed, and none is marked as open.
    links = LazyHTML.query(page, ".lab-directory-list a.lab-directory-item")
    assert Enum.count(links) == length(directory())
    assert Enum.empty?(LazyHTML.query(page, ".lab-directory-list a[aria-current=page]"))

    assert LazyHTML.query(page, ".lab-composer-foot select#lab-environment option[selected]")
           |> LazyHTML.text()
           |> squish() == "Production"

    # A saved conversation has no such row.
    saved =
      render_component(&LabPage.render/1, lab_assigns(directory(), "c"))
      |> LazyHTML.from_fragment()

    refute LazyHTML.text(saved) =~ "New conversation"
  end

  # Andrew, 2026-09-26: "Each conversation shows its environment." Chat picked
  # a conversation's environment in its head, but the list named none, so
  # finding the staging conversation meant opening each one.
  test "each conversation row names the environment it works in on its state line" do
    items =
      Enum.zip_with(directory(), ["production", "staging", nil, "gone", "production"], fn item,
                                                                                          ref ->
        Map.put(item, :environment_ref, ref)
      end)

    document =
      render_component(
        &LabPage.render/1,
        lab_assigns(items, "c") ++ [environments: environments()]
      )
      |> LazyHTML.from_fragment()

    rows = LazyHTML.query(document, ".lab-directory-day > a.lab-directory-item")

    assert Enum.map(rows, fn row ->
             row
             |> LazyHTML.query(".lab-directory-meta > .lab-directory-environment")
             |> LazyHTML.text()
             |> squish()
           end) == [
             "· Production",
             "· Staging",
             "· No environment",
             "· No environment",
             "· Production"
           ]

    # The state keeps its dot and word first on the line.
    assert LazyHTML.query(document, ".lab-directory-meta > .state-word:first-child")
           |> Enum.count() == 5

    # With no environments at all there is nothing to tell conversations
    # apart by, so no row repeats "No environment".
    bare =
      render_component(&LabPage.render/1, lab_assigns(items, "c"))
      |> LazyHTML.from_fragment()

    assert Enum.empty?(LazyHTML.query(bare, ".lab-directory-environment"))
  end

  defp environments do
    [
      %{ref: "production", name: "Production", default: true, repositories: [], emisar: true},
      %{ref: "staging", name: "Staging", default: false, repositories: [], emisar: false}
    ]
  end

  # The choices the head offers come from the settings the way every list
  # names them: the default first, repositories as people know them, and
  # whether the environment has an Emisar account.
  test "the environment choices name the default first and each environment by what it holds" do
    snapshot = %{
      emisar_connections: [%{ref: "emisar-main", display_name: "Acme Emisar"}],
      environments: [
        %Ryker.Settings.Environment{
          ref: "staging",
          display_name: "Staging",
          is_default: false,
          emisar_connection_ref: nil,
          repositories: [
            %Ryker.Settings.EnvironmentRepository{
              environment_ref: "staging",
              repository_ref: "api",
              position: 0
            }
          ]
        },
        %Ryker.Settings.Environment{
          ref: "production",
          display_name: "Production",
          is_default: true,
          emisar_connection_ref: "emisar-main",
          repositories: [
            %Ryker.Settings.EnvironmentRepository{
              environment_ref: "production",
              repository_ref: "api",
              position: 0
            },
            %Ryker.Settings.EnvironmentRepository{
              environment_ref: "production",
              repository_ref: "web",
              position: 1
            }
          ]
        }
      ],
      repositories: [
        %{ref: "api", display_name: "API", github_repository: "acme/api"},
        %{ref: "web", display_name: "Web", github_repository: nil}
      ]
    }

    assert LabPage.environment_choices(snapshot) == [
             %{
               ref: "production",
               name: "Production",
               default: true,
               repositories: ["acme/api", "Web"],
               emisar: true
             },
             %{
               ref: "staging",
               name: "Staging",
               default: false,
               repositories: ["acme/api"],
               emisar: false
             }
           ]
  end

  defp squish(text), do: text |> String.split() |> Enum.join(" ")

  # What the LiveView hands the page for an open conversation.
  defp lab_assigns(items, selected) do
    [
      snapshot: %{conversation_id: selected, messages: [], admission_progress: []},
      token: "token",
      items: items,
      filter: "",
      messages: [],
      history: %{before: nil, exhausted: true},
      announcement: "",
      now: @now,
      environments: [],
      environment: nil
    ]
  end

  test "a message's timeline link resolves only its own retained execution" do
    # The runtime rail linked "All requests in this conversation" and the
    # latest episode; a message from an earlier episode had no way to its own
    # execution. Each link now comes from the message's exact input id or
    # producing turn, never from list position, title text or the newest episode.
    message = "0193a5d2-7c1e-7b8a-9f00-0000000000a1"
    pending = %{actor: :operator, input_id: message, episode_id: nil, status: :pending}
    assert LabPage.timeline_href(pending) == "/timeline/#{message}"

    assert LabPage.timeline_href(%{pending | status: :blocked}) ==
             "/timeline/#{message}"

    admitted = %{
      actor: :operator,
      input_id: message,
      episode_id: "0193a5d2-7c1e-7b8a-9f00-00000000e01e",
      status: :decided,
      decision_action: :start_episode
    }

    # Once routed, the same route is this input's own admission request on its
    # episode; an ignored input's is its recorded decision.
    assert LabPage.timeline_href(admitted) == "/timeline/#{message}"

    assert LabPage.timeline_href(%{admitted | episode_id: nil, decision_action: :ignore}) ==
             "/timeline/#{message}"

    integration = %{actor: :integration, input_id: "0193a5d2-7c1e-7b8a-9f00-0000000000a2"}
    assert LabPage.timeline_href(integration) == "/timeline/0193a5d2-7c1e-7b8a-9f00-0000000000a2"

    # A reply opens its request at the attempt that wrote it.
    request = "0193a5d2-7c1e-7b8a-9f00-00000000e02e"
    reply = %{actor: :ryker, episode_id: request, turn_id: "turn-uuid", status: :settled}

    assert LabPage.timeline_href(reply) ==
             "/timeline/#{request}?attempt=turn-uuid#request-turn-uuid"

    action = %{actor: :ryker, episode_id: request, status: :delivered}
    assert LabPage.timeline_href(action) == "/timeline/#{request}"

    # No provenance, no guessed URL.
    assert LabPage.timeline_href(%{actor: :ryker, status: :delivered, text: "hi"}) == nil
    assert LabPage.timeline_href(%{actor: :operator, status: :decided, text: "hi"}) == nil
  end
end
