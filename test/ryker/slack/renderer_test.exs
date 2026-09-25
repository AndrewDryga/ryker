defmodule Ryker.Slack.RendererTest do
  use ExUnit.Case, async: true

  alias Ryker.ControlPlane.WorkRecovery
  alias Ryker.Slack.{Interaction, Renderer}
  alias Ryker.Work.{TaskStages, Turn}

  @now ~U[2026-08-28 12:00:00.000000Z]

  # Every confirmed entity used to collapse to "*Automation confirmed*" plus its
  # title: the trigger, filter, delivery, expiry and the only way to remove it
  # were gone the moment an operator said yes.
  test "a confirmed offer keeps the saved entity's full detail and its exact removal control" do
    captured = Jason.decode!(File.read!("testdata/work/terraform-automation-recovery.json"))
    proposal = hd(captured["automation_arguments"]["proposals"])
    ref = hd(captured["accepted_candidate"]["outcome"]["record_refs"])

    payload = %{
      "context_channel" => "slack:T0BHXKZJVDX:C0BHTRPHXP0",
      "delivery_channel" => "slack:T0BHXKZJVDX:C0BHTRPHXP0",
      "expires_at" => nil,
      "filter" => proposal["trigger"]["filter"],
      "hold" => nil,
      "repository" => nil,
      "source_kind" => proposal["trigger"]["source_kind"],
      "task" => proposal["prompt"],
      "title" => proposal["title"]
    }

    entity = %{
      "facts" => [
        ["Channel", %{"channel_ref" => "C0BHTRPHXP0"}],
        ["Source", proposal["trigger"]["source_kind"]],
        ["Event filter", "All #{proposal["trigger"]["source_kind"]} events posted here"],
        ["Repository", "No fixed binding"],
        ["Expires", "Until disabled"],
        ["Missed events", "Run the latest missed occurrence"],
        ["Access", "Read-only"]
      ],
      "instructions" => proposal["prompt"],
      "kind" => "standing_rule",
      "notice" => "Standing rule saved",
      "ref" => "behavior:2f6a1c0e-9c1d-4c2e-8d3f-4a5b6c7d8e9f",
      "removable" => true,
      "resumable" => false,
      "revision" => 1,
      "saved_at" => "2026-08-28T12:00:00.000000Z",
      "saved_by" => "slack:user:U123",
      "status" => "active",
      "title" => proposal["title"]
    }

    record = %{
      "kind" => "standing_assignment_offer",
      "payload" => payload,
      "presentation" => %{"entity" => entity},
      "ref" => ref,
      "status" => "confirmed"
    }

    assert {:ok, rendered} =
             Renderer.render(%{"message" => "Confirmation saved.", "records" => [record]})

    [_message, detail, facts, context, controls] = rendered["blocks"]
    assert detail["text"]["text"] =~ "*#{proposal["title"]}*"
    assert detail["text"]["text"] =~ proposal["prompt"]

    assert Enum.map(facts["fields"], & &1["text"]) == [
             "*Channel*\n<#C0BHTRPHXP0>",
             "*Source*\n#{proposal["trigger"]["source_kind"]}",
             "*Event filter*\nAll #{proposal["trigger"]["source_kind"]} events posted here",
             "*Repository*\nNo fixed binding",
             "*Expires*\nUntil disabled",
             "*Missed events*\nRun the latest missed occurrence",
             "*Access*\nRead-only"
           ]

    assert hd(context["elements"])["text"] =~ "Standing rule saved · saved by <@U123>"

    assert [delete] = controls["elements"]
    assert delete["action_id"] == "ryker_delete_behavior"
    assert delete["value"] == "behavior-control:behavior:2f6a1c0e-9c1d-4c2e-8d3f-4a5b6c7d8e9f:1"
    assert delete["style"] == "danger"
    assert delete["confirm"]["title"]["text"] == "Delete rule?"
    assert delete["confirm"]["text"]["text"] =~ proposal["title"]
    refute inspect(rendered) =~ "Enable automation"
    refute inspect(rendered) =~ "Automation confirmed"

    deleted =
      put_in(record, ["presentation", "entity"], %{
        entity
        | "removable" => false,
          "resumable" => false,
          "status" => "deleted",
          "notice" => "Standing rule deleted"
      })

    assert {:ok, rendered} =
             Renderer.render(%{"message" => "Confirmation saved.", "records" => [deleted]})

    refute Enum.any?(rendered["blocks"], &(&1["type"] == "actions"))
    assert inspect(rendered) =~ "Standing rule deleted"

    # The offer payload alone no longer describes what was saved; a confirmed
    # offer without its entity is an error, not a shorter card.
    assert Renderer.render(%{
             "message" => "Confirmation saved.",
             "records" => [Map.delete(record, "presentation")]
           }) ==
             {:error, {:invalid_slack_render, :record}}

    memory = %{
      "facts" => [
        ["Kind", "entity relationship"],
        ["Scope", "Whole workspace"],
        ["Visibility", "Whole workspace"],
        ["Expires", "No expiry"]
      ],
      "instructions" => "portal-prod",
      "kind" => "memory",
      "notice" => "Memory saved",
      "ref" => "memory:rollback-proof",
      "removable" => true,
      "resumable" => false,
      "revision" => nil,
      "saved_at" => "2026-08-28T12:00:00.000000Z",
      "saved_by" => "slack:user:U123",
      "status" => "active",
      "title" => "GCP project"
    }

    assert {:ok, rendered} = Renderer.render(%{"saved_entity" => memory})
    assert [forget] = List.last(rendered["blocks"])["elements"]
    assert forget["action_id"] == "ryker_forget_memory"
    assert forget["value"] == "memory:rollback-proof"
    assert forget["confirm"]["title"]["text"] == "Forget this memory?"
    assert forget["confirm"]["text"]["text"] =~ "GCP project"
    assert rendered["text"] =~ "Memory saved: GCP project"

    forged = put_in(memory, ["facts"], [["Kind", "<!everyone> pings"]])
    assert {:ok, rendered} = Renderer.render(%{"saved_entity" => forged})
    refute inspect(rendered) =~ "<!everyone>"
    assert inspect(rendered) =~ "&lt;!everyone&gt;"

    assert Renderer.render(%{"saved_entity" => %{memory | "ref" => "schedule:abc"}}) ==
             {:error, {:invalid_slack_render, :saved_entity}}
  end

  # Three cards parsed a time without looking at its type, so a document
  # missing one raised inside the renderer, taking the reply or the list with
  # it, where every other malformed field is refused.
  test "a card missing a time is refused, not a crash" do
    for at <- [nil, 1_787_832_000, "yesterday"] do
      assert Renderer.render(%{"saved_entity" => %{paused_rule() | "saved_at" => at}}) ==
               {:error, {:invalid_slack_render, :saved_entity}}

      setup = put_in(setup_document(Ecto.UUID.generate()), ["channel_setup", "expires_at"], at)

      assert Renderer.render(setup) == {:error, {:invalid_slack_render, :channel_setup}}

      welcome =
        welcome_document(Ecto.UUID.generate(), settings_document(), %{
          "actor_ref" => "U123",
          "at" => at
        })

      assert Renderer.render(welcome) == {:error, {:invalid_slack_render, :channel_welcome}}
    end
  end

  # The choice step once checked that its choices were a list and never what
  # was in it, so one malformed choice raised inside the renderer instead of
  # refusing the setup card.
  test "a setup step with a malformed environment choice is refused, not a crash" do
    document =
      setup_document(Ecto.UUID.generate())
      |> put_in(["channel_setup", "step"], "environment")

    valid = %{"emisar" => false, "name" => "Staging", "ref" => "staging", "repositories" => []}

    for choices <- [
          [nil],
          ["staging"],
          [Map.delete(valid, "emisar")],
          [%{valid | "name" => " "}],
          [%{valid | "emisar" => "yes"}],
          [%{valid | "repositories" => [42]}],
          [Map.put(valid, "url", "https://example.invalid")]
        ] do
      malformed = put_in(document, ["channel_setup", "draft", "environment_options"], choices)

      assert Renderer.render(malformed) == {:error, {:invalid_slack_render, :channel_setup}},
             inspect(choices)
    end

    assert {:ok, _rendered} = Renderer.render(document)

    # With no environments yet, the step still asks, and offers No environment.
    empty = put_in(document, ["channel_setup", "draft", "environment_options"], [])
    assert {:ok, %{"blocks" => [explanation, controls]}} = Renderer.render(empty)
    assert explanation["text"]["text"] =~ "*No environment* — I'll still answer here"

    assert Enum.map(controls["elements"], &{&1["action_id"], &1["text"]["text"]}) == [
             {"ryker_setup_environment_none", "No environment"}
           ]
  end

  test "renders host-authorized typed mentions into native Slack controls" do
    authority = %{
      "broadcasts" => [],
      "channels" => ["slack:T123:C456"],
      "user_groups" => [],
      "users" => ["slack-user:U123"],
      "workspace_ref" => "T123"
    }

    assert {:ok, rendered} =
             Renderer.render(%{
               "message" => "Thanks [@Bruno](slack-user:U123). Raw <!everyone> stays inert.",
               "records" => [],
               "slack_mentions" => authority
             })

    assert rendered["text"] == "Thanks <@U123>. Raw &lt;!everyone&gt; stays inert."
    assert hd(rendered["blocks"])["text"] == rendered["text"]
  end

  # Until 2026-09-11 the welcome was static system copy ("Configure Emisar for
  # this channel. Nothing is saved until an operator confirms it.") with a
  # 30-minute expiry; a channel that never clicked had no readable description
  # of what Ryker actually did there.
  test "the welcome is generated from effective saved settings, with controls for the saved state" do
    configuration_ref = Ecto.UUID.generate()

    assert {:ok, rendered} =
             Renderer.render(welcome_document(configuration_ref, settings_document()))

    text = Jason.encode!(rendered)

    assert text =~
             "I work in the *Production* environment here: I can make changes in <https://github.com/acme/backend|backend> and read `infrastructure`."

    assert text =~ "I'll reply when you mention <@UBOT>"
    assert text =~ "When an alert is posted here, I'll investigate proactively in its thread"
    refute text =~ "handled separately"
    refute text =~ "Nothing is saved"
    refute text =~ "expires"
    assert rendered["text"] =~ "AI teammate"

    assert [controls] = Enum.filter(rendered["blocks"], &(&1["type"] == "actions"))

    assert Enum.map(controls["elements"], &{&1["action_id"], &1["text"]["text"], &1["value"]}) ==
             [
               {"ryker_welcome_be_proactive", "Be proactive", "#{configuration_ref}|3"},
               {"ryker_welcome_configure", "Customize", "#{configuration_ref}|3"}
             ]

    proactive =
      settings_document()
      |> put_in(["participation"], %{"source" => "channel", "value" => "proactive"})
      |> put_in(["alert_policy"], "offer")
      |> put_in(["invitations", "user_refs"], ["U456"])

    assert {:ok, rendered} =
             Renderer.render(welcome_document(configuration_ref, proactive, "Settings updated."))

    text = Jason.encode!(rendered)
    assert text =~ "join conversations when I can help"
    assert text =~ "I'll offer to investigate in its thread or create a dedicated incident room"
    assert text =~ "I'll invite <@U456>"
    assert text =~ "*Settings updated.*"

    assert [controls] = Enum.filter(rendered["blocks"], &(&1["type"] == "actions"))

    assert Enum.map(controls["elements"], & &1["text"]["text"]) == ["Mentions only", "Customize"]

    observing =
      settings_document()
      |> put_in(["participation"], %{"source" => "channel", "value" => "shadow"})
      |> put_in(["observation"], %{"on" => true, "source" => "channel"})
      |> put_in(["environment"], nil)
      |> put_in(["environment_count"], 0)

    assert {:ok, rendered} = Renderer.render(welcome_document(configuration_ref, observing))
    text = Jason.encode!(rendered)
    assert text =~ "I don't have access to any repos, so please connect one (or more)"
    assert text =~ "watching quietly for now"
    assert text =~ "I'll wait to be asked before looking into one"
    assert text =~ "/ryker shadow inherit"

    assert [controls] = Enum.filter(rendered["blocks"], &(&1["type"] == "actions"))
    assert Enum.map(controls["elements"], & &1["text"]["text"]) == ["Configure channel"]

    assert Renderer.render(
             welcome_document(
               configuration_ref,
               put_in(settings_document(), ["alert_policy"], "loud")
             )
           ) ==
             {:error, {:invalid_slack_render, :channel_welcome}}
  end

  # The welcome says which environment the channel works in and what that
  # lets work there use, in plain words. No environment is a state of its own,
  # never the same as having none to choose from, and never the default.
  test "the welcome says what the channel's environment lets work there use" do
    configuration_ref = Ecto.UUID.generate()

    welcome = fn environment, count ->
      settings =
        settings_document()
        |> put_in(["environment"], environment)
        |> put_in(["environment_count"], count)

      assert {:ok, rendered} = Renderer.render(welcome_document(configuration_ref, settings))
      Jason.encode!(rendered)
    end

    production = settings_document()["environment"]

    assert welcome.(%{production | "emisar" => true}, 2) =~
             "I can make changes in <https://github.com/acme/backend|backend>, read `infrastructure`, and use Emisar."

    single = %{production | "repositories" => [hd(production["repositories"])]}

    assert welcome.(single, 2) =~
             "I work in the *Production* environment here: I can make changes in <https://github.com/acme/backend|backend>."

    ops = %{production | "emisar" => true, "name" => "Ops", "repositories" => []}

    assert welcome.(ops, 2) =~
             "I work in the *Ops* environment here. It has no repos, so I won't work on coding tasks in this channel, but I can use Emisar."

    assert welcome.(nil, 2) =~
             "This channel doesn't use an environment, so I'll answer here without any repos or Emisar. Choose one with *Customize* if you want me to work on code here."

    unavailable = %{
      "emisar" => false,
      "name" => "production",
      "ready" => false,
      "ref" => "production",
      "repositories" => []
    }

    assert welcome.(unavailable, 1) =~
             "This channel uses the `production` environment, but it can't run work right now, so I'll answer without any repos or Emisar until it can."

    # Environment names are an operator's text and never become markup.
    forged = welcome.(%{production | "name" => "<!channel> *prod*"}, 2)
    refute forged =~ "<!channel>"
    assert forged =~ "&lt;!channel&gt;"
  end

  test "settings on request share the welcome's projection in both audiences" do
    configuration_ref = Ecto.UUID.generate()

    for audience <- ["thread", "private"] do
      assert {:ok, rendered} =
               Renderer.render(%{
                 "channel_settings" => %{
                   "audience" => audience,
                   "bot_user_ref" => "UBOT",
                   "configuration_ref" => configuration_ref,
                   "revision" => 3,
                   "settings" => settings_document()
                 }
               })

      assert [heading, facts, context, controls] = rendered["blocks"]
      assert heading["text"]["text"] == "*Channel settings*"

      assert Enum.map(facts["fields"], & &1["text"]) == [
               "*Conversations*\nReply when mentioned",
               "*Alerts*\nInvestigate in the existing thread",
               "*Environment*\nProduction",
               "*Repositories*\n<https://github.com/acme/backend|backend> — changes\n`infrastructure` — read only",
               "*Incident invitations*\nNo one automatically — you can add people yourself",
               "*Observation mode*\nOff"
             ]

      assert hd(context["elements"])["text"] =~ "defaults; nobody has customized this channel yet"

      # List controls post item cards into the thread the view was asked in;
      # the private command reply has no thread, so it carries only Configure.
      expected_controls =
        if audience == "thread",
          do: [
            {"ryker_welcome_configure", "#{configuration_ref}|3"},
            {"ryker_welcome_view_schedules", "#{configuration_ref}|3"},
            {"ryker_welcome_view_rules", "#{configuration_ref}|3"}
          ],
          else: [{"ryker_welcome_configure", "#{configuration_ref}|3"}]

      assert Enum.map(controls["elements"], &{&1["action_id"], &1["value"]}) == expected_controls
      assert rendered["text"] =~ "Conversations: Reply when mentioned"
    end

    unconfigured =
      settings_document()
      |> put_in(["configuration_ref"], nil)
      |> put_in(["revision"], nil)
      |> put_in(["participation"], %{"source" => "installation", "value" => "mentions"})

    assert {:ok, rendered} =
             Renderer.render(%{
               "channel_settings" => %{
                 "audience" => "private",
                 "bot_user_ref" => "UBOT",
                 "configuration_ref" => nil,
                 "revision" => nil,
                 "settings" => unconfigured
               }
             })

    refute Enum.any?(rendered["blocks"], &(&1["type"] == "actions"))
  end

  # slack-presentation.md: all owned structural headings are colonless, tested as
  # one shared invariant rather than a per-card string replacement.
  test "owned structural headings never end in a colon across card families" do
    configuration_ref = Ecto.UUID.generate()

    documents = [
      welcome_document(configuration_ref, settings_document()),
      %{
        "channel_settings" => %{
          "audience" => "thread",
          "bot_user_ref" => "UBOT",
          "configuration_ref" => configuration_ref,
          "revision" => 3,
          "settings" => settings_document()
        }
      },
      setup_document(Ecto.UUID.generate())
    ]

    for document <- documents do
      assert {:ok, rendered} = Renderer.render(document)

      headings =
        rendered["blocks"]
        |> Enum.flat_map(fn block ->
          [get_in(block, ["text", "text"]) | Enum.map(block["fields"] || [], & &1["text"])]
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.flat_map(&Regex.scan(~r/\*([^*\n]+)\*/, &1, capture: :all_but_first))
        |> List.flatten()

      assert headings != []
      refute Enum.any?(headings, &String.ends_with?(&1, ":")), inspect(headings)
    end
  end

  test "the setup wizard explains every option before asking for a choice" do
    session_ref = Ecto.UUID.generate()

    assert {:ok, rendered} = Renderer.render(setup_document(session_ref))
    assert [explanation, actions] = rendered["blocks"]
    text = explanation["text"]["text"]
    assert text =~ "*1 · Conversations*"
    assert text =~ "*Mentions only* — I'll read along"
    assert text =~ "*Be proactive* — I'll read the messages in this channel and join in"
    assert text =~ "*Observe only* — I'll keep reading and learning, but I won't reply"
    assert text =~ "<@UBOT>"
    refute text =~ "expires"

    assert Enum.map(actions["elements"], &{&1["action_id"], &1["text"]["text"]}) == [
             {"ryker_setup_participation_mentions", "Mentions only"},
             {"ryker_setup_participation_proactive", "Be proactive"},
             {"ryker_setup_participation_shadow", "Observe only"}
           ]

    assert Enum.all?(actions["elements"], &(&1["value"] == session_ref))

    alerts = put_in(setup_document(session_ref), ["channel_setup", "step"], "alerts")
    assert {:ok, rendered} = Renderer.render(alerts)
    [explanation, actions] = rendered["blocks"]

    assert explanation["text"]["text"] =~
             "*Investigate here* — I'll look into it in the alert's own thread"

    assert explanation["text"]["text"] =~ "*Offer a room* — I'll start in the thread"
    assert explanation["text"]["text"] =~ "*Always open a room* — every alert I investigate"

    assert Enum.map(actions["elements"], & &1["text"]["text"]) == [
             "Investigate here",
             "Offer a room",
             "Always open a room"
           ]

    audience =
      setup_document(session_ref)
      |> put_in(["channel_setup", "step"], "audience")

    assert {:ok, rendered} = Renderer.render(audience)
    [explanation, actions] = rendered["blocks"]

    assert explanation["text"]["text"] =~
             "Reply in this thread with the people or user groups you want in the room"

    assert explanation["text"]["text"] =~ "Reply in this thread with the people or user groups"

    assert Enum.map(actions["elements"], &{&1["action_id"], &1["text"]["text"]}) == [
             {"ryker_setup_audience_none", "Nobody automatically"}
           ]

    environment =
      setup_document(session_ref)
      |> put_in(["channel_setup", "step"], "environment")

    assert {:ok, rendered} = Renderer.render(environment)
    [explanation, actions] = rendered["blocks"]

    assert explanation["text"]["text"] =~
             "*Production* — I'll make changes in `ryker`, read `docs`, and use Emisar."

    assert explanation["text"]["text"] =~
             "*No environment* — I'll still answer here, but without any repos or Emisar."

    assert Enum.map(actions["elements"], &{&1["action_id"], &1["text"]["text"]}) == [
             {"ryker_setup_environment_0", "Production"},
             {"ryker_setup_environment_none", "No environment"}
           ]

    confirm =
      setup_document(session_ref)
      |> put_in(["channel_setup", "status"], "confirming")
      |> put_in(["channel_setup", "step"], "confirm")
      |> put_in(["channel_setup", "draft", "participation"], "proactive")
      |> put_in(["channel_setup", "draft", "environment_ref"], "production")
      |> put_in(["channel_setup", "draft", "alert_policy"], "offer")
      |> put_in(["channel_setup", "draft", "invite_user_refs"], ["U123"])

    assert {:ok, rendered} = Renderer.render(confirm)
    [summary, actions] = rendered["blocks"]

    assert summary["text"]["text"] =~
             "• I'll join conversations when I think you could use my help."

    assert summary["text"]["text"] =~ "• I'll work in the *Production* environment."

    # An unanswered environment is not an answer of No environment.
    unanswered =
      update_in(confirm, ["channel_setup", "draft"], &Map.delete(&1, "environment_ref"))

    assert Renderer.render(unanswered) == {:error, {:invalid_slack_render, :channel_setup}}

    none = put_in(confirm, ["channel_setup", "draft", "environment_ref"], nil)
    assert {:ok, %{"blocks" => [none_summary | _controls]}} = Renderer.render(none)

    assert none_summary["text"]["text"] =~
             "• I won't use an environment, so I'll answer without any repos or Emisar."

    assert summary["text"]["text"] =~ "I'll invite <@U123>."

    assert summary["text"]["text"] =~
             "*Save settings* — I'll start using these choices and update my welcome message"

    assert Enum.map(actions["elements"], & &1["text"]["text"]) == [
             "Save settings",
             "Start over",
             "Cancel"
           ]
  end

  test "an engineering offer briefs the reader from facts, never from the prompt" do
    # The catalog's `long-task-offer/offer` wants the reader to see what the task
    # will do before they authorize it, and `d98b1d9f` forbids the model's own
    # instruction on a surface whose button grants authority. Both hold at once:
    # the brief is built from the fields the host validated — what it checks,
    # what it may not do, and the exact source — and never from `prompt`.
    document = %{
      "message" => "I can prepare that repository change.",
      "records" => [
        %{
          "kind" => "task_offer",
          "payload" => %{
            "authority_limits" => ["do not merge or deploy", "no schema changes"],
            "instruction_ref" => "input:slack:abc123",
            "kind" => "engineering",
            "prompt" => "Change the parser and run focused tests.",
            "repository" => "ryker",
            "repository_source" => %{"kind" => "branch", "name" => "main"},
            "source_refs" => ["record:evidence:one", "record:evidence:two"],
            "success_checks" => ["focused parser tests pass", "no new credo findings"],
            "title" => "Fix parser retries"
          },
          "ref" => "record:task_offer:abc123",
          "status" => "open"
        }
      ]
    }

    assert {:ok, rendered} = Renderer.render(document)

    text =
      rendered["blocks"]
      |> Enum.map(fn
        %{"text" => %{"text" => value}} -> value
        _block -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    assert text =~ "Fix parser retries"
    assert text =~ "focused parser tests pass"
    assert text =~ "no new credo findings"
    assert text =~ "do not merge or deploy"
    assert text =~ "branch `main`"
    assert text =~ "2 sources"

    # The rule that made this a conflict, still enforced.
    refute inspect(rendered) =~ "Change the parser"
  end

  test "renders an engineering task offer as host-owned Block Kit" do
    document = %{
      "message" => "I can prepare that repository change.",
      "records" => [
        %{
          "kind" => "task_offer",
          "payload" => %{
            "kind" => "engineering",
            "prompt" => "Change the parser and run focused tests.",
            "repository" => "ryker",
            "title" => "Fix parser retries"
          },
          "ref" => "record:task_offer:abc123",
          "status" => "open"
        }
      ]
    }

    assert {:ok, rendered} = Renderer.render(document)
    assert rendered["text"] == "I can prepare that repository change."

    assert [reply, offer, controls] = rendered["blocks"]

    assert reply == %{
             "text" => "I can prepare that repository change.",
             "type" => "markdown"
           }

    assert offer["type"] == "section"
    assert offer["text"]["type"] == "mrkdwn"
    assert offer["text"]["text"] =~ "*Fix parser retries*"
    assert offer["text"]["text"] =~ "Repository: `ryker`"

    assert %{
             "action_id" => "ryker_start_engineering_task",
             "confirm" => %{
               "confirm" => %{"text" => "Start task"},
               "deny" => %{"text" => "Cancel"},
               "text" => %{"text" => confirmation},
               "title" => %{"text" => "Start engineering task"}
             },
             "style" => "primary",
             "text" => %{"text" => "Start task"},
             "type" => "button",
             "value" => "record:task_offer:abc123"
           } = hd(controls["elements"])

    assert confirmation =~ "isolated working copy"
    refute inspect(rendered) =~ "Change the parser"
  end

  test "renders a durable engineering task projection without model-owned controls" do
    assert {:ok, rendered} =
             Renderer.render(%{
               "task_card" => %{
                 "action_needed" => nil,
                 "confirmed_at" => "2026-08-28T12:00:00.000000Z",
                 "confirmed_by" => "slack:user:U123",
                 "controls" => ["stop", "view_diff", "close", "timeline", "evidence", "handoff"],
                 "episode_state" => "working",
                 "publication" => nil,
                 "repository" => "ryker",
                 "session_generation" => 1,
                 "stages" => task_stages(),
                 "status" => "working",
                 "summary" => "The parser fix is being validated.",
                 "task_ref" => "task-card:abc123",
                 "title" => "Fix parser retries",
                 "ui_revision" => 2,
                 "updated_at" => "2026-08-28T12:01:00.000000Z",
                 "work_state" => "pending"
               }
             })

    # Slack truncates a notification hard, so the first characters are the most
    # valuable ones on the card and they were spent on eight characters of an
    # opaque ref. The title is what a person recognizes the work by.
    assert String.starts_with?(rendered["text"], "Fix parser retries: Working.")
    assert rendered["text"] =~ "The parser fix is being validated"
    refute rendered["text"] =~ "abc123"

    # The ledger is the status; a boilerplate reply instruction is not.
    assert Enum.any?(rendered["blocks"], fn block ->
             text = get_in(block, ["text", "text"])
             is_binary(text) and text =~ "*Progress*\n○ Workspace setup"
           end)

    refute Jason.encode!(rendered) =~ "Reply in this thread"

    assert [controls] = Enum.filter(rendered["blocks"], &(&1["type"] == "actions"))

    assert Enum.map(controls["elements"], & &1["action_id"]) == [
             "ryker_stop_work",
             "ryker_close_work",
             "ryker_work_record"
           ]

    record = List.last(controls["elements"])

    assert Enum.map(record["options"], & &1["value"]) == [
             "task-card:abc123|timeline",
             "task-card:abc123|evidence",
             "task-card:abc123|handoff"
           ]
  end

  # Diff reading is web-only since 2026-09-09. `view_diff` survives on the shared
  # work document because the control-plane card still links out to the exact
  # retained snapshot; Slack must render no diff button and accept no diff
  # document, or the retired paging loop comes back one message at a time.
  test "no work card emits a Slack diff control" do
    digest = String.duplicate("a", 64)

    assert Renderer.render(%{
             "work_diff" => %{
               "message" => "Workspace diff for task-card:abc123\nPatch page",
               "patch_bytes" => 7_200,
               "patch_digest" => digest,
               "patch_has_more" => true,
               "patch_next_offset" => 4_800,
               "patch_offset" => 2_400,
               "work_ref" => "task-card:abc123"
             }
           }) == {:error, {:invalid_slack_render, :document}}

    task = %{
      "action_needed" => nil,
      "confirmed_at" => "2026-08-28T12:00:00.000000Z",
      "confirmed_by" => "slack:user:U123",
      "controls" => ["stop", "view_diff", "close", "timeline", "evidence", "handoff"],
      "episode_state" => "working",
      "publication" => nil,
      "repository" => "ryker",
      "session_generation" => 1,
      "stages" => task_stages(),
      "status" => "working",
      "summary" => "The parser fix is being validated.",
      "task_ref" => "task-card:abc123",
      "title" => "Fix parser retries",
      "ui_revision" => 2,
      "updated_at" => "2026-08-28T12:01:00.000000Z",
      "work_state" => "pending"
    }

    room = %{
      "action_needed" => nil,
      "alert" => nil,
      "controls" => ["stop", "view_diff", "close", "timeline", "evidence", "handoff"],
      "episode_state" => "working",
      "goals" => [],
      "opened_at" => "2026-08-28T12:00:00.000000Z",
      "opened_by" => "slack:user:U123",
      "repository" => "ryker",
      "room_ref" => "incident-room:82208f8f-2ef4-4f1b-a011-626aabdc9342",
      "session_generation" => 1,
      "severity" => "not supplied",
      "signals" => %{"firing" => nil, "total" => nil},
      "source" => %{
        "channel_ref" => "C123",
        "message_ref" => "1787832000.000100",
        "thread_ref" => nil
      },
      "status" => "investigating",
      "summary" => "Checking the production symptoms.",
      "title" => "Checkout errors",
      "ui_revision" => 2,
      "updated_at" => "2026-08-28T12:01:00.000000Z"
    }

    for document <- [%{"task_card" => task}, %{"incident_room" => room}] do
      assert {:ok, rendered} = Renderer.render(document)

      action_ids =
        rendered["blocks"]
        |> Enum.flat_map(&Map.get(&1, "elements", []))
        |> Enum.map(& &1["action_id"])

      refute Enum.any?(action_ids, &(is_binary(&1) and &1 =~ "diff"))
      refute Jason.encode!(rendered) =~ "View diff"
    end
  end

  test "a blocked publication names the branch it is stuck on" do
    # The 2026-09-12 coverage measurement: "PR creation is blocked" told the
    # reader nothing about which branch, and this installation publishes no web
    # console URL to go and look. The branch is a fact the host already held.
    blocked =
      publication_task_card(%{
        "branch" => "refs/heads/ryker/publication-42",
        "controls" => ["update", "discard"],
        "publication_ref" => "publication:def456",
        "pull_request_number" => nil,
        "pull_request_url" => nil,
        "recovery_generation" => 1,
        "status" => "blocked",
        "unverified" => nil
      })

    assert {:ok, rendered} = Renderer.render(%{"task_card" => blocked})
    assert Jason.encode!(rendered) =~ "refs/heads/ryker/publication-42"

    reviewed = put_in(blocked, ["publication", "status"], "reviewed")
    assert {:ok, reviewed_rendered} = Renderer.render(%{"task_card" => reviewed})
    refute Jason.encode!(reviewed_rendered) =~ "refs/heads/ryker/publication-42"
  end

  test "renders only publication actions valid for the durable task state" do
    task = %{
      "action_needed" => nil,
      "confirmed_at" => "2026-08-28T12:00:00.000000Z",
      "confirmed_by" => "slack:user:U123",
      "controls" => ["view_diff", "timeline", "evidence", "handoff"],
      "episode_state" => "complete",
      "publication" => %{
        "branch" => "refs/heads/ryker/card",
        "controls" => ["open", "check"],
        "publication_ref" => "publication:def456",
        "pull_request_number" => 91,
        "pull_request_url" => "https://github.com/acme/ryker/pull/91",
        "recovery_generation" => 1,
        "status" => "published",
        "unverified" => nil
      },
      "repository" => "ryker",
      "session_generation" => 1,
      "stages" => task_stages(),
      "status" => "published",
      "summary" => "The reviewed change is available as a draft PR.",
      "task_ref" => "task-card:abc123",
      "title" => "Fix parser retries",
      "ui_revision" => 3,
      "updated_at" => "2026-08-28T12:01:00.000000Z",
      "work_state" => "settled"
    }

    assert {:ok, rendered} = Renderer.render(%{"task_card" => task})

    publication_controls =
      rendered["blocks"]
      |> Enum.filter(&(&1["type"] == "actions"))
      |> Enum.find(fn block ->
        Enum.any?(block["elements"], &(&1["action_id"] == "ryker_task_check"))
      end)

    assert Enum.map(publication_controls["elements"], & &1["action_id"]) == [
             "ryker_open_publication",
             "ryker_task_check"
           ]

    assert hd(publication_controls["elements"])["url"] ==
             "https://github.com/acme/ryker/pull/91"

    assert List.last(publication_controls["elements"])["value"] ==
             "task-card:abc123|publication:def456"

    reviewed =
      put_in(task, ["publication"], %{
        "branch" => "refs/heads/ryker/card",
        "controls" => ["publish"],
        "publication_ref" => "publication:def456",
        "pull_request_number" => nil,
        "pull_request_url" => nil,
        "recovery_generation" => 1,
        "status" => "reviewed",
        "unverified" => nil
      })

    assert {:ok, reviewed_rendered} = Renderer.render(%{"task_card" => reviewed})

    assert reviewed_rendered["blocks"]
           |> Enum.flat_map(&Map.get(&1, "elements", []))
           |> Enum.any?(&(&1["action_id"] == "ryker_task_publish"))

    recoverable =
      put_in(task, ["publication"], %{
        "branch" => "refs/heads/ryker/card",
        "controls" => ["update", "discard"],
        "publication_ref" => "publication:def456",
        "pull_request_number" => nil,
        "pull_request_url" => nil,
        "recovery_generation" => 3,
        "status" => "blocked",
        "unverified" => nil
      })

    assert {:ok, recovery_rendered} = Renderer.render(%{"task_card" => recoverable})
    assert Jason.encode!(recovery_rendered) =~ "PR creation is blocked"
    refute Jason.encode!(recovery_rendered) =~ "Publication:"

    recovery_buttons =
      recovery_rendered["blocks"]
      |> Enum.flat_map(&Map.get(&1, "elements", []))
      |> Enum.filter(&String.starts_with?(&1["action_id"] || "", "ryker_task_"))

    assert Enum.map(recovery_buttons, &{&1["action_id"], &1["value"]}) == [
             {"ryker_task_update_publication", "task-card:abc123|publication:def456|3"},
             {"ryker_task_discard_publication", "task-card:abc123|publication:def456|3"}
           ]

    stale =
      put_in(task, ["publication"], %{
        "branch" => "refs/heads/ryker/card",
        "controls" => ["open", "check", "update", "discard"],
        "publication_ref" => "publication:def456",
        "pull_request_number" => 91,
        "pull_request_url" => "https://github.com/acme/ryker/pull/91",
        "recovery_generation" => 4,
        "status" => "published",
        "unverified" => nil
      })

    assert {:ok, stale_rendered} = Renderer.render(%{"task_card" => stale})

    stale_buttons =
      stale_rendered["blocks"]
      |> Enum.flat_map(&Map.get(&1, "elements", []))
      |> Enum.filter(&String.starts_with?(&1["action_id"] || "", "ryker_task_"))

    assert Enum.map(stale_buttons, & &1["action_id"]) == [
             "ryker_task_check",
             "ryker_task_update_publication",
             "ryker_task_discard_publication"
           ]
  end

  # A draft opened because a required check could not run stays unverified after
  # it exists. "Draft PR created. Open it to review the changes." said nothing
  # about the gate that never started, one message after a card that had named it.
  test "an opened draft keeps naming the check that never finished" do
    task = %{
      "action_needed" => nil,
      "confirmed_at" => "2026-08-28T12:00:00.000000Z",
      "confirmed_by" => "slack:user:U123",
      "controls" => ["view_diff", "timeline", "evidence", "handoff"],
      "episode_state" => "complete",
      "publication" => %{
        "branch" => "refs/heads/ryker/card",
        "controls" => ["open", "check"],
        "publication_ref" => "publication:def456",
        "pull_request_number" => 91,
        "pull_request_url" => "https://github.com/acme/ryker/pull/91",
        "recovery_generation" => 1,
        "status" => "published",
        "unverified" => "docker: command not found"
      },
      "repository" => "ryker",
      "session_generation" => 1,
      "stages" => task_stages(),
      "status" => "published",
      "summary" => "The saved change is available as an unverified draft PR.",
      "task_ref" => "task-card:abc123",
      "title" => "Bump the hosted runner",
      "ui_revision" => 7,
      "updated_at" => "2026-08-28T12:01:00.000000Z",
      "work_state" => "settled"
    }

    assert {:ok, rendered} = Renderer.render(%{"task_card" => task})
    json = Jason.encode!(rendered)
    assert json =~ "the checks still haven't finished (docker: command not found)"
    assert json =~ "It isn't verified, and a draft doesn't merge or deploy anything."
    assert json =~ "Open PR"
    refute json =~ "Open it to review the changes"

    checked = put_in(task, ["publication", "unverified"], nil)
    assert {:ok, checked_rendered} = Renderer.render(%{"task_card" => checked})
    assert Jason.encode!(checked_rendered) =~ "Draft PR created. Open it to review the changes."
  end

  # "Review recovery" is the only control a card with no saved workspace can
  # offer: there is no changes page to open, nothing to publish and no retry
  # that reaches the stranded working copy.
  test "a work card offers recovery as a record control, never as a work button" do
    task = %{
      "action_needed" => "The worker finished, but I couldn't save its working copy.",
      "confirmed_at" => "2026-08-28T12:00:00.000000Z",
      "confirmed_by" => "slack:user:U123",
      "controls" => ["close", "timeline", "evidence", "handoff", "recovery"],
      "episode_state" => "working",
      "publication" => nil,
      "repository" => "ryker",
      "session_generation" => 1,
      "stages" => task_stages(),
      "status" => "action_required",
      "summary" => "The prepared change is saved but unrecovered.",
      "task_ref" => "task-card:abc123",
      "title" => "Bump the hosted runner",
      "ui_revision" => 7,
      "updated_at" => "2026-08-28T12:01:00.000000Z",
      "work_state" => "blocked"
    }

    assert {:ok, rendered} = Renderer.render(%{"task_card" => task})

    elements = Enum.flat_map(rendered["blocks"], &Map.get(&1, "elements", []))
    overflow = Enum.find(elements, &(&1["action_id"] == "ryker_work_record"))

    assert Enum.map(overflow["options"], &{&1["text"]["text"], &1["value"]}) == [
             {"Timeline", "task-card:abc123|timeline"},
             {"Evidence", "task-card:abc123|evidence"},
             {"Handoff summary", "task-card:abc123|handoff"},
             {"Review recovery", "task-card:abc123|recovery"}
           ]

    refute Enum.any?(
             elements,
             &(&1["type"] == "button" and &1["text"]["text"] == "Review recovery")
           )

    refute Jason.encode!(rendered) =~ "View diff"
  end

  # The button read "Resume task" and its dialog promised "Continue from the
  # stopped run, in the same session and working copy. Nothing already done is
  # repeated." Pressing it starts a new run in which the model works on the task
  # again from the start, which is what the Failures page already said for the
  # same step. A person who trusted the dialog lost work the stopped run had not
  # saved; the two surfaces must describe the one action in the same words.
  test "the Slack control that restarts a stopped task says it runs the task again, in the Failures page's words" do
    fingerprint = String.duplicate("a", 64)

    task = %{
      "action_needed" => "The operator stopped the current run.",
      "confirmed_at" => "2026-08-28T12:00:00.000000Z",
      "confirmed_by" => "slack:user:U123",
      "controls" => ["resume", "close", "timeline", "evidence", "handoff"],
      "episode_state" => "working",
      "publication" => nil,
      "repository" => "ryker",
      "resume_ref" => "task-card:abc123|" <> fingerprint,
      "session_generation" => 1,
      "stages" => task_stages(),
      "status" => "action_required",
      "summary" => "The run was stopped before it finished.",
      "task_ref" => "task-card:abc123",
      "title" => "Fix parser retries",
      "ui_revision" => 4,
      "updated_at" => "2026-08-28T12:01:00.000000Z",
      "work_state" => "blocked"
    }

    assert {:ok, rendered} = Renderer.render(%{"task_card" => task})

    button =
      rendered["blocks"]
      |> Enum.flat_map(&Map.get(&1, "elements", []))
      |> Enum.find(&(&1["action_id"] == "ryker_resume_work"))

    # The same stopped turn, as the Failures page and the request page read it.
    stopped = %Turn{
      cancellation_intent: %{"action" => "block", "reason" => "operator stopped the run"},
      id: Ecto.UUID.generate(),
      last_error_code: "work_execution_blocked",
      last_error_detail: "The operator stopped the current run.",
      status: :blocked
    }

    failures = WorkRecovery.project(stopped, :ok, true, nil)

    assert button["text"]["text"] == failures.action_label
    assert button["confirm"]["text"]["text"] == failures.retry_effect
    assert button["confirm"]["title"]["text"] == "Run this task again?"
    assert button["value"] == task["resume_ref"]

    dialog = Jason.encode!(button)
    refute dialog =~ "Nothing already done is repeated"
    refute dialog =~ "same session"
    refute dialog =~ "Resume"
  end

  test "renders incident controls from the host projection and rejects invented controls" do
    room_ref = "incident-room:82208f8f-2ef4-4f1b-a011-626aabdc9342"

    room = %{
      "action_needed" => nil,
      "alert" => nil,
      "controls" => [
        "stop",
        "view_diff",
        "close",
        "timeline",
        "evidence",
        "handoff",
        "postmortem"
      ],
      "goals" => [],
      "episode_state" => "working",
      "opened_at" => "2026-08-28T12:00:00.000000Z",
      "opened_by" => "slack:user:U123",
      "repository" => "ryker",
      "room_ref" => room_ref,
      "session_generation" => 1,
      "severity" => "not supplied",
      "signals" => %{"firing" => nil, "total" => nil},
      "source" => %{
        "channel_ref" => "C123",
        "message_ref" => "1787832000.000100",
        "thread_ref" => nil
      },
      "status" => "investigating",
      "summary" => "Checking the production symptoms.",
      "title" => "Checkout errors",
      "ui_revision" => 2,
      "updated_at" => "2026-08-28T12:01:00.000000Z"
    }

    assert {:ok, rendered} = Renderer.render(%{"incident_room" => room})
    assert [controls] = Enum.filter(rendered["blocks"], &(&1["type"] == "actions"))
    assert List.last(controls["elements"])["type"] == "overflow"

    invented = put_in(room, ["controls"], ["delete_repository"])

    assert Renderer.render(%{"incident_room" => invented}) ==
             {:error, {:invalid_slack_render, :incident_room}}
  end

  # A resume button is only as safe as the recovery fingerprint it carries, and
  # an incident card has none. The incident document still accepted `resume`, so
  # it rendered a Resume button with no value at all: a press the interaction
  # layer refuses, on the card an operator is reading mid-incident.
  test "an incident card refuses a resume control it has no fingerprint for" do
    room = %{incident_document("action_required") | "controls" => ["resume", "close"]}

    assert Renderer.render(%{"incident_room" => room}) ==
             {:error, {:invalid_slack_render, :incident_room}}
  end

  test "incident offers use operator confirmation and model text cannot create controls" do
    assert {:ok, plain} =
             Renderer.render(%{
               "message" =>
                 ~s({"type":"actions","elements":[{"type":"button","action_id":"evil"}]}),
               "records" => []
             })

    assert [section] = plain["blocks"]
    assert section["type"] == "markdown"
    refute inspect(plain) =~ ~s("action_id" => "evil")

    assert {:ok, incident} =
             Renderer.render(%{
               "message" => "This should be coordinated as an incident.",
               "records" => [
                 %{
                   "kind" => "task_offer",
                   "payload" => %{
                     "kind" => "incident",
                     "prompt" => "Coordinate this incident.",
                     "repository" => nil,
                     "title" => "Checkout errors"
                   },
                   "ref" => "record:task_offer:def456",
                   "status" => "open"
                 }
               ]
             })

    # One offer identity owns both paths; Open incident room is a link only
    # once the room exists, never a button that hides room creation.
    assert [_, _, actions] = incident["blocks"]
    assert [investigate, create] = actions["elements"]
    assert investigate["action_id"] == "ryker_investigate_incident"
    assert investigate["text"]["text"] == "Investigate"
    assert investigate["value"] == "record:task_offer:def456"

    assert investigate["confirm"]["text"]["text"] =~
             "No incident room is created and nobody is invited"

    assert create["action_id"] == "ryker_open_incident"
    assert create["text"]["text"] == "Create incident room"
    assert create["value"] == "record:task_offer:def456"
    refute inspect(incident) =~ "Open incident room"

    offer = %{
      "kind" => "task_offer",
      "payload" => %{
        "kind" => "incident",
        "prompt" => "Coordinate this incident.",
        "repository" => nil,
        "title" => "Checkout errors"
      },
      "ref" => "record:task_offer:def456",
      "status" => "confirmed"
    }

    assert {:ok, investigating} =
             Renderer.render(%{"message" => "Started.", "records" => [offer]})

    assert inspect(investigating) =~ "✓ Investigating in this thread."
    refute Enum.any?(investigating["blocks"], &(&1["type"] == "actions"))

    room_url = "https://slack.com/app_redirect?team=T123&channel=CINCIDENT"

    assert {:ok, created} =
             Renderer.render(%{
               "message" => "Started.",
               "records" => [
                 Map.put(offer, "presentation", %{"incident_room" => %{"url" => room_url}})
               ]
             })

    assert inspect(created) =~ "✓ Incident room created."
    assert [link] = List.last(created["blocks"])["elements"]
    assert link["text"]["text"] == "Open incident room"
    assert link["url"] == room_url

    assert {:ok, requested} =
             Renderer.render(%{
               "message" => "Started.",
               "records" => [
                 Map.put(offer, "presentation", %{"incident_room" => %{"url" => nil}})
               ]
             })

    assert inspect(requested) =~ "◷ Incident room requested"
    refute Enum.any?(requested["blocks"], &(&1["type"] == "actions"))

    assert {:ok, task} =
             Renderer.render(%{
               "message" => "Started.",
               "records" => [
                 %{
                   offer
                   | "payload" => %{
                       "kind" => "engineering",
                       "prompt" => "Fix it.",
                       "repository" => "ryker",
                       "title" => "Fix parser retries"
                     }
                 }
               ]
             })

    assert inspect(task) =~ "✓ Task started in this thread."
  end

  # Confirming an offer used to repaint the card down to its title and a check
  # mark, so the one message that recorded what was authorized stopped saying
  # what that was. The reader who comes back to the thread an hour later is
  # reading this card to find out what it agreed to, and the answer was gone.
  test "confirming an offer keeps what the card said it was authorizing" do
    payload = %{
      "authority_limits" => ["Never deploy", "No production writes"],
      "instruction_ref" => "record:instruction:aa11",
      "kind" => "engineering",
      "prompt" => "Raise the memory limit.",
      "repository" => "blitz-infra",
      "repository_source" => %{"kind" => "branch", "name" => "main"},
      "source_refs" => ["record:evidence:bb22"],
      "success_checks" => ["Traefik stays under its limit", "Five replicas remain"],
      "title" => "Prevent the next Traefik OOM"
    }

    offer = %{
      "kind" => "task_offer",
      "payload" => payload,
      "ref" => "record:task_offer:abc123",
      "status" => "open"
    }

    assert {:ok, open} = Renderer.render(%{"message" => "Want me to?", "records" => [offer]})

    assert {:ok, confirmed} =
             Renderer.render(%{
               "message" => "Started.",
               "records" => [%{offer | "status" => "confirmed"}]
             })

    for kept <- [
          "Prevent the next Traefik OOM",
          "blitz-infra",
          "branch",
          "Traefik stays under its limit",
          "Never deploy",
          "*Evidence:* 1 source"
        ] do
      assert inspect(open) =~ kept
      assert inspect(confirmed) =~ kept
    end

    # The authority is spent, so the button that granted it is gone.
    assert inspect(confirmed) =~ "✓ Task started in this thread."
    refute Enum.any?(confirmed["blocks"], &(&1["type"] == "actions"))

    # An incident offer carries the same authority fields — production offers
    # do, harvested 2026-09-13 — and showing none of them left the card that
    # decides whether to open a room saying only what it was called.
    incident = %{
      offer
      | "payload" => %{
          "authority_limits" => ["Do not restart the agent", "Do not page the on-call"],
          "instruction_ref" => "record:instruction:cc33",
          "kind" => "incident",
          "prompt" => "Coordinate this incident.",
          "repository" => nil,
          "source_refs" => ["record:evidence:dd44"],
          "success_checks" => ["Whether logs are being lost is answered"],
          "title" => "Vector logging errors"
        }
    }

    assert {:ok, incident_open} =
             Renderer.render(%{"message" => "Where?", "records" => [incident]})

    assert {:ok, incident_confirmed} =
             Renderer.render(%{
               "message" => "Started.",
               "records" => [%{incident | "status" => "confirmed"}]
             })

    for kept <- ["Whether logs are being lost is answered", "Do not restart the agent"] do
      assert inspect(incident_open) =~ kept
      assert inspect(incident_confirmed) =~ kept
    end

    assert inspect(incident_confirmed) =~ "✓ Investigating in this thread."
  end

  # The brief counted its evidence without looking at the count, so every offer
  # that cited a single source asked the person authorizing it to trust
  # "1 sources" — the card that grants authority read like a template.
  test "an offer that cites one source counts it in the singular" do
    payload = %{
      "authority_limits" => ["Never deploy"],
      "instruction_ref" => "record:instruction:aa11",
      "kind" => "engineering",
      "prompt" => "Raise the memory limit.",
      "repository" => "blitz-infra",
      "repository_source" => nil,
      "source_refs" => ["record:evidence:bb22"],
      "success_checks" => ["Traefik stays under its limit"],
      "title" => "Prevent the next Traefik OOM"
    }

    offer = %{
      "kind" => "task_offer",
      "payload" => payload,
      "ref" => "record:task_offer:abc123",
      "status" => "open"
    }

    assert {:ok, one} = Renderer.render(%{"message" => "Want me to?", "records" => [offer]})
    assert Jason.encode!(one) =~ "*Evidence:* 1 source"
    refute Jason.encode!(one) =~ "1 sources"

    two =
      put_in(offer, ["payload", "source_refs"], ["record:evidence:bb22", "record:evidence:cc33"])

    assert {:ok, rendered} = Renderer.render(%{"message" => "Want me to?", "records" => [two]})
    assert Jason.encode!(rendered) =~ "*Evidence:* 2 sources"
  end

  # The brief escaped each check and limit before cutting it to length, so a
  # cut could land inside an entity: the person deciding whether to grant the
  # task read a stray `&a…` where the limit had said `&`.
  test "an offer's brief is cut to length before it is escaped" do
    limit = String.duplicate("a", 197) <> "&" <> String.duplicate("x", 10)

    offer = %{
      "kind" => "task_offer",
      "payload" => %{
        "authority_limits" => [limit],
        "instruction_ref" => "record:instruction:aa11",
        "kind" => "engineering",
        "prompt" => "Raise the memory limit.",
        "repository" => "blitz-infra",
        "repository_source" => nil,
        "source_refs" => [],
        "success_checks" => ["Traefik stays under its limit"],
        "title" => "Prevent the next Traefik OOM"
      },
      "ref" => "record:task_offer:abc123",
      "status" => "open"
    }

    assert {:ok, rendered} = Renderer.render(%{"message" => "Want me to?", "records" => [offer]})
    [_message, summary, _actions] = rendered["blocks"]

    assert summary["text"]["text"] =~
             "*Will not:* #{String.duplicate("a", 197)}&amp;x…"
  end

  test "renders an inert publication offer with a host-owned review control" do
    assert {:ok, rendered} =
             Renderer.render(%{
               "message" => "The implementation is committed and ready for review.",
               "records" => [
                 %{
                   "kind" => "publication_offer",
                   "payload" => %{
                     "body" => "Implements the requested retry boundary.",
                     "title" => "Fix retry reconciliation"
                   },
                   "ref" => "record:publication_offer:abc123",
                   "status" => "open"
                 }
               ]
             })

    [_, offer, actions] = rendered["blocks"]
    assert offer["text"]["text"] =~ "Fix retry reconciliation"
    assert offer["text"]["text"] =~ "No branch or pull request has been published"

    assert [%{"action_id" => "ryker_review_publication"} = button] = actions["elements"]
    assert button["value"] == "record:publication_offer:abc123"
    assert button["confirm"]["text"]["text"] =~ "read-only Coop review"
  end

  test "the first governed-review card is the card its decisions will repaint" do
    document = %{
      "message" => "The action has not run. It is waiting for Emisar approval.",
      "records" => [
        %{
          "kind" => "emisar_approval",
          "payload" => %{
            "action_id" => "nomad.alloc_restart",
            "approval_url" => "https://emisar.example/app/acme/approvals/apr-1",
            "expires_at" => "2099-08-29T12:00:00.000000Z",
            "operation_id" => "op-1",
            "pack_ref" => "nomad@1#sha256:abc",
            "request_id" => "apr-1",
            "run_id" => "run-1",
            "runner_ref" => "production-runner",
            "status" => "pending_approval"
          },
          "ref" => "record:emisar_approval:abc123",
          "status" => "open"
        }
      ]
    }

    assert {:ok, rendered} = Renderer.render(document)
    [_message | blocks] = rendered["blocks"]

    assert headings(blocks) == ["Emisar review", "Action", "Runner", "Status"]
    assert status_text(blocks) =~ "◷ Waiting for review."

    # Review happens in Emisar, and while a decision is open its link is the
    # card's accented primary action.
    assert [%{"elements" => [button]}] = Enum.filter(blocks, &(&1["type"] == "actions"))
    assert button["action_id"] == "ryker_open_emisar_approval"
    assert button["text"]["text"] == "Review in Emisar"
    assert button["style"] == "primary"
    assert button["url"] == "https://emisar.example/app/acme/approvals/apr-1"

    malformed = put_in(document, ["records", Access.at(0), "payload", "request_id"], "other")
    assert {:error, {:invalid_slack_render, :record}} = Renderer.render(malformed)
  end

  test "a pending review leads with the dispatch rationale and a trusted command block" do
    assert {:ok, rendered} =
             Renderer.render(%{
               "emisar_approval_status" =>
                 approval_status("pending_approval", nil, review(%{"approved_count" => 0}))
             })

    blocks = rendered["blocks"]

    # Operator-facing dispatch metadata first, in one fixed order, then what
    # will actually run, then who runs it.
    assert headings(blocks) == [
             "Emisar review",
             "Reason",
             "Evidence",
             "Expected outcome",
             "Command to run",
             "Runner",
             "Status"
           ]

    assert [code] = Enum.filter(blocks, &(&1["type"] == "rich_text"))

    assert code["elements"] == [
             %{
               "type" => "rich_text_preformatted",
               "elements" => [
                 %{"type" => "text", "text" => "vmctl query-range --query 'sum(...)' --step 60s"}
               ]
             }
           ]

    # Headings this card owns carry no colon; retained prose keeps its own.
    for heading <- headings(blocks), do: refute(String.ends_with?(heading, ":"))
    assert status_text(blocks) =~ "◷ 0 of 2 reviews received."

    # Both controls link out and nothing on this card mutates: Slack cannot
    # approve a governed action, and no button here pretends otherwise.
    assert [%{"elements" => buttons}] = Enum.filter(blocks, &(&1["type"] == "actions"))

    assert Enum.map(buttons, & &1["action_id"]) == [
             "ryker_open_emisar_approval",
             "ryker_open_emisar_run"
           ]

    assert Enum.all?(buttons, &is_binary(&1["url"]))
  end

  test "without a provable command the card names the action and where its arguments are" do
    assert {:ok, rendered} =
             Renderer.render(%{
               "emisar_approval_status" =>
                 approval_status(
                   "pending_approval",
                   nil,
                   review(%{"argument_count" => 3}) |> Map.delete("command")
                 )
             })

    blocks = rendered["blocks"]

    assert headings(blocks) == [
             "Emisar review",
             "Reason",
             "Evidence",
             "Expected outcome",
             "Action",
             "Runner",
             "Status"
           ]

    # The note belongs under the Action block and before Runner, not in a
    # disconnected footer.
    kinds = Enum.map(blocks, & &1["type"])
    action_index = Enum.find_index(blocks, &(section_text(&1) == "*Action*"))

    runner_index =
      Enum.find_index(blocks, &String.starts_with?(section_text(&1) || "", "*Runner*"))

    note_index = Enum.find_index(blocks, &(context_text(&1) =~ "arguments in Emisar"))

    assert Enum.at(kinds, action_index + 1) == "rich_text"
    assert note_index == action_index + 2
    assert note_index < runner_index
    assert context_text(Enum.at(blocks, note_index)) == "3 arguments in Emisar."
  end

  test "an executed run reports a receipt, never a command it would run" do
    executed = %{"kind" => "executed", "text" => "df -P -h /srv", "truncated" => true}

    assert {:ok, rendered} =
             Renderer.render(%{
               "emisar_approval_status" =>
                 approval_status(
                   "success",
                   nil,
                   review(%{
                     "status" => "approved",
                     "approved_count" => 2,
                     "command" => executed,
                     "decisions" => [approve("Jane Doe"), approve("Sam Reviewer")]
                   })
                 )
             })

    blocks = rendered["blocks"]
    assert "Executed command" in headings(blocks)
    refute "Command to run" in headings(blocks)

    assert Enum.any?(blocks, &(context_text(&1) =~ "Command truncated"))
  end

  test "every governed-review outcome states its status once, then its history oldest first" do
    states = [
      {"partial", "pending_approval",
       review(%{"approved_count" => 1, "decisions" => [approve("Jane Doe")]}),
       "◷ 1 of 2 reviews received.", ["✓ Review granted by Jane Doe."]},
      {"granted", "success",
       review(%{
         "status" => "approved",
         "required_approvals" => 1,
         "approved_count" => 1,
         "decisions" => [approve("Jane Doe", "Read-only query; no configuration changes.")]
       }), "✓ Review granted by Jane Doe. Reason: Read-only query; no configuration changes.",
       []},
      {"granted-many", "success",
       review(%{
         "status" => "approved",
         "approved_count" => 2,
         "decisions" => [approve("Jane Doe"), approve("Sam Reviewer")]
       }), "✓ Review granted; 2 of 2 reviews received.",
       ["✓ Review granted by Jane Doe.", "✓ Review granted by Sam Reviewer."]},
      {"denied", "denied",
       review(%{
         "status" => "denied",
         "approved_count" => 1,
         "decisions" => [approve("Jane Doe"), deny("Sam Reviewer", "Please narrow the query.")]
       }), "✕ Review denied by Sam Reviewer.",
       [
         "✓ Review granted by Jane Doe.",
         "✕ Review denied by Sam Reviewer. Reason: Please narrow the query."
       ]},
      {"expired", "cancelled",
       review(%{
         "status" => "expired",
         "approved_count" => 1,
         "decisions" => [approve("Jane Doe")]
       }), "◷ Review window expired. 1 of 2 reviews received.",
       ["✓ Review granted by Jane Doe."]},
      {"cancelled", "cancelled", review(%{"status" => "cancelled"}),
       "■ Review cancelled. 0 of 2 reviews received.", []},
      {"override", "success",
       review(%{
         "status" => "approved",
         "approved_count" => 1,
         "decisions" => [approve("Jane Doe")],
         "override" => %{
           "actor" => "Alex Admin",
           "reason" => "A second reviewer is unavailable.",
           "approved_count" => 1,
           "required_approvals" => 2,
           "waived_approvals" => 1,
           "decided_at" => "2026-09-11T08:07:23.488276Z"
         }
       }),
       "✓ Review granted by Alex Admin; 1 of 2 reviews received; remaining reviews were overridden.",
       [
         "✓ Review granted by Jane Doe.",
         "⚠ Review granted by Alex Admin · admin override. Reason: A second reviewer is unavailable."
       ]}
    ]

    for {name, run_status, review, summary, history} <- states do
      assert {:ok, rendered} =
               Renderer.render(%{
                 "emisar_approval_status" => approval_status(run_status, nil, review)
               })

      blocks = rendered["blocks"]
      expected = Enum.join([summary | if(history == [], do: [], else: [""] ++ history)], "\n")

      assert status_text(blocks) == "*Status*\n" <> expected, "#{name} status"
      assert rendered["text"] =~ summary

      # While a decision is open, reviewing it in Emisar is the card's accented
      # primary action; once decided, the same link opens the decided record.
      assert [%{"elements" => buttons}] = Enum.filter(blocks, &(&1["type"] == "actions"))
      open? = review["status"] == "pending"
      expected_label = if open?, do: "Review in Emisar", else: "Open in Emisar"

      assert hd(buttons)["text"]["text"] == expected_label, "#{name} control"
      assert Map.get(hd(buttons), "style") == if(open?, do: "primary"), "#{name} control style"
    end
  end

  test "a failed poll says the status could not be refreshed, never that it was denied" do
    assert {:ok, rendered} =
             Renderer.render(%{
               "emisar_approval_status" =>
                 approval_status("pending_approval", "The approval read failed.", nil)
             })

    status = status_text(rendered["blocks"])

    assert status == "*Status*\n⚠ Couldn't refresh review status. Check Emisar for the latest."
    refute status =~ "denied"
    refute status =~ "expired"

    malformed =
      put_in(approval_status("success", nil, nil), ["run_url"], "http://evil.example/run")

    assert Renderer.render(%{"emisar_approval_status" => malformed}) ==
             {:error, {:invalid_slack_render, :emisar_approval_status}}
  end

  test "renders an inert schedule offer with exact recurrence and operator confirmation" do
    assert {:ok, rendered} =
             Renderer.render(%{
               "message" => "I can check this every weekday morning.",
               "records" => [
                 %{
                   "kind" => "schedule_offer",
                   "payload" => %{
                     "authority" => "read_only",
                     "expires_at" => nil,
                     "recurrence" => %{
                       "kind" => "weekly",
                       "time" => "09:00:00",
                       "weekday" => "monday"
                     },
                     "repository" => nil,
                     "task" => "Inspect current service health and report material changes.",
                     "timezone" => "America/New_York",
                     "title" => "Weekly service health"
                   },
                   "ref" => "record:schedule_offer:abc123",
                   "status" => "open"
                 }
               ]
             })

    [_, summary, actions] = rendered["blocks"]
    assert summary["text"]["text"] =~ "Weekly service health"
    assert summary["text"]["text"] =~ "every monday at 09:00:00"
    assert summary["text"]["text"] =~ "America/New_York"
    assert summary["text"]["text"] =~ "only an offer"

    assert [%{"action_id" => "ryker_confirm_schedule"} = button] = actions["elements"]
    assert button["value"] == "record:schedule_offer:abc123"
    assert button["confirm"]["text"]["text"] =~ "current policy"
    refute inspect(rendered) =~ "event_matcher"
  end

  test "a post that has landed says so and links to it" do
    # The 2026-09-12 coverage measurement: a confirmed post card said the
    # delivery worker was "sending or reconciling this exact message" forever,
    # long after it had landed, because the card was built from the offer and
    # the offer cannot know where the message went.
    payload = %{
      "conversation_ref" => "slack:T123:C789",
      "destination_ref" => "slack-source:v1:T123:C789:thread:1787832888.000300",
      "instruction_ref" => "slack-source:v1:T123:C456:message:1787832000.000100",
      "message" => "The deployment is healthy.",
      "requested_by_actor_ref" => "slack:user:U123",
      "thread_ref" => "1787832888.000300",
      "transport" => "slack"
    }

    sent = %{
      "kind" => "slack_post_offer",
      "message_url" => "https://emisar.slack.com/archives/C789/p1787832888000300",
      "payload" => payload,
      "ref" => "record:slack_post_offer:sent1",
      "status" => "confirmed"
    }

    assert {:ok, rendered} = Renderer.render(%{"message" => "Posted.", "records" => [sent]})
    text = Jason.encode!(rendered)
    assert text =~ "Additional Slack post sent"
    assert text =~ "Open message"
    refute text =~ "sending or reconciling"

    unsent = Map.delete(sent, "message_url")
    assert {:ok, pending} = Renderer.render(%{"message" => "Posted.", "records" => [unsent]})
    assert Jason.encode!(pending) =~ "sending or reconciling"

    forged = Map.put(sent, "message_url", "http://evil.example/steal")

    assert Renderer.render(%{"message" => "Posted.", "records" => [forged]}) ==
             {:error, {:invalid_slack_render, :record}}
  end

  test "renders an additional Slack post as an exact requester-owned confirmation" do
    destination_ref = "slack-source:v1:T123:C789:thread:1787832888.000300"

    assert {:ok, rendered} =
             Renderer.render(%{
               "message" => "I prepared the requested post for confirmation.",
               "records" => [
                 %{
                   "kind" => "slack_post_offer",
                   "payload" => %{
                     "conversation_ref" => "slack:T123:C789",
                     "destination_ref" => destination_ref,
                     "instruction_ref" => "slack-source:v1:T123:C456:message:1787832000.000100",
                     "message" => "The deployment is healthy.",
                     "requested_by_actor_ref" => "slack:user:U123",
                     "thread_ref" => "1787832888.000300",
                     "transport" => "slack"
                   },
                   "ref" => "record:slack_post_offer:abc123",
                   "status" => "open"
                 }
               ]
             })

    rendered_text = inspect(rendered)
    assert rendered_text =~ destination_ref
    assert rendered_text =~ "The deployment is healthy."
    assert rendered_text =~ "No message has been posted"

    assert [button] =
             rendered["blocks"]
             |> Enum.find(&(&1["type"] == "actions"))
             |> Map.fetch!("elements")

    assert button["action_id"] == "ryker_confirm_slack_post"
    assert button["value"] == "record:slack_post_offer:abc123"
    assert button["confirm"]["text"]["text"] =~ destination_ref
  end

  test "renders a complete automation before and after with one host-owned confirmation" do
    before = %{
      "automation_id" => "schedule:daily-health",
      "context_channel" => "slack:T123:C456",
      "delivery_channel" => "slack:T123:C456",
      "expires_at" => nil,
      "next_occurrence_at" => "2026-08-30T13:00:00.000000Z",
      "prompt" => "Inspect current service health.",
      "repository" => nil,
      "revision" => 1,
      "status" => "active",
      "title" => "Daily service health",
      "trigger" => %{
        "recurrence" => "daily",
        "time" => "13:00:00",
        "timezone" => "Etc/UTC",
        "type" => "time"
      }
    }

    assert {:ok, rendered} =
             Renderer.render(%{
               "message" => "I can pause that schedule.",
               "records" => [
                 %{
                   "kind" => "automation_change_offer",
                   "payload" => %{
                     "action" => "pause",
                     "after" => before |> Map.put("revision", 2) |> Map.put("status", "paused"),
                     "automation_id" => before["automation_id"],
                     "automation_kind" => "time",
                     "before" => before,
                     "patch" => %{},
                     "revision" => 1
                   },
                   "ref" => "record:automation_change_offer:pause",
                   "status" => "open"
                 }
               ]
             })

    text = Enum.map_join(rendered["blocks"], "\n", &inspect/1)
    assert text =~ "Before"
    assert text =~ "After"
    assert text =~ "Daily service health"
    assert text =~ "Inspect current service health."
    assert text =~ "paused"

    assert [%{"action_id" => "ryker_confirm_automation"} = button] =
             rendered["blocks"]
             |> Enum.filter(&(&1["type"] == "actions"))
             |> List.last()
             |> Map.fetch!("elements")

    assert button["value"] == "record:automation_change_offer:pause"
    assert button["style"] == "danger"
  end

  test "renders a complete maximum-sized automation update for operator review" do
    before = %{
      "automation_id" => "schedule:large-health-review",
      "context_channel" => "slack:T123:C456",
      "delivery_channel" => "slack:T123:C456",
      "expires_at" => nil,
      "next_occurrence_at" => "2026-08-30T13:00:00.000000Z",
      "prompt" => String.duplicate("a", 12_000),
      "repository" => nil,
      "revision" => 1,
      "status" => "active",
      "title" => "Large daily health review",
      "trigger" => %{
        "recurrence" => "daily",
        "time" => "13:00:00",
        "timezone" => "Etc/UTC",
        "type" => "time"
      }
    }

    after_document =
      before
      |> Map.put("prompt", String.duplicate("b", 12_000))
      |> Map.put("revision", 2)

    assert {:ok, rendered} =
             Renderer.render(%{
               "message" => "Review this full prompt replacement.",
               "records" => [
                 %{
                   "kind" => "automation_change_offer",
                   "payload" => %{
                     "action" => "update",
                     "after" => after_document,
                     "automation_id" => before["automation_id"],
                     "automation_kind" => "time",
                     "before" => before,
                     "patch" => %{"prompt" => after_document["prompt"]},
                     "revision" => 1
                   },
                   "ref" => "record:automation_change_offer:large",
                   "status" => "open"
                 }
               ]
             })

    rendered_text =
      Enum.map_join(rendered["blocks"], "", fn
        %{"text" => %{"text" => text}} -> text
        %{"text" => text} when is_binary(text) -> text
        _block -> ""
      end)

    assert rendered_text =~ before["prompt"]
    assert rendered_text =~ after_document["prompt"]
    assert length(rendered["blocks"]) <= 50
  end

  test "renders behavior offers as explicit operator-owned confirmations" do
    records = [
      %{
        "kind" => "preference_offer",
        "payload" => %{
          "expires_in" => "90d",
          "key" => "response_detail",
          "repository" => nil,
          "scope" => "operator",
          "value" => "concise"
        },
        "ref" => "record:preference_offer:abc123",
        "status" => "open"
      },
      %{
        "kind" => "guidance_offer",
        "payload" => %{
          "expires_in" => "30d",
          "repository" => nil,
          "scope" => "conversation",
          "subject" => "terraform-review",
          "summary" => "Lead with availability risk.",
          "text" => "Explain availability and drift before resource counts.",
          "visibility" => "conversation"
        },
        "ref" => "record:guidance_offer:def456",
        "status" => "open"
      },
      %{
        "kind" => "standing_assignment_offer",
        "payload" => %{
          "action" => "review_terraform_plan",
          "expires_in" => "30d",
          "repository" => "ryker-infra",
          "source_filter" => "app",
          "task" => "Review every exact Terraform plan posted here.",
          "trigger" => "terraform_plan"
        },
        "ref" => "record:standing_assignment_offer:ghi789",
        "status" => "open"
      },
      %{
        "kind" => "standing_assignment_offer",
        "payload" => %{
          "context_channel" => "slack:T123:C456",
          "delivery_channel" => "slack:T123:C456",
          "expires_at" => nil,
          "filter" => %{"action" => "submitted"},
          "hold" => nil,
          "repository" => "ryker",
          "source_kind" => "github",
          "task" => "Review every submitted pull request review.",
          "title" => "Review pull request reviews"
        },
        "ref" => "record:standing_assignment_offer:jkl012",
        "status" => "open"
      }
    ]

    assert {:ok, rendered} =
             Renderer.render(%{"message" => "I can remember these bounds.", "records" => records})

    assert inspect(rendered) =~ "behavior has not changed"
    assert inspect(rendered) =~ "Advisory only"
    assert inspect(rendered) =~ "Read-only initiative"
    rendered_text = Enum.map_join(rendered["blocks"], "\n", &inspect/1)
    assert rendered_text =~ "Source event: `github`"
    assert rendered_text =~ "Review pull request reviews"

    assert rendered["blocks"]
           |> Enum.filter(&(&1["type"] == "actions"))
           |> Enum.flat_map(& &1["elements"])
           |> Enum.map(& &1["action_id"]) ==
             List.duplicate("ryker_confirm_behavior", 4)
  end

  test "renders operational memory as an explicit scoped stale-hint confirmation" do
    assert {:ok, rendered} =
             Renderer.render(%{
               "message" => "I can remember that mapping after confirmation.",
               "records" => [
                 %{
                   "kind" => "memory_offer",
                   "payload" => %{
                     "expires_in" => "90d",
                     "kind" => "repository_binding",
                     "repository" => nil,
                     "scope" => "conversation",
                     "subject" => "primary_repository",
                     "value" => "ryker",
                     "visibility" => "conversation"
                   },
                   "ref" => "record:memory_offer:abc123",
                   "status" => "open"
                 }
               ]
             })

    assert inspect(rendered) =~ "Potentially stale hint only"
    assert inspect(rendered) =~ "live evidence"

    assert [button] =
             rendered["blocks"]
             |> Enum.find(&(&1["type"] == "actions"))
             |> Map.fetch!("elements")

    assert button["action_id"] == "ryker_confirm_memory"
    assert button["value"] == "record:memory_offer:abc123"
  end

  test "renders only an exact publishable review as an operator publication control" do
    review = %{
      "candidate_tree" => String.duplicate("7", 40),
      "draft_authorized" => false,
      "gate" => "passed",
      "patch_bytes" => 4_096,
      "patch_digest" => String.duplicate("8", 64),
      "policy_findings" => [],
      "publishable" => true,
      "reasons" => [],
      "rebase" => "clean",
      "repository" => "ryker",
      "title" => "Fix retry reconciliation"
    }

    assert {:ok, rendered} =
             Renderer.render(%{
               "message" => "The exact committed candidate passed review.",
               "records" => [
                 %{
                   "kind" => "publication_review",
                   "payload" => review,
                   "ref" => "publication:abc123",
                   "status" => "open"
                 }
               ]
             })

    [_, summary, actions] = rendered["blocks"]
    assert summary["text"]["text"] =~ "Gate: `passed`"
    assert summary["text"]["text"] =~ "Candidate tree: `#{String.duplicate("7", 40)}`"
    assert [%{"action_id" => "ryker_publish_draft"} = button] = actions["elements"]
    assert button["value"] == "publication:abc123"

    blocked = %{review | "gate" => "failed", "publishable" => false, "reasons" => ["gate_failed"]}

    assert {:ok, blocked_rendered} =
             Renderer.render(%{
               "message" => "The review did not pass.",
               "records" => [
                 %{
                   "kind" => "publication_review",
                   "payload" => blocked,
                   "ref" => "publication:def456",
                   "status" => "open"
                 }
               ]
             })

    refute inspect(blocked_rendered) =~ "ryker_publish_draft"
    assert inspect(blocked_rendered) =~ "gate_failed"
  end

  # Every confirmed coding task ended on a button that could not change the
  # candidate, the repository or the scope. Once the host already holds the
  # confirming person's grant, the review card has to say what is happening;
  # rendering the click anyway is how "authorized" and "awaiting you" became
  # the same card.
  test "an authorized draft states what it is doing instead of asking for a click" do
    review = %{
      "candidate_tree" => String.duplicate("7", 40),
      "draft_authorized" => true,
      "gate" => "passed",
      "patch_bytes" => 4_096,
      "patch_digest" => String.duplicate("8", 64),
      "policy_findings" => [],
      "publishable" => true,
      "reasons" => [],
      "rebase" => "clean",
      "repository" => "ryker",
      "title" => "Fix retry reconciliation"
    }

    assert {:ok, rendered} =
             Renderer.render(%{
               "message" => "The exact committed candidate passed review.",
               "records" => [
                 %{
                   "kind" => "publication_review",
                   "payload" => review,
                   "ref" => "publication:abc123",
                   "status" => "open"
                 }
               ]
             })

    refute Enum.any?(rendered["blocks"], &(&1["type"] == "actions")),
           "an already-granted draft must not render a publication click"

    refute inspect(rendered) =~ "ryker_publish_draft"
    assert inspect(rendered) =~ "opening the draft pull request"
  end

  # Andrew's 2026-09-09 hosted-runner recovery: the gate could not start, so the
  # card could only say "blocked" and offer nothing. A draft a person can read is
  # a different question from a change that is ready to merge, and the
  # confirmation has to name the repository and the check that never ran.
  test "an unverified draft offer names its repository and its missing check" do
    task =
      publication_task_card(%{
        "branch" => "refs/heads/ryker/card",
        "controls" => ["publish", "update", "discard"],
        "publication_ref" => "publication:def456",
        "pull_request_number" => nil,
        "pull_request_url" => nil,
        "recovery_generation" => 3,
        "status" => "blocked",
        "unverified" => "docker: command not found"
      })

    assert {:ok, rendered} = Renderer.render(%{"task_card" => task})
    encoded = Jason.encode!(rendered)

    assert encoded =~ "docker: command not found"
    refute encoded =~ "PR creation is blocked"

    assert [publish | _rest] =
             rendered["blocks"]
             |> Enum.flat_map(&Map.get(&1, "elements", []))
             |> Enum.filter(&(&1["action_id"] == "ryker_task_publish"))

    assert publish["text"]["text"] == "Create draft PR"
    confirmation = publish["confirm"]["text"]["text"]
    assert confirmation =~ "ryker"
    assert confirmation =~ "docker: command not found"
    assert confirmation =~ "does not waive them"
    assert confirmation =~ "does not merge or deploy"

    # Nothing here says the gate passed, and the older wording that treated a
    # publishable candidate and an unverified snapshot as one thing is gone.
    refute encoded =~ "Readiness review complete"

    unshareable = put_in(task, ["publication", "unverified"], nil)
    unshareable = put_in(unshareable, ["publication", "controls"], ["update", "discard"])

    assert {:ok, blocked_rendered} = Renderer.render(%{"task_card" => unshareable})
    blocked_encoded = Jason.encode!(blocked_rendered)
    assert blocked_encoded =~ "PR creation is blocked"
    refute blocked_encoded =~ "ryker_task_publish"
  end

  # The superseded routine handoff told an operator to create a draft PR after
  # every readiness review, including the ones Ryker was already authorized
  # to open. The sentence itself is the regression.
  test "a reviewed candidate explains the missing grant rather than handing work back" do
    task =
      publication_task_card(%{
        "branch" => "refs/heads/ryker/card",
        "controls" => ["publish", "update", "discard"],
        "publication_ref" => "publication:def456",
        "pull_request_number" => nil,
        "pull_request_url" => nil,
        "recovery_generation" => 1,
        "status" => "reviewed",
        "unverified" => nil
      })

    assert {:ok, rendered} = Renderer.render(%{"task_card" => task})
    encoded = Jason.encode!(rendered)

    refute encoded =~ "Readiness review complete. Create a draft PR when you are ready."
    assert encoded =~ "don't have a draft-PR grant"

    assert [publish | _rest] =
             rendered["blocks"]
             |> Enum.flat_map(&Map.get(&1, "elements", []))
             |> Enum.filter(&(&1["action_id"] == "ryker_task_publish"))

    assert publish["confirm"]["text"]["text"] =~ "ryker"
    refute publish["confirm"]["text"]["text"] =~ "waive"

    # An authorized task is already publishing, so its card offers nothing to
    # click and never re-poses the question.
    publishing =
      publication_task_card(%{
        "branch" => "refs/heads/ryker/card",
        "controls" => [],
        "publication_ref" => "publication:def456",
        "pull_request_number" => nil,
        "pull_request_url" => nil,
        "recovery_generation" => 1,
        "status" => "publish_pending",
        "unverified" => nil
      })

    assert {:ok, publishing_rendered} = Renderer.render(%{"task_card" => publishing})
    publishing_encoded = Jason.encode!(publishing_rendered)
    assert publishing_encoded =~ "Creating the draft PR"
    refute publishing_encoded =~ "ryker_task_publish"
  end

  test "a published pull request has host-owned open and delivery-check controls" do
    url = "https://github.com/acme/ryker/pull/42"

    assert {:ok, rendered} =
             Renderer.render(%{
               "message" => "The draft is published.",
               "records" => [
                 %{
                   "kind" => "publication_result",
                   "payload" => %{
                     "branch_ref" => "refs/heads/ryker/fix-42",
                     "commit_sha" => String.duplicate("a", 40),
                     "pull_request_number" => 42,
                     "pull_request_url" => url,
                     "repository" => "ryker",
                     "title" => "Fix lifecycle tracking"
                   },
                   "ref" => "publication:published42",
                   "status" => "confirmed"
                 }
               ]
             })

    [_, summary, actions] = rendered["blocks"]
    assert summary["text"]["text"] =~ "Draft pull request published"

    assert [open, check] = actions["elements"]
    assert open["action_id"] == "ryker_open_publication"
    assert open["url"] == url
    assert open["value"] == "publication:published42"
    assert check["action_id"] == "ryker_check_publication"
    assert check["value"] == "publication:published42"
  end

  # The host knows whether remember_answer succeeded; the model was writing
  # "Remembered X" in prose, which a reader cannot check and the prompt has to
  # police. The answered question carries the receipt instead.
  test "an answered question shows what the host actually remembered" do
    question = %{
      "kind" => "input_request",
      "payload" => %{"choices" => [], "question" => "Which GCP project hosts this workload?"},
      "ref" => "record:input_request:abc123",
      "status" => "answered"
    }

    assert {:ok, without} = Renderer.render(%{"message" => "Thanks.", "records" => [question]})
    refute inspect(without) =~ "Remembered"

    remembered =
      Map.put(question, "presentation", %{
        "memory" => %{
          "applicability" => "the checkout workload in production",
          "subject" => "GCP project for checkout",
          "value" => "emisar-project-qa"
        }
      })

    assert {:ok, with_memory} =
             Renderer.render(%{"message" => "Thanks.", "records" => [remembered]})

    text = inspect(with_memory)
    assert text =~ "Remembered"
    assert text =~ "emisar-project-qa"
    assert text =~ "GCP project for checkout"
    assert text =~ "the checkout workload in production"

    # It is a receipt, not a control: nothing here grants or asks for anything.
    refute Enum.any?(with_memory["blocks"], &(&1["type"] == "actions"))
  end

  test "renders durable questions and event waits without accepting model-authored controls" do
    assert {:ok, rendered} =
             Renderer.render(%{
               "message" => "I need one decision before I continue.",
               "records" => [
                 %{
                   "kind" => "input_request",
                   "payload" => %{
                     "choices" => ["Roll out to 1%", "Stop the rollout"],
                     "question" => "Which rollout action should I take?"
                   },
                   "ref" => "record:input_request:abc123",
                   "status" => "open"
                 },
                 %{
                   "kind" => "event_wait",
                   "payload" => %{
                     "deadline_at" => "2026-08-29T12:00:00.000000Z",
                     "event_matcher" => %{"deployment" => "ryker"},
                     "kind" => "deployment_health",
                     "verification" => "Verify the new allocation is healthy."
                   },
                   "ref" => "record:event_wait:def456",
                   "status" => "open"
                 }
               ]
             })

    [_, question, choices, wait] = rendered["blocks"]
    assert question["text"]["text"] == "Which rollout action should I take?"

    assert Enum.map(choices["elements"], &{&1["action_id"], &1["value"]}) == [
             {"ryker_answer_input_0", "record:input_request:abc123|0"},
             {"ryker_answer_input_1", "record:input_request:abc123|1"}
           ]

    refute inspect(wait) =~ "Verify the new allocation is healthy."
    assert inspect(wait) =~ "Monitoring deadline <!date^"
    assert inspect(wait) =~ "2026-08-29 12:00 UTC"
    refute inspect(rendered) =~ ~s("deployment" => "ryker")
  end

  test "a timed wait names the host's next check only while it is before the deadline" do
    wait = %{
      "kind" => "event_wait",
      "payload" => %{
        "deadline_at" => "2026-08-29T12:00:00.000000Z",
        "event_matcher" => %{
          "delay" => "30m",
          "on_timeout" => "Report the rollout state.",
          "type" => "after"
        },
        "kind" => "deployment_health",
        "verification" => "Verify the new allocation is healthy."
      },
      "presentation" => %{"next_check_at" => "2026-08-28T12:30:00.000000Z"},
      "ref" => "record:event_wait:timer",
      "status" => "open"
    }

    next_check = DateTime.to_unix(~U[2026-08-28 12:30:00Z])
    deadline = DateTime.to_unix(~U[2026-08-29 12:00:00Z])

    assert {:ok, rendered} = Renderer.render(%{"message" => "Watching.", "records" => [wait]})

    assert [_message, %{"type" => "context", "elements" => [%{"text" => text}]}] =
             rendered["blocks"]

    assert text ==
             "Next check <!date^#{next_check}^{date_short_pretty} at {time}|2026-08-28 12:30 UTC>" <>
               " · Monitoring deadline <!date^#{deadline}^{date_short_pretty} at {time}|2026-08-29 12:00 UTC>"

    late = put_in(wait, ["presentation", "next_check_at"], "2026-08-30T00:00:00.000000Z")
    assert {:ok, rendered} = Renderer.render(%{"message" => "Watching.", "records" => [late]})

    assert [_message, %{"elements" => [%{"text" => "Monitoring deadline " <> _}]}] =
             rendered["blocks"]

    assert {:ok, rendered} =
             Renderer.render(%{
               "message" => "Done.",
               "records" => [%{wait | "status" => "answered"}]
             })

    assert [_message] = rendered["blocks"]

    for invalid <- ["tomorrow", "2026-08-28T14:30:00+02:00"] do
      forged = put_in(wait, ["presentation", "next_check_at"], invalid)

      assert Renderer.render(%{"message" => "Watching.", "records" => [forged]}) ==
               {:error, {:invalid_slack_render, :record}}
    end
  end

  test "long answers remain readable and many choices require explicit submission" do
    # Proposed stress copy from question__many-long-options in the native catalog;
    # these are UI examples, not harvested answers or a saved retention policy.
    choices = [
      "Delete each report after six hours. This gives us a short window to investigate an incident while it is happening, but the reports will not be available for a review the next day.",
      "Delete each report after twelve hours. This leaves time for another shift to pick up the investigation, while keeping sensitive diagnostics for less than a full day.",
      "Delete each report after twenty-four hours. This lets someone investigate an overnight failure the following morning, but they will need to review it before that window closes.",
      "Delete each report after three days. This gives the team time to investigate after a short absence or weekend, without keeping a full week of sensitive diagnostic data.",
      "Delete each report after seven days. This gives us a week to compare recurring failures and review reports together, at the cost of keeping sensitive diagnostic data for longer.",
      "Delete each report after fourteen days. This gives us more time to investigate intermittent failures and compare two weeks of reports, but requires a longer retention window for sensitive data.",
      "Delete each report after thirty days. This provides the longest window for investigating rare failures, but keeps sensitive diagnostics for a month and can use more of the available storage."
    ]

    record = %{
      "kind" => "input_request",
      "ref" => "record:input_request:retention",
      "status" => "open",
      "payload" => %{"question" => "How long should diagnostics be kept?", "choices" => choices}
    }

    assert {:ok, rendered} =
             Renderer.render(%{
               "message" => "Reports remain private and size bounded.",
               "records" => [record]
             })

    sections =
      for %{"type" => "section", "text" => %{"text" => text}} <- rendered["blocks"], do: text

    Enum.each(choices, fn choice -> assert Enum.any?(sections, &String.contains?(&1, choice)) end)
    elements = Enum.flat_map(rendered["blocks"], &Map.get(&1, "elements", []))
    assert [radio] = Enum.filter(elements, &(&1["type"] == "radio_buttons"))
    assert length(radio["options"]) == 7
    refute Map.has_key?(radio, "initial_option")
    assert Enum.map(radio["options"], & &1["value"]) == Enum.map(0..6, &"#{record["ref"]}|#{&1}")

    assert Enum.any?(
             elements,
             &(&1["action_id"] == "ryker_submit_input" and
                 &1["text"]["text"] == "Submit answer")
           )

    short_set = put_in(record, ["payload", "choices"], Enum.take(choices, 3))
    assert {:ok, short} = Renderer.render(%{"message" => "Choose one.", "records" => [short_set]})

    buttons =
      short["blocks"]
      |> Enum.flat_map(&Map.get(&1, "elements", []))
      |> Enum.filter(&(&1["type"] == "button"))

    assert Enum.map(buttons, & &1["text"]["text"]) == ["Option 1", "Option 2", "Option 3"]
    assert length(Enum.uniq_by(buttons, & &1["action_id"])) == 3

    assert {:ok, answered} =
             Renderer.render(%{
               "message" => "Choose one.",
               "records" => [%{record | "status" => "answered"}]
             })

    assert inspect(answered["blocks"]) =~ record["payload"]["question"]
    refute Enum.any?(answered["blocks"], &(&1["type"] == "actions"))
    refute inspect(answered["blocks"]) =~ "ryker_question_choice"
  end

  test "a reusable question explains the saved fact and applicability before the answer" do
    assert {:ok, rendered} =
             Renderer.render(%{
               "message" => "The plan updates the portal template, fleet and monitors.",
               "records" => [
                 %{
                   "kind" => "input_request",
                   "ref" => "record:input_request:project",
                   "status" => "open",
                   "payload" => %{
                     "question" =>
                       "Which GCP project should I use for the health and backup checks?",
                     "choices" => [],
                     "remember" => %{
                       "subject" => "GCP project",
                       "applicability" => "Production portal"
                     }
                   }
                 }
               ]
             })

    assert inspect(rendered["blocks"]) =~
             "I'll remember an operator's answer across conversations"

    assert inspect(rendered["blocks"]) =~ "GCP project"
    assert inspect(rendered["blocks"]) =~ "Production portal"
    refute inspect(rendered["blocks"]) =~ "already remembered"
  end

  test "event-only watches do not append internal instructions or an empty deadline" do
    # The original Terraform reply exposed its full monitoring prompt and UUIDs.
    assert {:ok, rendered} =
             Renderer.render(%{
               "message" => "The plan is ready. I’ll report the apply outcome.",
               "records" => [
                 %{
                   "kind" => "event_wait",
                   "ref" => "record:event_wait:quiet",
                   "status" => "open",
                   "payload" => %{
                     "deadline_at" => nil,
                     "kind" => "source_event",
                     "event_matcher" => %{
                       "type" => "source_event",
                       "source_kind" => "slack",
                       "match" => %{"run_id" => "run-k9CpPp3nWjQrkCMG"},
                       "poll_after" => nil,
                       "on_timeout" => nil
                     },
                     "verification" => "Internal exact-run verification instructions."
                   }
                 }
               ]
             })

    assert length(rendered["blocks"]) == 1
    refute inspect(rendered) =~ "Waiting until"
    refute inspect(rendered) =~ "Internal exact-run"
  end

  test "refuses malformed or unsupported presentation records" do
    assert Renderer.render(%{"message" => "Done.", "records" => "records"}) ==
             {:error, {:invalid_slack_render, :records}}

    assert Renderer.render(%{
             "message" => "Done.",
             "records" => [%{"kind" => "unknown", "payload" => %{}, "ref" => "record:1"}]
           }) == {:error, {:invalid_slack_render, :record}}
  end

  test "renders a plain host message without requiring presentation records" do
    assert {:ok, rendered} = Renderer.render(%{"message" => "A plain reply."})
    assert rendered["text"] == "A plain reply."
    assert [%{"type" => "markdown"}] = rendered["blocks"]
  end

  test "renders model prose as standard Markdown without granting Slack control syntax" do
    message = """
    # Result

    [Read the evidence](https://example.com/evidence?a=1&b=2).

    | Check | State |
    | --- | --- |
    | API | healthy |

    ```elixir
    assert current < target
    ```

    <!channel> <@U123>
    """

    assert {:ok, rendered} = Renderer.render(%{"message" => message})
    assert [%{"type" => "markdown", "text" => markdown}] = rendered["blocks"]
    assert markdown =~ "# Result"
    assert markdown =~ "[Read the evidence](https://example.com/evidence?a=1&amp;b=2)"
    assert markdown =~ "| Check | State |"
    assert markdown =~ "```elixir"
    assert markdown =~ "assert current &lt; target"
    assert markdown =~ "&lt;!channel&gt; &lt;@U123&gt;"
    refute markdown =~ "<!channel>"
    refute markdown =~ "<@U123>"
  end

  test "preserves prose above Slack's cumulative Markdown limit as inert plain text" do
    message = "# Result\n\n" <> String.duplicate("evidence ", 1_500)

    assert String.length(message) > 12_000
    assert {:ok, rendered} = Renderer.render(%{"message" => message})
    assert Enum.all?(rendered["blocks"], &(&1["type"] == "section"))

    assert Enum.map_join(rendered["blocks"], "", &get_in(&1, ["text", "text"])) == message
  end

  test "investigation records remain audit-only without hiding the self-contained reply" do
    records = [
      record("evidence", %{
        "claim_id" => "api.health",
        "observation" => "The <API> probe is ready.",
        "relation" => nil,
        "source_name" => "production & probe",
        "source_type" => "monitoring"
      }),
      record("coverage", %{
        "claim_ids" => ["api.health"],
        "detail" => "The public path was sampled.",
        "layer" => "application",
        "observed_at" => "2026-08-28T12:00:00.000000Z",
        "source" => "production probe",
        "status" => "healthy"
      }),
      record("finding", %{
        "status" => "unexplained",
        "what" => "Worker health is not yet known."
      }),
      record("progress", %{
        "phase" => "verifying",
        "summary" => "The API is healthy; workers remain."
      }),
      record("goal", %{
        "authority" => "read_only",
        "completion_contract" => "A current worker observation exists.",
        "id" => "check-workers",
        "kind" => "check",
        "parent_goal_id" => "verify-service",
        "prerequisite_goal_ids" => ["check-api"],
        "read_only_repositories" => ["runbooks"],
        "requested_outcome" => "Check worker health",
        "required" => true,
        "stage" => "self_review"
      }),
      record("goal_state", %{
        "goal_id" => "check-workers",
        "state" => "working"
      }),
      record("alert_assessment", %{
        "impact" => "API traffic is healthy; workers are not yet verified.",
        "immediate_action" => "Inspect a current worker signal.",
        "verdict" => "unverified"
      })
    ]

    assert {:ok, rendered} =
             Renderer.render(%{"message" => "Current investigation state.", "records" => records})

    assert length(rendered["blocks"]) == 1
    refute inspect(rendered) =~ "Sources"
    refute inspect(rendered) =~ "source link unavailable"
    refute inspect(rendered) =~ "action_id"
    assert rendered["text"] == "Current investigation state."
  end

  test "renders every durable setup state without inventing configuration authority" do
    session_ref = Ecto.UUID.generate()
    base = setup_document(session_ref)

    documents = [
      base,
      base
      |> put_in(["channel_setup", "step"], "environment")
      |> put_in(
        ["channel_setup", "draft", "environment_options"],
        Enum.map(
          1..7,
          &%{
            "emisar" => false,
            "name" => "Environment #{&1}",
            "ref" => "environment-#{&1}",
            "repositories" => []
          }
        )
      ),
      put_in(base, ["channel_setup", "step"], "alerts"),
      put_in(base, ["channel_setup", "step"], "audience"),
      base
      |> put_in(["channel_setup", "status"], "confirming")
      |> put_in(["channel_setup", "step"], "confirm")
      |> put_in(["channel_setup", "draft", "participation"], "proactive")
      |> put_in(["channel_setup", "draft", "environment_ref"], "production")
      |> put_in(["channel_setup", "draft", "alert_policy"], "offer")
      |> put_in(["channel_setup", "draft", "invite_user_refs"], ["U123"]),
      base
      |> put_in(["channel_setup", "status"], "saved")
      |> put_in(["channel_setup", "draft", "participation"], "mentions")
      |> put_in(["channel_setup", "draft", "environment_ref"], "production")
      |> put_in(["channel_setup", "draft", "alert_policy"], "reply"),
      put_in(base, ["channel_setup", "status"], "cancelled"),
      put_in(base, ["channel_setup", "status"], "expired")
    ]

    Enum.each(documents, fn document ->
      assert {:ok, %{"blocks" => blocks, "text" => text}} = Renderer.render(document)
      assert blocks != []
      assert is_binary(text) and text != ""
    end)

    # Seven environments and No environment wrap into rows of five buttons.
    environments = Enum.at(documents, 1)
    assert {:ok, rendered} = Renderer.render(environments)
    assert length(Enum.filter(rendered["blocks"], &(&1["type"] == "actions"))) == 2
  end

  # Since 2026-09-12 the Workspace setup row quotes the worker's own refusal when
  # work never started, so a stage detail is the first part of the ledger that is
  # not host-authored end to end. The escape that keeps it inert is what stands
  # between a provider's sentence and a channel-wide mention.
  test "a stage detail quoting the worker's own words reaches Slack inert" do
    stages =
      Enum.map(task_stages(), fn
        %{"stage" => "workspace_setup"} = stage ->
          %{
            stage
            | "detail" =>
                "work never started · The worker rejected the operation: <!everyone> & <https://example.invalid|urgent>",
              "state" => "failed"
          }

        stage ->
          stage
      end)

    task = %{task_document("action_required") | "stages" => stages}

    assert {:ok, rendered} = Renderer.render(%{"task_card" => task})
    json = Jason.encode!(rendered)

    assert json =~
             "Workspace setup · work never started · The worker rejected the operation: &lt;!everyone&gt; &amp; &lt;https://example.invalid|urgent&gt;"

    refute json =~ "<!everyone>"

    # The row is bounded before it is escaped, and a detail over the bound is
    # not a card the host will send.
    over_bound =
      put_in(task, ["stages"], [
        %{Enum.at(stages, 0) | "detail" => String.duplicate("a", 201)} | Enum.drop(stages, 1)
      ])

    assert Renderer.render(%{"task_card" => over_bound}) ==
             {:error, {:invalid_slack_render, :task_card}}
  end

  # Every card escaped its model-authored values in the blocks, but the task,
  # incident, saved-entity and governed-review cards built their notification
  # line from the same title, summary, question and reviewer text raw. That line
  # is what Slack reads for the push notification, so a `<!channel>` a worker
  # wrote into a title was one post away from paging the whole channel.
  test "a card's notification text never turns its values into Slack markup" do
    forged = "<!channel> & <https://example.invalid|urgent>"
    inert = "&lt;!channel&gt; &amp; &lt;https://example.invalid|urgent&gt;"

    task = %{
      task_document("action_required")
      | "action_needed" => forged,
        "summary" => forged,
        "title" => forged
    }

    room = %{
      incident_document("waiting_for_input")
      | "action_needed" => forged,
        "summary" => forged,
        "title" => forged
    }

    entity = %{paused_rule() | "instructions" => forged, "notice" => forged, "title" => forged}

    review =
      approval_status(
        "success",
        nil,
        review(%{
          "status" => "approved",
          "required_approvals" => 1,
          "approved_count" => 1,
          "decisions" => [approve("<!here>")]
        })
      )

    settings =
      put_in(settings_document(), ["environment"], %{
        "emisar" => false,
        "name" => "<!here>",
        "ready" => true,
        "ref" => "production",
        "repositories" => [
          %{"ref" => "<!here>", "url" => "https://github.com/acme/backend"}
        ]
      })

    documents = [
      %{"task_card" => task},
      %{"incident_room" => room},
      %{"saved_entity" => entity},
      %{"emisar_approval_status" => review},
      %{
        "channel_settings" => %{
          "audience" => "thread",
          "bot_user_ref" => "UBOT",
          "configuration_ref" => nil,
          "revision" => nil,
          "settings" => %{settings | "configuration_ref" => nil, "revision" => nil}
        }
      }
    ]

    for document <- documents do
      assert {:ok, %{"text" => text}} = Renderer.render(document)
      refute text =~ "<!", "#{inspect(Map.keys(document))} notification: #{text}"
      refute text =~ "<https://", "#{inspect(Map.keys(document))} notification: #{text}"
    end

    for document <- Enum.take(documents, 3) do
      assert {:ok, %{"text" => text}} = Renderer.render(document)
      assert text =~ inert
    end
  end

  test "renders every task and incident lifecycle label from host-owned state" do
    task_statuses =
      ~w(waiting_for_input waiting_for_event action_required stopping reviewing ready_to_publish completed cancelled)

    labels = %{
      "action_required" => "Action required",
      "cancelled" => "Closed",
      "completed" => "Completed",
      "ready_to_publish" => "Reviewed and ready for operator publication",
      "reviewing" => "Checking the change before it is published",
      "stopping" => "Stopping current work",
      "waiting_for_event" => "Waiting for verification",
      "waiting_for_input" => "Waiting for input"
    }

    Enum.each(task_statuses, fn status ->
      task = task_document(status)
      assert {:ok, rendered} = Renderer.render(%{"task_card" => task})
      assert String.starts_with?(rendered["text"], "#{task["title"]}: #{labels[status]}.")
      refute Enum.any?(rendered["blocks"], &(&1["type"] == "actions"))
    end)

    readiness =
      task_document("reviewing")
      |> put_in(["publication"], %{
        "branch" => "refs/heads/ryker/card",
        "controls" => [],
        "publication_ref" => "publication:review123",
        "pull_request_number" => nil,
        "pull_request_url" => nil,
        "recovery_generation" => nil,
        "status" => "review_pending",
        "unverified" => nil
      })

    assert {:ok, rendered} = Renderer.render(%{"task_card" => readiness})
    refute inspect(rendered) =~ "ryker_task_readiness"

    incident_statuses =
      ~w(provisioning action_required waiting_for_input waiting_for_event stopping resolved cancelled paused)

    Enum.each(incident_statuses, fn status ->
      room = incident_document(status)
      result = Renderer.render(%{"incident_room" => room})
      assert match?({:ok, _rendered}, result), inspect({status, result})
      {:ok, rendered} = result
      assert rendered["text"] =~ "Incident 82208f8f"
      assert inspect(rendered) =~ "Latest alert assessment"
      assert inspect(rendered) =~ "Action needed"
    end)
  end

  test "an incident room shows what the investigation has established" do
    # The 2026-09-12 coverage measurement: the incident card carried a prose
    # summary and nothing else, on the surface where "what do we actually
    # know by now" is the entire question a ryker brings to it.
    room = %{
      incident_document("investigating")
      | "goals" => [
          %{
            "detail" => "Checkout is the affected service.",
            "id" => "confirm-scope",
            "outcome" => "Confirm which service is affected",
            "state" => "completed"
          },
          %{
            "detail" => nil,
            "id" => "find-cause",
            "outcome" => "Name the cause",
            "state" => "working"
          },
          %{
            "detail" => "The rollback needs an owner who can approve it.",
            "id" => "restore",
            "outcome" => "Restore checkout",
            "state" => "blocked"
          },
          %{
            "detail" => nil,
            "id" => "verify",
            "outcome" => "Verify the recovery",
            "state" => "ready"
          },
          %{
            "detail" => nil,
            "id" => "wait",
            "outcome" => "Wait for the vendor",
            "state" => "waiting"
          },
          %{
            "detail" => nil,
            "id" => "drop",
            "outcome" => "Rule out the cache",
            "state" => "excluded"
          }
        ]
    }

    assert {:ok, rendered} = Renderer.render(%{"incident_room" => room})

    ledger =
      Enum.find(rendered["blocks"], fn block ->
        block["type"] == "section" and
          String.contains?(block["text"]["text"] || "", "What this investigation is establishing")
      end)

    assert ledger["text"]["text"] =~
             "✓ Confirm which service is affected · Checkout is the affected service."

    assert ledger["text"]["text"] =~ "▸ Name the cause\n"
    assert ledger["text"]["text"] =~ "! Restore checkout · The rollback needs an owner"
    assert ledger["text"]["text"] =~ "○ Verify the recovery"
    # One goal-state vocabulary across the cards: a goal waiting on someone else
    # and a goal ruled out do not both read as "not started yet".
    assert ledger["text"]["text"] =~ "◷ Wait for the vendor"
    assert ledger["text"]["text"] =~ "− Rule out the cache"

    assert {:ok, empty} =
             Renderer.render(%{"incident_room" => incident_document("investigating")})

    refute inspect(empty) =~ "What this investigation is establishing"
  end

  test "an incident room opens its evidence without a menu" do
    # The catalog's `incident-room/observed` names Open evidence as the card's
    # primary control. It was a row in the overflow: on the one card whose
    # subject is what was found, reading the findings took two taps and a guess.
    room = %{
      incident_document("investigating")
      | "controls" => ["stop", "close", "timeline", "evidence", "handoff"]
    }

    assert {:ok, rendered} = Renderer.render(%{"incident_room" => room})

    elements =
      rendered["blocks"] |> Enum.flat_map(&Map.get(&1, "elements", []))

    assert %{"type" => "button", "value" => value} =
             Enum.find(elements, &(&1["text"]["text"] == "Open evidence"))

    assert value == "incident-room:82208f8f-2ef4-4f1b-a011-626aabdc9342|evidence"

    overflow = Enum.find(elements, &(&1["type"] == "overflow"))
    labels = Enum.map(overflow["options"], & &1["text"]["text"])
    assert labels == ["Timeline", "Handoff summary"]

    # A task card reads its evidence from the menu, where a task's own work is
    # the headline and its records are the aside.
    card = %{task_document("working") | "controls" => ["stop", "timeline", "evidence", "handoff"]}

    assert {:ok, task} = Renderer.render(%{"task_card" => card})

    task_labels =
      task["blocks"]
      |> Enum.flat_map(&Map.get(&1, "elements", []))
      |> Enum.find(&(&1["type"] == "overflow"))
      |> Map.fetch!("options")
      |> Enum.map(& &1["text"]["text"])

    assert "Evidence" in task_labels
  end

  test "every control a card renders is one the host would accept back" do
    # `ryker_confirm_slack_post` shipped to production rendered but absent
    # from the interaction allowlist, so pressing it did nothing at all and
    # nothing said so (fixed in d315b9f3). A control the host refuses is worse
    # than no control: it asks for a press and then drops it.
    documents = [
      %{
        "incident_room" => %{
          incident_document("investigating")
          | "controls" => ["stop", "close", "timeline", "evidence", "handoff", "postmortem"]
        }
      },
      %{"saved_entity" => paused_rule()},
      %{
        "task_card" => %{
          task_document("working")
          | "controls" => ["stop", "close", "timeline", "evidence", "handoff"]
        }
      }
    ]

    pressable =
      Enum.flat_map(documents, fn document ->
        assert {:ok, rendered} = Renderer.render(document)

        rendered["blocks"]
        |> Enum.flat_map(&Map.get(&1, "elements", []))
        |> Enum.flat_map(&presses/1)
      end)

    assert length(pressable) >= 12

    for {action_id, value} <- pressable do
      envelope =
        put_in(
          interaction_envelope(),
          ["payload", "actions"],
          [%{"action_id" => action_id, "type" => "button", "value" => value}]
        )

      result = Interaction.from_socket(envelope, "T123", @now)

      assert match?({:ok, %{action_id: ^action_id, action_value: ^value}}, result),
             "the renderer emits #{action_id} with #{inspect(value)}, " <>
               "and the host answers #{inspect(result)}"
    end
  end

  # A saved entity's ref carries the durable id, and the interaction layer
  # requires that exact shape — a control built from anything looser is one the
  # host would ignore, which is what this test exists to notice.
  defp paused_rule do
    %{
      "facts" => [["Scope", "Whole workspace"]],
      "instructions" => "Watch the checkout dashboards every morning.",
      "kind" => "standing_rule",
      "notice" => "Standing rule paused",
      "ref" => "behavior:0b6b4c90-1f3a-4a2e-9a4a-0f0b3a6a8f21",
      "removable" => true,
      "resumable" => true,
      "revision" => 7,
      "saved_at" => "2026-08-28T12:00:00.000000Z",
      "saved_by" => "slack:user:U123",
      "status" => "paused",
      "title" => "Morning checkout watch"
    }
  end

  defp presses(%{"type" => "button", "action_id" => action_id, "value" => value}),
    do: [{action_id, value}]

  defp presses(%{"type" => "overflow", "action_id" => action_id, "options" => options}),
    do: Enum.map(options, &{action_id, &1["value"]})

  defp presses(_element), do: []

  defp interaction_envelope do
    %{
      "envelope_id" => "env-render",
      "payload" => %{
        "actions" => [],
        "container" => %{
          "channel_id" => "C456",
          "is_ephemeral" => false,
          "message_ts" => "1787832001.000200",
          "thread_ts" => "1787832000.000100",
          "type" => "message"
        },
        "team" => %{"id" => "T123"},
        "type" => "block_actions",
        "user" => %{"id" => "U123"}
      },
      "type" => "interactive"
    }
  end

  test "the settings notice names a person Slack will actually link" do
    # Caught by rendering the preview rather than by a test: the first version
    # passed "Settings changed by <@U123>" as free text, which the welcome
    # escapes against invented mentions, so the channel would have read a
    # literal <@U123>. Who changed it is a host fact, so it travels as one.
    settings = welcome_settings()

    document = %{
      "channel_welcome" => %{
        "bot_user_ref" => "UBOT",
        "configuration_ref" => "9a51fa43-977f-4b27-93f6-0c2ad3652ddc",
        "notice" => %{"actor_ref" => "U123", "at" => "2026-09-12T19:56:00.000000Z"},
        "revision" => 2,
        "settings" => settings
      }
    }

    assert {:ok, rendered} = Renderer.render(document)
    text = inspect(rendered)
    assert text =~ "Settings changed by <@U123> at 19:56 UTC"
    refute text =~ "&lt;@U123&gt;"
    # The fallback is read aloud, where a mention is noise.
    assert rendered["text"] =~ "Settings changed at 19:56 UTC."

    # Free text is still escaped, because anything else may not be host-written.
    forged = put_in(document, ["channel_welcome", "notice"], "Updated by <@U999>")
    assert {:ok, escaped} = Renderer.render(forged)
    assert inspect(escaped) =~ "&lt;@U999&gt;"

    for invalid <- [
          %{"actor_ref" => "U123"},
          %{"actor_ref" => "not-a-user", "at" => "2026-09-12T19:56:00.000000Z"},
          %{"actor_ref" => "U123", "at" => "yesterday"}
        ] do
      assert Renderer.render(put_in(document, ["channel_welcome", "notice"], invalid)) ==
               {:error, {:invalid_slack_render, :channel_welcome}}
    end
  end

  defp welcome_settings do
    %{
      "alert_policy" => "offer",
      "configuration_ref" => "9a51fa43-977f-4b27-93f6-0c2ad3652ddc",
      "customized_by" => nil,
      "environment" => %{
        "emisar" => false,
        "name" => "Blitz",
        "ready" => true,
        "ref" => "blitz",
        "repositories" => [
          %{"ref" => "blitz-infra", "url" => nil},
          %{"ref" => "blitz-app-svelte", "url" => nil}
        ]
      },
      "environment_count" => 1,
      "invitations" => %{"user_group_refs" => [], "user_refs" => ["U456"]},
      "observation" => %{"on" => false, "source" => "channel"},
      "participation" => %{"source" => "installation", "value" => "mentions"},
      "revision" => 2
    }
  end

  test "rejects malformed cards, controls, publication identities, and dates" do
    assert Renderer.render(:not_a_document) == {:error, {:invalid_slack_render, :document}}

    assert Renderer.render(%{"incident_room" => %{}}) ==
             {:error, {:invalid_slack_render, :incident_room}}

    assert Renderer.render(%{"task_card" => %{}}) ==
             {:error, {:invalid_slack_render, :task_card}}

    assert Renderer.render(%{"channel_setup" => %{}}) ==
             {:error, {:invalid_slack_render, :channel_setup}}

    assert Renderer.render(%{"task_card" => %{task_document("working") | "controls" => "stop"}}) ==
             {:error, {:invalid_slack_render, :task_card}}

    malformed_publication =
      task_document("working")
      |> put_in(["publication"], %{
        "branch" => "refs/heads/ryker/card",
        "controls" => ["open"],
        "publication_ref" => nil,
        "pull_request_number" => 1,
        "pull_request_url" => "http://example.test/pr/1",
        "recovery_generation" => nil,
        "status" => "published"
      })

    assert Renderer.render(%{"task_card" => malformed_publication}) ==
             {:error, {:invalid_slack_render, :task_card}}

    assert Renderer.render(%{
             "incident_room" => %{
               incident_document("investigating")
               | "updated_at" => "yesterday"
             }
           }) == {:error, {:invalid_slack_render, :incident_room}}
  end

  defp record(kind, payload) do
    %{
      "kind" => kind,
      "payload" => payload,
      "ref" => "record:#{kind}:abc123",
      "status" => "open"
    }
  end

  defp approval_status(status, error, review) do
    %{
      "action_id" => "nomad.alloc_restart",
      "approval_url" => "https://emisar.example/app/acme/approvals/apr-1",
      "expires_at" => "2099-08-29T12:00:00.000000Z",
      "operation_id" => "op-1",
      "pack_ref" => "nomad@1#sha256:abc",
      "remote_error" => error,
      "request_id" => "apr-1",
      "review" => review,
      "run_id" => "run-1",
      "run_url" => "https://emisar.example/app/acme/runs/run-1",
      "runner_ref" => "production-runner",
      "status" => status
    }
  end

  defp review(fields) do
    Map.merge(
      %{
        "request_id" => "apr-1",
        "status" => "pending",
        "required_approvals" => 2,
        "approved_count" => 0,
        "argument_count" => 2,
        "reason" => "Check whether the reload churn has settled.",
        "evidence" => "43 reloads in ten minutes across five allocations.",
        "expected" => "A time series showing whether reloads returned below the threshold.",
        "command" => %{
          "kind" => "preview",
          "text" => "vmctl query-range --query 'sum(...)' --step 60s",
          "truncated" => false
        },
        "decisions" => []
      },
      fields
    )
  end

  defp approve(actor, reason \\ nil), do: review_decision(actor, "approve", reason)
  defp deny(actor, reason), do: review_decision(actor, "deny", reason)

  defp review_decision(actor, decision, reason) do
    %{"actor" => actor, "decision" => decision, "decided_at" => "2026-09-11T08:07:23.379141Z"}
    |> then(&if reason, do: Map.put(&1, "reason", reason), else: &1)
  end

  defp headings(blocks) do
    for %{"type" => "section", "text" => %{"text" => text}} <- blocks,
        [_, heading] = Regex.run(~r/\A\*([^*]+)\*/, text) || [nil, nil],
        heading != nil,
        do: heading
  end

  defp section_text(%{"type" => "section", "text" => %{"text" => text}}), do: text
  defp section_text(_block), do: nil

  defp context_text(%{"type" => "context", "elements" => [%{"text" => text} | _]}), do: text
  defp context_text(_block), do: ""

  defp status_text(blocks) do
    Enum.find_value(blocks, fn block ->
      text = get_in(block, ["text", "text"])
      if is_binary(text) and String.starts_with?(text, "*Status*"), do: text
    end)
  end

  defp setup_document(session_ref) do
    %{
      "channel_setup" => %{
        "bot_user_ref" => "UBOT",
        "draft" => %{
          "alert_policy" => nil,
          "environment_options" => [
            %{
              "emisar" => true,
              "name" => "Production",
              "ref" => "production",
              "repositories" => ["ryker", "docs"]
            }
          ],
          "invite_user_group_refs" => [],
          "invite_user_refs" => [],
          "participation" => nil
        },
        "expires_at" => "2026-08-28T12:30:00.000000Z",
        "revision" => 1,
        "session_ref" => session_ref,
        "status" => "asking",
        "step" => "participation"
      }
    }
  end

  defp settings_document do
    %{
      "alert_policy" => "reply",
      "configuration_ref" => Ecto.UUID.generate(),
      "customized_by" => nil,
      "environment" => %{
        "emisar" => false,
        "name" => "Production",
        "ready" => true,
        "ref" => "production",
        "repositories" => [
          %{"ref" => "backend", "url" => "https://github.com/acme/backend"},
          %{"ref" => "infrastructure", "url" => nil}
        ]
      },
      "environment_count" => 2,
      "invitations" => %{"user_group_refs" => [], "user_refs" => []},
      "observation" => %{"on" => false, "source" => "installation"},
      "participation" => %{"source" => "installation", "value" => "mentions"},
      "revision" => 3
    }
  end

  defp welcome_document(configuration_ref, settings, notice \\ nil) do
    %{
      "channel_welcome" => %{
        "bot_user_ref" => "UBOT",
        "configuration_ref" => configuration_ref,
        "notice" => notice,
        "revision" => 3,
        "settings" => Map.put(settings, "configuration_ref", configuration_ref)
      }
    }
  end

  defp task_stages do
    Enum.map(TaskStages.stages(), fn stage ->
      %{
        "current" => stage == "implementation",
        "detail" => nil,
        "stage" => stage,
        "state" => if(stage == "implementation", do: "running", else: "pending"),
        "subtasks" => [],
        "subtasks_total" => nil,
        "url" => nil,
        "your_turn" => false
      }
    end)
  end

  defp task_document(status) do
    %{
      "action_needed" => nil,
      "confirmed_at" => "2026-08-28T12:00:00.000000Z",
      "confirmed_by" => "slack:user:U123",
      "controls" => [],
      "episode_state" => "working",
      "publication" => nil,
      "repository" => "ryker",
      "session_generation" => nil,
      "stages" => task_stages(),
      "status" => status,
      "summary" => "The durable task state is current.",
      "task_ref" => "task-card:abc123",
      "title" => "Verify the product",
      "ui_revision" => 2,
      "updated_at" => "2026-08-28T12:01:00.000000Z",
      "work_state" => nil
    }
  end

  defp publication_task_card(publication) do
    "action_required"
    |> task_document()
    |> Map.merge(%{
      "episode_state" => "complete",
      "publication" => publication,
      "work_state" => "settled"
    })
  end

  defp incident_document(status) do
    %{
      "action_needed" => "Review the current blocker.",
      "alert" => %{"impact" => "Checkout traffic is affected.", "verdict" => "firing"},
      "controls" => [],
      "episode_state" => "working",
      "goals" => [],
      "opened_at" => "2026-08-28T12:00:00.000000Z",
      "opened_by" => "slack:user:U123",
      "repository" => "ryker",
      "room_ref" => "incident-room:82208f8f-2ef4-4f1b-a011-626aabdc9342",
      "session_generation" => nil,
      "severity" => "high",
      "signals" => %{"firing" => 2, "total" => 3},
      "source" => %{
        "channel_ref" => "C123",
        "message_ref" => "1787832000.000100",
        "thread_ref" => "1787832000.000100"
      },
      "status" => status,
      "summary" => "The investigation state is current.",
      "title" => "Checkout errors",
      "ui_revision" => 2,
      "updated_at" => "2026-08-28T12:01:00.000000Z"
    }
  end
end
