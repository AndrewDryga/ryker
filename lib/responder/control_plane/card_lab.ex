defmodule Responder.ControlPlane.CardLab do
  @moduledoc """
  Deterministic, side-effect-free catalog of every Slack presentation state.

  Message specimens pass through `Responder.Slack.Renderer`; App Home and modal
  specimens pass through their production view builders. Transition edges only
  select another checked-in specimen and never invoke a Slack or domain action.
  """

  alias Responder.Emisar.RunState
  alias Responder.Slack.{AppHome, AppHomeEditor, Renderer, ThreadStatusProjection}
  alias Responder.Work.TaskStages

  @legacy_path Path.expand("../../../priv/card_lab/legacy_task_records.json", __DIR__)
  @external_resource @legacy_path
  @legacy Jason.decode!(File.read!(@legacy_path))

  @task_statuses ~w(queued working waiting_for_input waiting_for_event action_required stopping reviewing ready_to_publish published completed cancelled)
  @incident_statuses ~w(provisioning investigating action_required waiting_for_input waiting_for_event stopping resolved cancelled paused)
  @spec catalog() :: [map()]
  def catalog do
    key = {__MODULE__, :catalog, __MODULE__.module_info(:md5)}

    case :persistent_term.get(key, :missing) do
      :missing ->
        catalog = build_catalog()
        :persistent_term.put(key, catalog)
        catalog

      catalog ->
        catalog
    end
  end

  defp build_catalog do
    [
      task_cards(),
      incident_rooms(),
      channel_welcome(),
      channel_setup(),
      channel_settings(),
      governed_actions(),
      task_offers(),
      publication_cards(),
      schedule_offers(),
      automation_changes(),
      memory_offers(),
      behavior_offers(),
      slack_post_offers(),
      input_and_waits(),
      investigation_records(),
      ordinary_messages(),
      app_home(),
      app_home_modal(),
      thread_statuses()
    ]
  end

  @spec fetch(String.t(), String.t()) :: {:ok, map()} | {:error, :card_lab_specimen_not_found}
  def fetch(card_id, state_id) when is_binary(card_id) and is_binary(state_id) do
    catalog = catalog()

    with %{} = card <- Enum.find(catalog, &(&1.id == card_id)),
         %{} = state <- Enum.find(card.states, &(&1.id == state_id)) do
      {:ok,
       %{card: card, catalog: catalog_summary(catalog), rendered: state.rendered, state: state}}
    else
      nil -> {:error, :card_lab_specimen_not_found}
    end
  end

  def fetch(_card_id, _state_id), do: {:error, :card_lab_specimen_not_found}

  @doc "Renders an explicitly labelled Slack test message with inert specimen controls."
  @spec slack_message(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def slack_message(card_id, state_id) do
    with {:ok, snapshot} <- fetch(card_id, state_id),
         true <- snapshot.card.surface == :message do
      label = "Card Lab · #{snapshot.card.title} · #{snapshot.state.label} · Test controls only"

      banner = %{
        "type" => "context",
        "elements" => [%{"type" => "plain_text", "text" => label}]
      }

      rendered = isolate_controls(snapshot.rendered)

      {:ok,
       %{
         "blocks" => [banner | rendered["blocks"]],
         "text" => label <> "\n" <> rendered["text"]
       }}
    else
      false -> {:error, :card_lab_requires_native_surface}
      {:error, _reason} = error -> error
    end
  end

  defp isolate_controls(values) when is_list(values), do: Enum.map(values, &isolate_controls/1)

  defp isolate_controls(%{} = value) do
    Map.new(value, fn
      {"action_id", id} -> {"action_id", "card_lab_preview_" <> id}
      {key, item} -> {key, isolate_controls(item)}
    end)
  end

  defp isolate_controls(value) when is_binary(value) do
    value
    |> String.replace(
      ~r/<!(?!date\^\d+\^\{date_short_pretty\} at \{time\}\|\d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC>)/,
      "&lt;!"
    )
    |> String.replace("<@", "&lt;@")
  end

  defp isolate_controls(value), do: value

  @spec default() :: map()
  def default do
    catalog = catalog()
    [card | _rest] = catalog
    [state | _rest] = card.states

    %{
      card: card,
      catalog: catalog_summary(catalog),
      rendered: state.rendered,
      state: state
    }
  end

  @spec transition(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :card_lab_specimen_not_found | :card_lab_transition_not_found}
  def transition(card_id, state_id, transition_id) do
    with {:ok, %{state: state}} <- fetch(card_id, state_id),
         %{} = transition <- Enum.find(state.transitions, &(&1.id == transition_id)) do
      fetch(card_id, transition.to)
    else
      nil -> {:error, :card_lab_transition_not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec coverage() :: map()
  def coverage do
    cards = catalog()

    %{
      card_count: length(cards),
      emisar_review_outcomes: covered(cards, :emisar_review),
      emisar_statuses: covered(cards, :emisar_status),
      incident_statuses: covered(cards, :incident_status),
      record_kinds: covered(cards, :record_kind),
      record_states: covered(cards, :record_state),
      settings_audiences: covered(cards, :settings_audience),
      setup_states: covered(cards, :setup_state),
      setup_statuses: covered(cards, :setup_status),
      setup_steps: covered(cards, :setup_step),
      specimen_count: Enum.sum(Enum.map(cards, &length(&1.states))),
      welcome_states: covered(cards, :welcome_state),
      surfaces: cards |> Enum.map(& &1.surface) |> MapSet.new(),
      task_statuses: covered(cards, :task_status),
      thread_phases: covered(cards, :thread_phase)
    }
  end

  defp catalog_summary(catalog) do
    Enum.map(catalog, fn card ->
      %{
        first_state_id: hd(card.states).id,
        id: card.id,
        state_count: length(card.states),
        surface: card.surface,
        title: card.title
      }
    end)
  end

  defp covered(cards, key) do
    cards
    |> Enum.flat_map(& &1.states)
    |> Enum.flat_map(fn state -> List.wrap(Map.get(state.covers, key)) end)
    |> Enum.uniq()
  end

  defp task_cards do
    states =
      @task_statuses
      |> Enum.map(fn status ->
        state(slug(status), humanize(status), task_description(status), task_document(status), %{
          task_status: status
        })
      end)
      |> insert_after("reviewing", [
        state(
          "automatic-readiness",
          "Checking changes",
          "The confirmed task starts its ordinary readiness checks without another permission request.",
          task_document("reviewing", publication("review_pending", []))
          |> put_in(["task_card", "controls"], ~w(view_diff timeline evidence handoff))
          |> put_in(["task_card", "episode_state"], "complete")
          |> put_in(["task_card", "work_state"], "settled"),
          %{task_status: "reviewing"}
        ),
        state(
          "unstarted-readiness",
          "Prepared changes need recovery",
          "A retained completed task has changes but no review custody. It is not completed publication.",
          task_document("action_required")
          |> put_in(["task_card", "controls"], ~w(view_diff timeline evidence handoff))
          |> put_in(["task_card", "episode_state"], "complete")
          |> put_in(["task_card", "work_state"], "settled")
          |> put_in(["task_card", "summary"], "The prepared changes remain saved.")
          |> put_in(
            ["task_card", "action_needed"],
            "Prepared changes are saved, but checks have not started. Open the episode to review workspace recovery."
          ),
          %{task_status: "action_required"}
        ),
        state(
          "reviewed-publication",
          "Reviewed candidate",
          "No confirmed task grants a draft for this candidate, so opening one stays a person's click.",
          task_document("ready_to_publish", publication("reviewed", ["publish"])),
          %{task_status: "ready_to_publish"}
        ),
        state(
          "autonomous-draft",
          "Opening the draft",
          "The confirming person's task grant covers this exact reviewed candidate, so the draft opens with no click.",
          task_document("reviewing", publication("publish_pending", [], 1))
          |> put_in(["task_card", "controls"], ~w(timeline evidence handoff))
          |> put_in(["task_card", "episode_state"], "complete")
          |> put_in(["task_card", "work_state"], "settled"),
          %{task_status: "reviewing"}
        ),
        state(
          "blocked-publication",
          "Publication blocked",
          "A recoverable publication failure offers refresh or discard controls.",
          task_document("action_required", publication("blocked", ["update", "discard"], 3)),
          %{task_status: "action_required"}
        ),
        state(
          "unverified-draft-offer",
          "Checks unavailable",
          "The gate could not start in the worker. The exact saved change is offered as an explicitly unverified draft, never opened automatically.",
          task_document(
            "action_required",
            publication(
              "blocked",
              ["publish", "update", "discard"],
              3,
              false,
              "docker: command not found"
            )
          ),
          %{task_status: "action_required"}
        ),
        state(
          "held-workspace",
          "Workspace not recoverable yet",
          "The worker finished and answered, the host could not snapshot its working copy, and the session was then closed. Recovery is the only control this state can offer: there is no changes page, nothing to publish, and no retry that reaches the stranded copy.",
          task_document("action_required")
          |> put_in(["task_card", "controls"], ~w(close timeline evidence handoff recovery))
          |> put_in(["task_card", "work_state"], "blocked")
          |> put_in(
            ["task_card", "action_needed"],
            "The worker finished, but I couldn't save its working copy, so its reply is still held. Nothing was published. Keep its working copy and task notes: the worker session is closed, so a retry can't recover them. The worker's own report, which is not a check result: “Prepared the internal hosted runner bump from 0.23.1 to 0.27.0. Terraform validation, formatting, TFLint, release-pin checks and rendered startup syntax checks passed. The full infra gate stopped because this box lacks Docker.”"
          )
          |> put_in(
            ["task_card", "stages"],
            specimen_stages(
              ~w(failed completed completed pending pending pending pending),
              %{"workspace_setup" => "no saved snapshot · session closed"},
              nil
            )
          ),
          %{task_status: "action_required"}
        ),
        state(
          "unverified-draft-open",
          "Draft open, checks incomplete",
          "The operator opened the unverified draft. The pull request exists and CI on its exact head is its own row, but the trusted gate still never ran, so the check stage stays open and nobody is handed a merge.",
          task_document(
            "published",
            publication("published", ["open", "check"], 5, true, "docker: command not found")
          )
          |> put_in(
            ["task_card", "stages"],
            specimen_stages(
              ~w(completed completed completed failed completed completed pending),
              %{"self_review" => "docker: command not found", "draft_pr" => "#91", "ci" => "8/8"},
              publication("published", ["open", "check"], 5, true)
            )
          ),
          %{task_status: "published"}
        ),
        state(
          "conflicted-publication",
          "Publication conflict",
          "A stale or conflicting candidate remains operator-owned and recoverable.",
          task_document(
            "action_required",
            publication("publish_pending", ["open", "update", "discard"], 4, true)
          ),
          %{task_status: "action_required"}
        ),
        state(
          "published-stale-head",
          "Published, newer head",
          "The draft PR exists but the retained workspace has newer unpublished work.",
          task_document(
            "published",
            publication("published", ["open", "check", "update", "discard"], 5, true)
          ),
          %{task_status: "published"}
        )
      ])

    states =
      Enum.map(states, fn specimen ->
        if specimen.id == "working" do
          historical_task_state("working", "Working · recorded", 4)
        else
          Map.put(specimen, :provenance, %{
            basis: "State simulation",
            source_ref: nil,
            observed_at: nil,
            note:
              "This exercises a supported state. It is not a claim that this transition occurred in the legacy task."
          })
        end
      end)
      |> insert_after("working", [
        historical_task_state("working-validation", "Later progress · recorded", 8),
        historical_task_state("working-finalizing", "Finalizing · recorded", 12)
      ])
      |> insert_after("completed", [recorded_goal_state()])

    states =
      put_transitions(states, %{
        "working" => [
          t("next-recorded", "Next recorded update", "working-validation"),
          t("wait-input", "Need operator input", "waiting-for-input"),
          t("wait-event", "Wait for event", "waiting-for-event"),
          t("need-action", "Raise blocker", "action-required"),
          t("stop", "Stop current run", "stopping"),
          t("review", "Start review", "reviewing")
        ],
        "working-validation" => [t("next-recorded", "Next recorded update", "working-finalizing")],
        "working-finalizing" => [t("restart-recorded", "First recorded update", "working")],
        "waiting-for-input" => [t("resume", "Resume work", "working")],
        "waiting-for-event" => [t("event-arrived", "Event arrived", "working")],
        "action-required" => [t("correct", "Apply correction", "working")],
        "stopping" => [t("stopped", "Finish stopping", "cancelled")],
        "reviewing" => [t("check", "Checks start automatically", "automatic-readiness")],
        "automatic-readiness" => [
          t("reviewed", "Pass readiness", "reviewed-publication"),
          t("blocked", "Block publication", "blocked-publication")
        ],
        "reviewed-publication" => [t("publish", "Publish draft", "published")],
        "blocked-publication" => [
          t("refresh", "Review latest state", "reviewed-publication"),
          t("discard", "Discard candidate", "cancelled")
        ],
        "conflicted-publication" => [
          t("refresh", "Review latest state", "reviewed-publication"),
          t("discard", "Discard candidate", "cancelled")
        ],
        "ready-to-publish" => [t("publish", "Publish draft", "published")],
        "published" => [
          t("new-head", "Detect newer head", "published-stale-head"),
          t("complete", "Delivery complete", "completed")
        ],
        "published-stale-head" => [
          t("update", "Review latest head", "reviewed-publication"),
          t("complete", "Keep published draft", "completed")
        ]
      })

    family(
      "task-card",
      "Task card",
      "Pinned engineering work, publication recovery, and terminal outcomes.",
      :message,
      states
    )
  end

  defp historical_task_state(id, label, sequence) do
    source = @legacy["runner_task"]
    progress = source["progress"] |> Enum.filter(&(&1["sequence"] <= sequence)) |> Enum.take(-4)
    latest = List.last(progress)

    task =
      task_document("working")["task_card"]
      |> Map.merge(%{
        "title" => source["title"],
        "repository" => source["repository"],
        "summary" => latest["summary"],
        "request" => source["title"],
        "confirmed_at" => source["created_at"],
        "confirmed_by" => "Legacy actor not retained",
        "session_generation" => nil,
        "work_state" => nil,
        "updated_at" => latest["at"],
        "stages" => unrecorded_stages()
      })

    state(
      id,
      label,
      "The real runner-pin task, replayed from retained progress records.",
      %{"task_card" => task},
      %{task_status: "working"}
    )
    |> Map.put(:provenance, %{
      basis: "Retained progress",
      source_ref: source["episode_id"],
      observed_at: latest["at"],
      note:
        "Request and progress are from the legacy database. This is a new-renderer replay, not an archived Slack payload. Controls are test-only; missing actor/session metadata is not reconstructed."
    })
  end

  # A task retained before typed stage membership existed: its stages are
  # explicitly unrecorded rather than backfilled from prose.
  defp unrecorded_stages do
    Enum.map(TaskStages.stages(), fn stage ->
      state = if stage in ~w(planning implementation self_review), do: "unknown", else: "pending"

      %{
        "current" => false,
        "detail" => if(state == "unknown", do: "not recorded"),
        "stage" => stage,
        "state" => state,
        "subtasks" => [],
        "subtasks_total" => nil,
        "url" => nil,
        "your_turn" => false
      }
    end)
  end

  defp recorded_goal_state do
    source = @legacy["portal_goals"]

    task =
      task_document("completed")["task_card"]
      |> Map.merge(%{
        "title" => "Portal recovery · retained goals",
        "repository" => "emisar",
        "summary" =>
          "The three retained goals are complete. Overall task state is simulated for this layout study.",
        "stages" =>
          unrecorded_stages() ++
            [
              %{
                "current" => false,
                "detail" => "3 subtasks recorded without a stage",
                "stage" => "unassigned",
                "state" => "unknown",
                "subtasks" =>
                  Enum.map(source["goals"], fn goal ->
                    %{
                      "current" => false,
                      "detail" => nil,
                      "id" => goal["id"],
                      "outcome" => goal["requested_outcome"],
                      "state" => goal["state"]
                    }
                  end),
                "subtasks_total" => length(source["goals"]),
                "url" => nil,
                "your_turn" => false
              }
            ]
      })

    state(
      "recorded-goals",
      "Real goals · layout study",
      source["note"],
      %{"task_card" => task},
      %{task_status: "completed"}
    )
    |> Map.put(:provenance, %{
      basis: "Real goals · layout study",
      source_ref: source["episode_id"],
      observed_at: nil,
      note:
        "Goal titles and final goal states are real. The surrounding task state and controls are a layout study, not a captured engineering task."
    })
  end

  defp incident_rooms do
    states =
      @incident_statuses
      |> Enum.map(fn status ->
        state(
          slug(status),
          humanize(status),
          incident_description(status),
          incident_document(status),
          %{
            incident_status: status
          }
        )
      end)
      |> sequence()

    family(
      "incident-room",
      "Incident room",
      "Pinned incident anchor from provisioning through resolution or cancellation.",
      :message,
      states
    )
  end

  defp channel_welcome do
    states = [
      welcome_state("default", "Default · ready without setup", settings_document(), nil),
      welcome_state(
        "proactive",
        "Proactive",
        settings_document(participation: "proactive", customized_by: "U123", revision: 2),
        "Update: proactive mode is on."
      ),
      welcome_state(
        "customized",
        "After Q&A",
        settings_document(
          alert_policy: "offer",
          customized_by: "U123",
          default_repository: "emisar",
          invite_user_refs: ["U456"],
          participation: "proactive",
          revision: 3
        ),
        "Settings updated."
      ),
      welcome_state(
        "shadow",
        "Observation mode",
        settings_document(observation: true, participation: "shadow"),
        nil
      ),
      welcome_state(
        "no-repository",
        "No repository connected",
        settings_document(repositories: [], default_repository: nil),
        nil
      )
    ]

    family(
      "channel-welcome",
      "Channel welcome",
      "One welcome generated from the effective saved settings; the optional Q&A re-renders it in place.",
      :message,
      sequence(states)
    )
  end

  defp welcome_state(id, label, settings, notice) do
    state(
      id,
      label,
      "Welcome prose and controls follow the effective saved settings.",
      %{
        "channel_welcome" => %{
          "bot_user_ref" => "UCARDLAB",
          "configuration_ref" => settings["configuration_ref"],
          "notice" => notice,
          "revision" => settings["revision"],
          "settings" => settings
        }
      },
      %{welcome_state: id}
    )
  end

  defp channel_settings do
    states =
      Enum.map(["thread", "private"], fn audience ->
        settings =
          settings_document(participation: "proactive", customized_by: "U123", revision: 2)

        state(
          audience,
          if(audience == "thread", do: "Asked in conversation", else: "/responder status"),
          "The same structured effective-settings view; the reply stays in its thread, the command stays private.",
          %{
            "channel_settings" => %{
              "audience" => audience,
              "bot_user_ref" => "UCARDLAB",
              "configuration_ref" => settings["configuration_ref"],
              "revision" => settings["revision"],
              "settings" => settings
            }
          },
          %{settings_audience: audience}
        )
      end)

    family(
      "channel-settings",
      "Channel settings on request",
      "Settings shown on request share the welcome's projection and controls.",
      :message,
      sequence(states)
    )
  end

  defp settings_document(overrides \\ []) do
    repositories =
      Keyword.get(overrides, :repositories, [
        %{"ref" => "responder", "url" => "https://github.com/acme/responder"},
        %{"ref" => "emisar", "url" => "https://github.com/acme/emisar"}
      ])

    participation = Keyword.get(overrides, :participation, "mentions")
    customized_by = Keyword.get(overrides, :customized_by)

    # A channel that chose for itself reports "channel"; one that never did
    # reports the installation default it follows.
    source =
      Keyword.get(overrides, :source, if(customized_by, do: "channel", else: "installation"))

    %{
      "alert_policy" => Keyword.get(overrides, :alert_policy, "reply"),
      "configuration_ref" => "018f3ef7-1f62-7ee0-a83c-0c12f21d83e7",
      "customized_by" => customized_by,
      "default_repository" =>
        Keyword.get(
          overrides,
          :default_repository,
          if(repositories == [], do: nil, else: "responder")
        ),
      "invitations" => %{
        "on_call_count" => 2,
        "user_group_refs" => [],
        "user_refs" => Keyword.get(overrides, :invite_user_refs, [])
      },
      "observation" => %{"on" => Keyword.get(overrides, :observation, false), "source" => source},
      "participation" => %{"source" => source, "value" => participation},
      "repositories" => repositories,
      "revision" => Keyword.get(overrides, :revision, 1)
    }
  end

  defp channel_setup do
    states = [
      state(
        "participation",
        "1 · Conversations",
        "Mentions only, Be proactive, or Observe only, each explained.",
        setup_document("asking", "participation"),
        %{setup_state: "participation", setup_status: "asking", setup_step: "participation"}
      ),
      state(
        "repository",
        "2 · Repositories",
        "Choose the default repository for coding tasks.",
        setup_document("asking", "repository"),
        %{setup_state: "repository", setup_status: "asking", setup_step: "repository"}
      ),
      state(
        "alerts",
        "3 · Alerts",
        "Investigate in the thread, offer a choice, or create a room automatically.",
        setup_document("asking", "alerts"),
        %{setup_state: "alerts", setup_status: "asking", setup_step: "alerts"}
      ),
      state(
        "audience",
        "4 · Invitations",
        "Who is invited when an incident room is created.",
        setup_document("asking", "audience"),
        %{setup_state: "audience", setup_status: "asking", setup_step: "audience"}
      ),
      state(
        "confirming",
        "5 · Confirm",
        "Review the complete draft before saving.",
        setup_document("confirming", "confirm"),
        %{setup_state: "confirming", setup_status: "confirming", setup_step: "confirm"}
      ),
      state(
        "saved",
        "Saved",
        "The wizard is retired; the welcome above was re-rendered from the saved settings.",
        setup_document("saved", "confirm"),
        %{setup_state: "saved", setup_status: "saved", setup_step: "confirm"}
      ),
      state(
        "cancelled",
        "Cancelled",
        "No setting changed.",
        setup_document("cancelled", "confirm"),
        %{setup_state: "cancelled", setup_status: "cancelled", setup_step: "confirm"}
      ),
      state(
        "expired",
        "Expired",
        "The draft expired without changing settings.",
        setup_document("expired", "confirm"),
        %{setup_state: "expired", setup_status: "expired", setup_step: "confirm"}
      )
    ]

    family(
      "channel-setup",
      "Channel setup",
      "The optional setup Q&A: one wizard message that replaces itself in the welcome thread.",
      :message,
      sequence(states)
    )
  end

  defp governed_actions do
    run_states =
      Enum.map(RunState.statuses(), fn status ->
        error =
          if status in ~w(failed error validation_failed unknown_action),
            do: "The exact remote run reported a bounded failure.",
            else: nil

        state(
          slug(status),
          humanize(status),
          "Authoritative Emisar run status: #{status}.",
          %{"emisar_approval_status" => approval_status(status, error)},
          %{emisar_status: status}
        )
      end)

    family(
      "governed-action",
      "Governed action",
      "One Emisar review message: its rationale, the command it is judged on, and every recorded decision.",
      :message,
      sequence(run_states ++ review_states())
    )
  end

  # The review outcomes the card exists to report. The run status barely moves
  # across them — which is the point: these are decisions, not execution.
  defp review_states do
    Enum.map(review_specimens(), fn {slug, label, run_status, review} ->
      state(
        "review-#{slug}",
        label,
        "Authoritative Emisar review outcome: #{review["status"]}.",
        %{
          "emisar_approval_status" =>
            approval_status(run_status, nil) |> Map.put("review", review)
        },
        %{emisar_status: run_status, emisar_review: review["status"]}
      )
    end)
  end

  defp review_specimens do
    [
      {"pending", "Review · pending", "pending_approval", review_specimen(%{})},
      {"partial", "Review · one of two", "pending_approval",
       review_specimen(%{
         "approved_count" => 1,
         "decisions" => [lab_decision("approve", "Amara Osei")]
       })},
      {"granted", "Review · granted", "success",
       review_specimen(%{
         "status" => "approved",
         "required_approvals" => 1,
         "approved_count" => 1,
         "decisions" => [
           lab_decision("approve", "Amara Osei", "Read-only query; no configuration changes.")
         ]
       })},
      {"granted-many", "Review · quorum granted", "success",
       review_specimen(%{
         "status" => "approved",
         "approved_count" => 2,
         "decisions" => [
           lab_decision("approve", "Amara Osei"),
           lab_decision("approve", "Jonas Weber", "The runner and query scope are correct.")
         ]
       })},
      {"denied", "Review · denied", "denied",
       review_specimen(%{
         "status" => "denied",
         "approved_count" => 1,
         "decisions" => [
           lab_decision("approve", "Amara Osei"),
           lab_decision("deny", "Jonas Weber", "Please narrow the query to the affected service.")
         ]
       })},
      {"expired", "Review · window expired", "cancelled",
       review_specimen(%{
         "status" => "expired",
         "approved_count" => 1,
         "decisions" => [lab_decision("approve", "Amara Osei")]
       })},
      {"cancelled", "Review · cancelled", "cancelled",
       review_specimen(%{"status" => "cancelled"})},
      {"override", "Review · admin override", "success",
       review_specimen(%{
         "status" => "approved",
         "approved_count" => 1,
         "decisions" => [lab_decision("approve", "Amara Osei")],
         "override" => %{
           "actor" => "Priya Raman",
           "reason" =>
             "A second reviewer is unavailable; we need this read-only check during the incident.",
           "approved_count" => 1,
           "required_approvals" => 2,
           "waived_approvals" => 1,
           "decided_at" => "2099-09-04T12:20:00.000000Z"
         }
       })},
      {"executed", "Review · executed receipt", "success",
       review_specimen(%{
         "status" => "approved",
         "approved_count" => 2,
         "decisions" => [
           lab_decision("approve", "Amara Osei"),
           lab_decision("approve", "Jonas Weber")
         ],
         "command" => %{
           "kind" => "executed",
           "text" => "nomad alloc restart 9f2c1b7e",
           "truncated" => false
         }
       })}
    ]
  end

  defp review_specimen(fields) do
    Map.merge(
      %{
        "request_id" => "apr-card-lab",
        "status" => "pending",
        "required_approvals" => 2,
        "approved_count" => 0,
        "argument_count" => 2,
        "reason" => "Restart the stuck allocation so the ingest queue drains.",
        "evidence" =>
          "The allocation has been unhealthy for 18 minutes and the queue is growing.",
        "expected" => "A healthy allocation and a falling queue depth within five minutes.",
        "command" => %{
          "kind" => "preview",
          "text" => "nomad alloc restart 9f2c1b7e",
          "truncated" => false
        },
        "decisions" => []
      },
      fields
    )
  end

  defp lab_decision(decision, actor, reason \\ nil) do
    %{"actor" => actor, "decision" => decision, "decided_at" => "2099-09-04T12:15:00.000000Z"}
    |> then(&if reason, do: Map.put(&1, "reason", reason), else: &1)
  end

  defp task_offers do
    states = [
      record_state(
        "engineering",
        "Engineering task",
        "Create isolated repository work after confirmation.",
        "task_offer",
        %{
          "kind" => "engineering",
          "prompt" => "Repair the parser and run focused tests.",
          "repository" => "responder",
          "title" => "Fix parser retries"
        }
      ),
      record_state(
        "engineering-started",
        "Task started",
        "The confirmed offer names the path it took; the task card follows in the thread.",
        "task_offer",
        %{
          "kind" => "engineering",
          "prompt" => "Repair the parser and run focused tests.",
          "repository" => "responder",
          "title" => "Fix parser retries"
        },
        "confirmed"
      ),
      record_state(
        "incident",
        "Incident offer",
        "Investigate in this thread or create an incident room; one offer owns both paths.",
        "task_offer",
        incident_offer_payload()
      ),
      record_state(
        "incident-investigating",
        "Investigating in the thread",
        "Durable read-only work started in this thread, with no room and no invitations.",
        "task_offer",
        incident_offer_payload(),
        "confirmed"
      ),
      record_state(
        "incident-room-requested",
        "Incident room requested",
        "The room is being created; Open incident room appears only once it exists.",
        "task_offer",
        incident_offer_payload(),
        "confirmed",
        %{"incident_room" => %{"url" => nil}}
      ),
      record_state(
        "incident-room-created",
        "Incident room created",
        "The offer links to the room that now exists.",
        "task_offer",
        incident_offer_payload(),
        "confirmed",
        %{
          "incident_room" => %{
            "url" => "https://slack.com/app_redirect?team=T0BHXKZJVDX&channel=C0BHTRPHXP1"
          }
        }
      )
    ]

    family(
      "task-offer",
      "Task offers",
      "Operator confirmation before repository or incident work.",
      :message,
      sequence(states)
    )
  end

  defp incident_offer_payload do
    %{
      "kind" => "incident",
      "prompt" => "Coordinate the current production symptoms.",
      "repository" => nil,
      "title" => "Checkout errors"
    }
  end

  defp publication_cards do
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
      "repository" => "responder",
      "title" => "Fix retry reconciliation"
    }

    states = [
      record_state(
        "offer",
        "Publication offer",
        "Committed work can enter a read-only review.",
        "publication_offer",
        %{
          "body" => "Implements the requested retry boundary.",
          "title" => "Fix retry reconciliation"
        }
      ),
      publication_state("review-publishable", "Publishable review", review, "open"),
      publication_state(
        "review-authorized",
        "Authorized draft",
        %{review | "draft_authorized" => true},
        "open"
      ),
      publication_state(
        "review-blocked",
        "Blocked review",
        %{review | "gate" => "failed", "publishable" => false, "reasons" => ["gate_failed"]},
        "open"
      ),
      state(
        "published",
        "Draft published",
        "The exact draft PR has open and delivery-check controls.",
        render_record(
          "publication_result",
          %{
            "branch_ref" => "refs/heads/responder/fix-42",
            "commit_sha" => String.duplicate("a", 40),
            "pull_request_number" => 42,
            "pull_request_url" => "https://github.com/acme/responder/pull/42",
            "repository" => "responder",
            "title" => "Fix lifecycle tracking"
          },
          "confirmed",
          "publication:published42"
        ),
        %{record_kind: "publication_result", record_state: "publication_result:confirmed"}
      )
    ]

    family(
      "publication",
      "Publication cards",
      "Offer, review verdicts, and published draft receipt.",
      :message,
      sequence(states)
    )
  end

  defp schedule_offers do
    recurrences = [
      {"once", %{"at" => "2099-09-04T14:00:00.000000Z", "kind" => "once"}},
      {"interval",
       %{
         "every_seconds" => 3_600,
         "kind" => "interval",
         "starts_at" => "2099-09-04T14:00:00.000000Z"
       }},
      {"daily", %{"kind" => "daily", "time" => "09:00:00"}},
      {"weekly", %{"kind" => "weekly", "time" => "09:00:00", "weekday" => "monday"}},
      {"monthly", %{"day" => 15, "kind" => "monthly", "time" => "09:00:00"}}
    ]

    states =
      Enum.map(recurrences, fn {id, recurrence} ->
        record_state(id, humanize(id), "A #{id} recurring-work offer.", "schedule_offer", %{
          "authority" => "read_only",
          "catch_up" => "latest",
          "expires_at" => nil,
          "recurrence" => recurrence,
          "repository" => nil,
          "task" => "Inspect current service health and report material changes.",
          "timezone" => "Etc/UTC",
          "title" => "Service health"
        })
      end)

    family(
      "schedule-offer",
      "Schedule offer",
      "Every supported recurrence shape before creation.",
      :message,
      sequence(states)
    )
  end

  defp automation_changes do
    before = automation_document("active", 1)

    states =
      ~w(update pause resume delete)
      |> Enum.map(fn action ->
        after_status = if action == "pause", do: "paused", else: "active"
        after_document = automation_document(after_status, 2)
        after_document = if action == "delete", do: %{}, else: after_document

        record_state(
          action,
          humanize(action),
          "Review the exact before/after #{action}.",
          "automation_change_offer",
          %{
            "action" => action,
            "after" => after_document,
            "automation_id" => before["automation_id"],
            "automation_kind" => "time",
            "before" => before,
            "patch" => %{},
            "revision" => 1
          }
        )
      end)

    family(
      "automation-change",
      "Automation change",
      "Update, pause, resume, and delete confirmations.",
      :message,
      sequence(states)
    )
  end

  defp memory_offers do
    kinds = [
      {"alias", "checkout-api", "payments-api"},
      {"repository-binding", "primary_repository", "responder"},
      {"evidence-route", "production_metrics", "Use the Emisar monitoring pack."},
      {"entity-relationship", "checkout_dependency", "checkout depends on payments"}
    ]

    states =
      Enum.map(kinds, fn {id, subject, value} ->
        kind = String.replace(id, "-", "_")

        record_state(id, humanize(id), "Scoped #{humanize(id)} memory offer.", "memory_offer", %{
          "expires_in" => "90d",
          "kind" => kind,
          "repository" => nil,
          "scope" => "conversation",
          "subject" => subject,
          "value" => value,
          "visibility" => "conversation"
        })
      end)

    family(
      "memory-offer",
      "Memory offer",
      "Every supported operational-memory kind.",
      :message,
      sequence(states)
    )
  end

  defp behavior_offers do
    states = [
      record_state(
        "preference",
        "Preference",
        "A bounded operator preference.",
        "preference_offer",
        %{
          "expires_in" => "90d",
          "key" => "response_detail",
          "repository" => nil,
          "scope" => "operator",
          "value" => "concise"
        }
      ),
      record_state(
        "guidance",
        "Guidance",
        "Advisory conversational guidance.",
        "guidance_offer",
        %{
          "expires_in" => "30d",
          "repository" => nil,
          "scope" => "conversation",
          "subject" => "terraform-review",
          "summary" => "Lead with availability risk.",
          "text" => "Explain availability and drift before resource counts.",
          "visibility" => "conversation"
        }
      ),
      record_state(
        "standing-assignment",
        "Standing assignment",
        "Legacy typed standing assignment.",
        "standing_assignment_offer",
        %{
          "action" => "review_terraform_plan",
          "expires_in" => "30d",
          "repository" => "responder-infra",
          "source_filter" => "app",
          "task" => "Review every exact Terraform plan posted here.",
          "trigger" => "terraform_plan"
        }
      ),
      record_state(
        "source-event",
        "Source-event automation",
        "Generic GitHub or platform event automation.",
        "standing_assignment_offer",
        %{
          "catch_up" => "skip",
          "context_channel" => "slack:T123:C456",
          "delivery_channel" => "slack:T123:C456",
          "expires_at" => nil,
          "filter" => %{"action" => "submitted"},
          "hold" => nil,
          "repository" => "responder",
          "source_kind" => "github",
          "task" => "Review every submitted pull request review.",
          "title" => "Review pull request reviews"
        }
      )
    ]

    family(
      "behavior-offer",
      "Behavior offers",
      "Preferences, guidance, and standing assignments.",
      :message,
      sequence(states)
    )
  end

  defp slack_post_offers do
    payload = %{
      "conversation_ref" => "slack:T123:C789",
      "destination_ref" => "slack-source:v1:T123:C789:thread:1787832888.000300",
      "instruction_ref" => "slack-source:v1:T123:C456:message:1787832000.000100",
      "message" => "The deployment is healthy.",
      "requested_by_actor_ref" => "slack:user:U123",
      "thread_ref" => "1787832888.000300",
      "transport" => "slack"
    }

    states = [
      record_state(
        "open",
        "Awaiting confirmation",
        "No additional message has been posted.",
        "slack_post_offer",
        payload
      ),
      state(
        "confirmed",
        "Confirmed",
        "The durable delivery worker is reconciling the post.",
        render_record("slack_post_offer", payload, "confirmed"),
        %{record_kind: "slack_post_offer", record_state: "slack_post_offer:confirmed"}
      )
    ]

    family(
      "slack-post",
      "Additional Slack post",
      "Requester-owned confirmation and delivery handoff.",
      :message,
      sequence(states)
    )
  end

  defp input_and_waits do
    states = [
      record_state(
        "choices",
        "Input choices",
        "A bounded choice can continue the waiting episode.",
        "input_request",
        %{
          "choices" => ["Roll out to 1%", "Stop the rollout"],
          "question" => "Which rollout action should I take?"
        }
      ),
      record_state(
        "freeform",
        "Freeform input",
        "The operator replies in the thread rather than clicking a choice.",
        "input_request",
        %{"choices" => [], "question" => "What exact threshold should I use?"}
      ),
      record_state(
        "event",
        "Timed event wait",
        "Localized next check and monitoring deadline; verification instructions remain in the episode.",
        "event_wait",
        %{
          "deadline_at" => "2099-09-05T12:00:00.000000Z",
          "event_matcher" => %{
            "type" => "source_event",
            "source_kind" => "slack",
            "match" => %{"deployment" => "responder"},
            "poll_after" => "2099-09-04T12:30:00Z",
            "on_timeout" => "Check the exact deployment."
          },
          "kind" => "deployment_health",
          "verification" => "Verify the new allocation is healthy."
        }
      ),
      record_state(
        "event-only",
        "Notification-only watch",
        "No timer footer or activity indicator while waiting for a configured lifecycle notification.",
        "event_wait",
        %{
          "deadline_at" => nil,
          "kind" => "source_event",
          "event_matcher" => %{
            "type" => "source_event",
            "source_kind" => "slack",
            "match" => %{"run_id" => "run-k9CpPp3nWjQrkCMG"},
            "poll_after" => nil,
            "on_timeout" => nil
          },
          "verification" => "Check the exact run when its lifecycle notification arrives."
        }
      ),
      record_state(
        "emisar-approval",
        "Emisar approval hold",
        "Slack links to Emisar but cannot approve the action.",
        "emisar_approval",
        approval_record()
      )
    ]

    family(
      "wait-record",
      "Questions and waits",
      "Durable input, external-event, and governed-action waits.",
      :message,
      sequence(states ++ retired_question_states())
    )
  end

  defp retired_question_states do
    Enum.map(~w(answered dismissed superseded), fn status ->
      record_state(
        "question-#{status}",
        "Question #{status}",
        "The original question remains visible without active controls; the human answer is separate.",
        "input_request",
        %{
          "choices" => ["Roll out to 1%", "Stop the rollout"],
          "question" => "Which rollout action should I take?"
        },
        status
      )
    end)
  end

  defp investigation_records do
    evidence = [
      {"evidence-observed",
       %{
         "claim_id" => "api.health",
         "observation" => "The API probe is ready.",
         "relation" => nil,
         "source_name" => "production probe",
         "source_id" => "https://example.com/probe",
         "source_type" => "monitoring"
       }},
      {"evidence-contradicts",
       %{
         "claim_id" => "api.health",
         "observation" => "The worker probe contradicts overall health.",
         "relation" => "contradicts",
         "source_name" => "worker probe",
         "source_type" => "monitoring"
       }}
    ]

    coverage =
      Enum.map(
        ~w(healthy degraded unhealthy unknown not_applicable),
        &{"coverage-#{slug(&1)}",
         %{
           "claim_ids" => ["api.health"],
           "detail" => "The application layer was sampled.",
           "layer" => "application",
           "observed_at" => "2026-09-04T12:00:00.000000Z",
           "source" => "production probe",
           "status" => &1
         }}
      )

    finding = [
      {"finding-unexplained",
       %{"status" => "unexplained", "what" => "Worker health is not yet known."}},
      {"finding-explained",
       %{
         "cause_evidence" => ["evidence:worker"],
         "status" => "explained",
         "what" => "Worker health failed because the queue is stalled."
       }},
      {"finding-expected",
       %{
         "reason" => "This is an intentional maintenance window.",
         "status" => "expected",
         "what" => "One replica is absent."
       }},
      {"finding-out-of-scope",
       %{
         "reason" => "Owned by the upstream provider.",
         "status" => "out_of_scope",
         "what" => "External DNS control-plane latency."
       }}
    ]

    goal_states =
      Enum.map(
        ~w(ready working waiting completed blocked excluded cancelled),
        &{"goal-#{slug(&1)}", %{"goal_id" => "check-workers", "state" => &1}}
      )

    assessments = [
      {"assessment-confirmed", issue_assessment("confirmed_issue")},
      {"assessment-likely", issue_assessment("likely_issue")},
      {"assessment-not-issue",
       %{"impact" => "No customer impact remains.", "verdict" => "not_issue"}},
      {"assessment-unverified",
       %{
         "impact" => "Workers are not yet verified.",
         "immediate_action" => "Inspect a current worker signal.",
         "verdict" => "unverified"
       }}
    ]

    records =
      Enum.map(evidence, &investigation_state(&1, "evidence")) ++
        Enum.map(coverage, &investigation_state(&1, "coverage")) ++
        Enum.map(finding, &investigation_state(&1, "finding")) ++
        [
          investigation_state(
            {"progress",
             %{"phase" => "verifying", "summary" => "The API is healthy; workers remain."}},
            "progress"
          )
        ] ++
        [
          investigation_state(
            {"goal",
             %{
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
             }},
            "goal"
          )
        ] ++
        Enum.map(goal_states, &investigation_state(&1, "goal_state")) ++
        Enum.map(assessments, &investigation_state(&1, "alert_assessment"))

    confirmed = [
      investigation_state(
        {"evidence-confirmed", elem(hd(evidence), 1)},
        "evidence",
        "confirmed"
      ),
      investigation_state(
        {"coverage-confirmed", elem(hd(coverage), 1)},
        "coverage",
        "confirmed"
      ),
      investigation_state(
        {"finding-confirmed", elem(hd(finding), 1)},
        "finding",
        "confirmed"
      ),
      investigation_state(
        {"progress-confirmed",
         %{"phase" => "verified", "summary" => "The exact progress note was confirmed."}},
        "progress",
        "confirmed"
      ),
      investigation_state(
        {"goal-confirmed",
         %{
           "authority" => "read_only",
           "completion_contract" => "A current worker observation exists.",
           "id" => "check-workers",
           "kind" => "check",
           "requested_outcome" => "Check worker health",
           "required" => true,
           "stage" => "self_review"
         }},
        "goal",
        "confirmed"
      ),
      investigation_state(
        {"goal-state-confirmed", elem(hd(goal_states), 1)},
        "goal_state",
        "confirmed"
      ),
      investigation_state(
        {"assessment-confirmed-record", elem(List.last(assessments), 1)},
        "alert_assessment",
        "confirmed"
      )
    ]

    family(
      "investigation-record",
      "Investigation records",
      "Audit records stay in the episode. Slack shows self-contained prose and concise source links.",
      :message,
      sequence(records ++ confirmed)
    )
  end

  defp ordinary_messages do
    states = [
      state(
        "plain",
        "Plain response",
        "Ordinary model prose without interactive records.",
        %{"message" => "The current deployment is healthy.\n\nNo action is required."},
        %{}
      ),
      state(
        "typed-mentions",
        "Typed mentions",
        "Only host-authorized typed mentions become Slack controls.",
        %{
          "message" => "Thanks [@Bruno](slack-user:U123). Raw <!everyone> stays inert.",
          "records" => [],
          "slack_mentions" => %{
            "broadcasts" => [],
            "channels" => [],
            "user_groups" => [],
            "users" => ["slack-user:U123"],
            "workspace_ref" => "T123"
          }
        },
        %{}
      )
    ]

    family(
      "message",
      "Ordinary messages",
      "Plain replies and host-authorized Slack mentions.",
      :message,
      sequence(states)
    )
  end

  defp app_home do
    states = [
      view_state(
        "restricted",
        "Restricted member",
        "No private operational state is disclosed.",
        AppHome.render(:restricted, %{})
      ),
      view_state(
        "operator-empty",
        "Operator · quiet",
        "No work currently needs attention.",
        AppHome.render(:operator, home_snapshot())
      ),
      view_state(
        "operator-active",
        "Operator · active",
        "Attention, work, incidents, controls, and counts together.",
        AppHome.render(:operator, active_home_snapshot())
      ),
      view_state(
        "memory-review-stale",
        "Stale memory review",
        "Editable stale memory with keep, edit, and forget controls.",
        AppHome.render(:operator, %{
          home_snapshot()
          | memory_review_count: 1,
            memory_reviews: [stale_memory_review()]
        })
      ),
      view_state(
        "memory-review-duplicate",
        "Duplicate memory review",
        "Duplicate memories can remain separate, merge, or be forgotten.",
        AppHome.render(:operator, %{
          home_snapshot()
          | memory_review_count: 1,
            memory_reviews: [duplicate_memory_review()]
        })
      ),
      view_state(
        "collection-page",
        "Complete list · page 2",
        "The whole authorized list a channel card points at, past the five the sections show.",
        AppHome.render(:collection, home_collection())
      ),
      view_state(
        "collection-empty",
        "Complete list · nothing saved",
        "Nothing is saved in the channels this operator shares.",
        AppHome.render(:collection, %{
          home_collection()
          | offset: 0,
            outcome: :empty,
            rows: [],
            total: 0
        })
      ),
      view_state(
        "collection-unavailable",
        "Complete list · could not load",
        "A query that did not run is never reported as an empty list.",
        AppHome.render(:collection, %{
          home_collection()
          | offset: 0,
            outcome: :unavailable,
            rows: [],
            total: 0
        })
      )
    ]

    family(
      "app-home",
      "App Home",
      "Restricted and operator Home views, including actionable memory review.",
      :app_home,
      sequence(states)
    )
  end

  defp app_home_modal do
    {:ok, view} = AppHomeEditor.memory_review_view("memory-review:stale-1", stale_memory_review())

    family(
      "app-home-modal",
      "App Home editor",
      "The exact modal used to edit one stale memory.",
      :modal,
      [view_state("memory-edit", "Edit memory", "Bounded subject and guidance inputs.", view)]
    )
  end

  defp thread_statuses do
    statuses = [
      {:blocked, "", "Admission or execution needs operator attention."},
      {:admitting, "is deciding how to respond...", "Admission owns the input."},
      {:admission_retry, "is waiting to retry admission...", "Admission is durably retrying."},
      {:queued, "is queued...", "The input is accepted and queued."},
      {:delivery, "is preparing the response...", "The accepted result is being delivered."},
      {:working, "is working...", "A model turn owns the episode."},
      {:waiting_for_input, "", "The episode needs human input; native activity is cleared."},
      {:waiting_for_event, "", "The episode awaits an event; native activity is cleared."},
      {:clear, "", "Terminal state clears Slack's assistant status."}
    ]

    if Enum.map(statuses, &elem(&1, 0)) != ThreadStatusProjection.phases(),
      do: raise(ArgumentError, "Card Lab thread statuses do not match the production projection")

    states =
      Enum.map(statuses, fn {phase, status, description} ->
        id = phase |> Atom.to_string() |> slug()

        view_state(
          id,
          humanize(id),
          description,
          %{
            "blocks" => [],
            "status" => status,
            "type" => "thread_status"
          },
          %{thread_phase: phase}
        )
      end)

    family(
      "thread-status",
      "Assistant thread status",
      "Every ephemeral Slack assistant-thread status projection.",
      :thread_status,
      sequence(states)
    )
  end

  defp family(id, title, description, surface, states),
    do: %{description: description, id: id, states: states, surface: surface, title: title}

  defp state(id, label, description, document, covers) do
    rendered =
      case Renderer.render(document) do
        {:ok, rendered} ->
          rendered

        {:error, reason} ->
          raise ArgumentError, "invalid Card Lab fixture #{id}: #{inspect(reason)}"
      end

    %{
      covers: covers,
      description: description,
      id: id,
      label: label,
      rendered: rendered,
      transitions: []
    }
  end

  defp view_state(id, label, description, rendered, covers \\ %{}),
    do: %{
      covers: covers,
      description: description,
      id: id,
      label: label,
      rendered: rendered,
      transitions: []
    }

  defp record_state(id, label, description, kind, payload, status \\ "open", presentation \\ nil) do
    document = render_record(kind, payload, status) |> present(presentation)

    specimen =
      state(id, label, description, document, %{
        record_kind: kind,
        record_state: "#{kind}:#{status}"
      })

    if status == "open" and
         kind in ~w(preference_offer guidance_offer standing_assignment_offer memory_offer schedule_offer automation_change_offer) do
      Map.put(
        specimen,
        :confirmation,
        record_state(
          "#{id}-confirmed",
          "#{label} confirmed",
          "The saved entity keeps its full detail and its exact removal control.",
          kind,
          payload,
          "confirmed",
          %{"entity" => saved_entity(kind, payload)}
        )
      )
    else
      specimen
    end
  end

  # Illustrative saved-entity projections for confirmed specimens. The values
  # are proposed copy over the specimen payload, not harvested history.
  defp saved_entity("schedule_offer", payload) do
    entity(
      "schedule",
      "schedule:018f3ef7-1f62-7ee0-a83c-0c12f21d83e8",
      payload["title"],
      payload["task"],
      [
        ["When", "Daily at 13:00:00 · #{payload["timezone"]}"],
        ["Channel", %{"channel_ref" => "C0BHTRPHXP0"}],
        ["Next run", "05 Sep 2099, 13:00 UTC"],
        ["Expires", "No expiry"],
        ["Missed runs", "Run the latest missed occurrence"],
        ["Access", "Read-only"],
        ["Repository", payload["repository"] || "No fixed binding"]
      ],
      "Schedule saved"
    )
  end

  defp saved_entity("automation_change_offer", payload) do
    entity(
      "schedule",
      payload["automation_id"],
      get_in(payload, ["after", "title"]) || "Daily health check",
      get_in(payload, ["after", "prompt"]) || "Check service health.",
      [
        ["When", "Daily at 13:00:00 · Etc/UTC"],
        ["Channel", %{"channel_ref" => "C0BHTRPHXP0"}],
        ["Expires", "No expiry"],
        ["Missed runs", "Run the latest missed occurrence"],
        ["Access", "Read-only"],
        ["Repository", "No fixed binding"]
      ],
      "Schedule has been updated",
      payload["revision"] + 1
    )
  end

  defp saved_entity("standing_assignment_offer", %{"source_kind" => source_kind} = payload) do
    entity(
      "standing_rule",
      "behavior:018f3ef7-1f62-7ee0-a83c-0c12f21d83e9",
      payload["title"],
      payload["task"],
      [
        ["Channel", %{"channel_ref" => "C0BHTRPHXP0"}],
        ["Source", source_kind],
        ["Event filter", "All #{source_kind} events posted here"],
        ["Repository", payload["repository"] || "No fixed binding"],
        ["Expires", "Until disabled"],
        ["Missed events", "Run the latest missed occurrence"],
        ["Access", "Read-only"]
      ],
      "Standing rule saved"
    )
  end

  defp saved_entity("standing_assignment_offer", payload) do
    entity(
      "standing_rule",
      "behavior:018f3ef7-1f62-7ee0-a83c-0c12f21d83e9",
      payload["trigger"],
      payload["task"],
      [
        ["Trigger", "#{payload["trigger"]} → #{payload["action"]}"],
        ["Source filter", payload["source_filter"]],
        ["Repository", payload["repository"] || "No fixed binding"],
        ["Expires", "Until disabled"],
        ["Access", "Read-only"]
      ],
      "Standing rule saved"
    )
  end

  defp saved_entity("preference_offer", payload) do
    entity(
      "preference",
      "behavior:018f3ef7-1f62-7ee0-a83c-0c12f21d83ea",
      payload["key"],
      "#{payload["key"]} = #{payload["value"]}",
      [
        ["Scope", "Whole workspace"],
        ["Repository", payload["repository"] || "No fixed binding"],
        ["Expires", "27 Oct 2099, 12:00 UTC"]
      ],
      "Preference saved"
    )
  end

  defp saved_entity("guidance_offer", payload) do
    entity(
      "guidance",
      "behavior:018f3ef7-1f62-7ee0-a83c-0c12f21d83eb",
      payload["subject"],
      payload["text"],
      [
        ["Scope", "This conversation"],
        ["Repository", payload["repository"] || "No fixed binding"],
        ["Visibility", "This conversation"],
        ["Expires", "27 Oct 2099, 12:00 UTC"],
        ["Source", %{"channel_ref" => "C0BHTRPHXP0"}]
      ],
      "Guidance saved"
    )
  end

  defp saved_entity("memory_offer", payload) do
    entity(
      "memory",
      "memory:018f3ef7-1f62-7ee0-a83c-0c12f21d83ec",
      payload["subject"],
      payload["value"],
      [
        ["Kind", String.replace(payload["kind"], "_", " ")],
        ["Scope", "Whole workspace"],
        ["Visibility", "Whole workspace"],
        ["Expires", "27 Oct 2099, 12:00 UTC"],
        ["Source", %{"channel_ref" => "C0BHTRPHXP0"}]
      ],
      "Memory saved",
      nil
    )
  end

  defp entity(kind, ref, title, instructions, facts, notice, revision \\ 1) do
    %{
      "facts" => facts,
      "instructions" => instructions,
      "kind" => kind,
      "notice" => notice,
      "ref" => ref,
      "removable" => true,
      "resumable" => false,
      "revision" => revision,
      "saved_at" => "2099-09-04T12:00:00.000000Z",
      "saved_by" => "slack:user:U123",
      "status" => "active",
      "title" => title
    }
  end

  defp publication_state(id, label, payload, status) do
    state(
      id,
      label,
      "Trusted read-only publication verdict.",
      render_record("publication_review", payload, status, "publication:#{id}"),
      %{record_kind: "publication_review", record_state: "publication_review:#{status}"}
    )
  end

  defp investigation_state({id, payload}, kind, status \\ "open"),
    do:
      record_state(
        id,
        humanize(id),
        "Audit-only #{humanize(kind)} record; no raw record dump is appended to Slack.",
        kind,
        payload,
        status,
        source_presentation(kind, payload)
      )

  # The lab authors this resolved link itself. A real reply only gets one when
  # ReplyRecords matches the source against a retained tool receipt.
  defp source_presentation("evidence", %{"source_id" => url}), do: %{"source_url" => url}
  defp source_presentation(_kind, _payload), do: nil

  defp present(document, nil), do: document

  defp present(document, presentation),
    do: update_in(document["records"], &[Map.put(hd(&1), "presentation", presentation)])

  defp render_record(kind, payload, status, ref \\ nil) do
    %{
      "message" => "Current #{humanize(kind)} state.",
      "records" => [
        %{
          "kind" => kind,
          "payload" => payload,
          "ref" => ref || "record:#{kind}:card-lab",
          "status" => status
        }
      ]
    }
  end

  defp sequence(states) do
    states =
      Enum.flat_map(states, fn specimen ->
        case Map.pop(specimen, :confirmation) do
          {nil, specimen} -> [specimen]
          {confirmed, specimen} -> [specimen, confirmed]
        end
      end)

    ids = Enum.map(states, & &1.id)

    states
    |> Enum.with_index()
    |> Enum.map(fn {state, index} ->
      transitions =
        [
          if(index > 0, do: t("previous", "Previous state", Enum.at(ids, index - 1))),
          if(index < length(ids) - 1, do: t("next", "Next state", Enum.at(ids, index + 1)))
        ]
        |> Enum.reject(&is_nil/1)

      %{state | transitions: transitions}
    end)
  end

  defp put_transitions(states, transitions) do
    Enum.map(states, fn state -> %{state | transitions: Map.get(transitions, state.id, [])} end)
  end

  defp insert_after(states, id, inserted) do
    {left, right} = Enum.split_while(states, &(&1.id != id))

    case right do
      [matched | rest] -> left ++ [matched] ++ inserted ++ rest
      [] -> states ++ inserted
    end
  end

  defp t(id, label, to), do: %{id: id, label: label, to: to}

  defp task_document(status, publication \\ nil) do
    action_needed =
      if status == "action_required",
        do: "Review the current blocker and choose a recovery path.",
        else: nil

    controls =
      if status in ~w(completed cancelled stopping),
        do: ["timeline", "evidence", "handoff"],
        else: ["stop", "view_diff", "close", "timeline", "evidence", "handoff"]

    %{
      "task_card" => %{
        "action_needed" => action_needed,
        "confirmed_at" => "2026-09-04T12:00:00.000000Z",
        "confirmed_by" => "slack:user:U123",
        "controls" => controls,
        "episode_state" => task_episode_state(status),
        "publication" => publication,
        "repository" => "responder",
        "repository_url" => publication && "https://github.com/acme/responder",
        "session_generation" => 2,
        "stages" => task_stages(status, publication),
        "status" => status,
        "summary" => task_description(status),
        "task_ref" => "task-card:card-lab-123",
        "title" => "Fix parser retries",
        "ui_revision" => 7,
        "updated_at" => "2026-09-04T12:04:00.000000Z",
        "work_state" => task_work_state(status)
      }
    }
  end

  # Specimen ledgers: one per supported status, so the catalog exercises every
  # disposition the production projection can produce.
  defp task_stages(status, publication) do
    states = task_stage_states(status, publication)

    details = %{
      "implementation" => "2/4 subtasks",
      "draft_pr" => draft_detail(status, publication),
      "ci" => if(status == "published", do: "waiting for GitHub")
    }

    TaskStages.stages()
    |> Enum.zip(states)
    |> Enum.map(fn {stage, state} ->
      %{
        "current" => state in ~w(running waiting failed),
        "detail" => details[stage],
        "stage" => stage,
        "state" => state,
        "subtasks" => task_subtasks(stage, state),
        "subtasks_total" => if(stage == "implementation", do: 4),
        "url" => stage == "draft_pr" && publication["pull_request_url"],
        "your_turn" => stage == "review_and_merge" and state == "waiting"
      }
      |> Map.update!("url", fn url -> url || nil end)
    end)
    |> current_only()
  end

  # A blocked-recovery ledger is not one of the per-status shapes: it puts the
  # cause on the stage that owns it and leaves the stages that did run alone.
  defp specimen_stages(states, details, publication) do
    TaskStages.stages()
    |> Enum.zip(states)
    |> Enum.map(fn {stage, state} ->
      %{
        "current" => state in ~w(running waiting failed),
        "detail" => details[stage],
        "stage" => stage,
        "state" => state,
        "subtasks" => [],
        "subtasks_total" => nil,
        "url" => (stage == "draft_pr" && publication && publication["pull_request_url"]) || nil,
        "your_turn" => false
      }
    end)
    |> current_only()
  end

  defp task_stage_states("action_required", %{"status" => "blocked"}),
    do: ~w(completed completed completed completed failed pending pending)

  # Nothing has run yet: the workspace is still waiting for a worker, so no
  # stage may claim completion.
  defp task_stage_states("queued", _publication),
    do: ~w(waiting pending pending pending pending pending pending)

  defp task_stage_states("working", _publication),
    do: ~w(completed completed running pending pending pending pending)

  defp task_stage_states("waiting_for_input", _publication),
    do: ~w(completed completed waiting pending pending pending pending)

  defp task_stage_states("waiting_for_event", _publication),
    do: ~w(completed completed waiting pending pending pending pending)

  defp task_stage_states("action_required", _publication),
    do: ~w(completed completed failed pending pending pending pending)

  defp task_stage_states("stopping", _publication),
    do: ~w(completed completed running pending pending pending pending)

  defp task_stage_states("reviewing", _publication),
    do: ~w(completed completed completed running pending pending pending)

  defp task_stage_states("ready_to_publish", _publication),
    do: ~w(completed completed completed completed waiting pending pending)

  defp task_stage_states("published", _publication),
    do: ~w(completed completed completed completed completed waiting pending)

  defp task_stage_states("completed", _publication),
    do: ~w(completed completed completed completed unknown pending pending)

  defp task_stage_states("cancelled", _publication),
    do: ~w(completed completed stopped pending pending pending pending)

  defp draft_detail("completed", _publication), do: "not recorded"

  defp draft_detail(_status, %{"pull_request_number" => number}) when is_integer(number),
    do: "##{number}"

  defp draft_detail(_status, _publication), do: nil

  defp task_subtasks("implementation", state) when state in ~w(running waiting failed) do
    [
      %{
        "current" => false,
        "detail" => nil,
        "id" => "parse-retry-budget",
        "outcome" => "Read the retry budget from configuration",
        "state" => "completed"
      },
      %{
        "current" => true,
        "detail" => if(state == "waiting", do: "waiting for the retry-budget answer"),
        "id" => "retry-backoff",
        "outcome" => "Back off between parser retries",
        "state" => %{"running" => "working", "waiting" => "waiting", "failed" => "blocked"}[state]
      }
    ]
  end

  defp task_subtasks(_stage, _state), do: []

  # One current stage, and subtasks only beneath it, exactly as the production
  # projection emits them.
  defp current_only(rows) do
    first = Enum.find_index(rows, & &1["current"])

    rows
    |> Enum.with_index()
    |> Enum.map(fn {row, index} ->
      if index == first,
        do: %{row | "current" => true},
        else: %{row | "current" => false, "subtasks" => [], "subtasks_total" => nil}
    end)
  end

  defp publication(status, controls, generation \\ 1, published \\ false, unverified \\ nil) do
    %{
      "branch" => "refs/heads/responder/card-lab",
      "controls" => controls,
      "publication_ref" => "publication:card-lab",
      "pull_request_number" => if(published, do: 91, else: nil),
      "pull_request_url" =>
        if(published, do: "https://github.com/acme/responder/pull/91", else: nil),
      "recovery_generation" => generation,
      "status" => status,
      "unverified" => unverified
    }
  end

  defp task_episode_state(status) when status in ~w(completed), do: "complete"
  defp task_episode_state(status) when status in ~w(cancelled), do: "cancelled"

  defp task_episode_state(status) when status in ~w(waiting_for_input waiting_for_event),
    do: status

  defp task_episode_state(_status), do: "working"

  defp task_work_state(status)
       when status in ~w(completed cancelled published ready_to_publish),
       do: "settled"

  defp task_work_state("action_required"), do: "blocked"
  defp task_work_state(_status), do: "pending"

  defp task_description("queued"),
    do: "The task is confirmed and waiting for a worker; nothing is running yet."

  defp task_description("working"), do: "The parser fix is running focused validation."

  defp task_description("waiting_for_input"),
    do: "One exact operator decision is required before work can continue."

  defp task_description("waiting_for_event"),
    do: "Work is waiting for an external verification event."

  defp task_description("action_required"),
    do: "The current attempt is blocked and needs a bounded recovery decision."

  defp task_description("stopping"),
    do: "The active run is being cancelled while custody remains durable."

  defp task_description("reviewing"),
    do: "The committed candidate is in a trusted read-only review."

  defp task_description("ready_to_publish"),
    do: "The reviewed candidate is ready for operator publication."

  defp task_description("published"),
    do: "The reviewed change is available as a draft pull request."

  defp task_description("completed"),
    do: "The requested outcome and its verification contract are complete."

  defp task_description("cancelled"),
    do: "The task is closed; its durable history remains available."

  defp incident_document(status) do
    %{
      "incident_room" => %{
        "action_needed" =>
          if(status in ~w(action_required waiting_for_input),
            do: "Review the current blocker.",
            else: nil
          ),
        "alert" => %{
          "impact" => "Checkout traffic is affected.",
          "verdict" => if(status == "resolved", do: "not_issue", else: "confirmed_issue")
        },
        "controls" =>
          if(status in ~w(resolved cancelled),
            do: ["timeline", "evidence", "handoff", "postmortem"],
            else: ["stop", "view_diff", "close", "timeline", "evidence", "handoff", "postmortem"]
          ),
        "episode_state" => incident_episode_state(status),
        "goals" => [
          %{
            "id" => "confirm-scope",
            "outcome" => "Confirm which service is affected",
            "state" => "completed"
          },
          %{"id" => "find-cause", "outcome" => "Establish the cause", "state" => "working"}
        ],
        "opened_at" => "2026-09-04T11:45:00.000000Z",
        "opened_by" => "slack:user:U123",
        "repository" => "responder",
        "room_ref" => "incident-room:82208f8f-2ef4-4f1b-a011-626aabdc9342",
        "session_generation" => 2,
        "severity" => "high",
        "signals" => %{"firing" => if(status == "resolved", do: 0, else: 2), "total" => 3},
        "source" => %{
          "channel_ref" => "C123",
          "message_ref" => "1787832000.000100",
          "thread_ref" => "1787832000.000100"
        },
        "status" => status,
        "summary" => incident_description(status),
        "title" => "Checkout errors",
        "ui_revision" => 9,
        "updated_at" => "2026-09-04T12:04:00.000000Z"
      }
    }
  end

  defp incident_episode_state(status) when status in ~w(resolved), do: "complete"
  defp incident_episode_state(status) when status in ~w(cancelled), do: "cancelled"

  defp incident_episode_state(status) when status in ~w(waiting_for_input waiting_for_event),
    do: status

  defp incident_episode_state(_status), do: "working"

  defp incident_description("provisioning"), do: "The private incident room is being provisioned."

  defp incident_description("investigating"),
    do: "Current signals are being correlated across the service path."

  defp incident_description("action_required"), do: "A bounded operator action is required."

  defp incident_description("waiting_for_input"),
    do: "The investigation needs one operator decision."

  defp incident_description("waiting_for_event"),
    do: "The incident is waiting for current verification."

  defp incident_description("stopping"), do: "The active investigation turn is stopping."

  defp incident_description("resolved"),
    do: "Recovery has been verified and the incident is resolved."

  defp incident_description("cancelled"),
    do: "The incident was closed without deleting its history."

  defp incident_description("paused"),
    do: "The Slack room is inactive; durable incident state remains."

  defp setup_document(status, step) do
    draft = %{
      "alert_policy" => "offer",
      "default_repository" => "responder",
      "invite_user_group_refs" => [],
      "invite_user_refs" => ["U123"],
      "participation" => "proactive",
      "repository_options" => [
        "responder",
        "emisar",
        "responder-infra",
        "runbooks",
        "frontend",
        "platform"
      ],
      "repository_ref" => "responder"
    }

    %{
      "channel_setup" => %{
        "bot_user_ref" => "UCARDLAB",
        "draft" => draft,
        "expires_at" => "2099-09-04T12:30:00.000000Z",
        "on_call_count" => 2,
        "revision" => 1,
        "session_ref" => "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
        "status" => status,
        "step" => step
      }
    }
  end

  defp approval_status(status, error) do
    %{
      "review" => nil,
      "action_id" => "nomad.alloc_restart",
      "approval_url" => "https://emisar.example/app/acme/approvals/apr-card-lab",
      "expires_at" => "2099-09-04T12:30:00.000000Z",
      "operation_id" => "op-card-lab",
      "pack_ref" => "nomad@1#sha256:abc",
      "remote_error" => error,
      "request_id" => "apr-card-lab",
      "run_id" => "run-card-lab",
      "run_url" => "https://emisar.example/app/acme/runs/run-card-lab",
      "runner_ref" => "production-runner",
      "status" => status
    }
  end

  defp approval_record do
    approval_status("pending_approval", nil)
    |> Map.drop(["remote_error", "review", "run_url"])
  end

  defp automation_document(status, revision),
    do: %{
      "automation_id" => "schedule:daily-health",
      "catch_up" => "latest",
      "context_channel" => "slack:T123:C456",
      "delivery_channel" => "slack:T123:C456",
      "expires_at" => nil,
      "next_occurrence_at" => "2099-09-05T13:00:00.000000Z",
      "prompt" => "Inspect current service health.",
      "repository" => nil,
      "revision" => revision,
      "status" => status,
      "title" => "Daily service health",
      "trigger" => %{
        "recurrence" => "daily",
        "time" => "13:00:00",
        "timezone" => "Etc/UTC",
        "type" => "time"
      }
    }

  defp issue_assessment(verdict),
    do: %{
      "cause" => "The worker queue is stalled.",
      "cause_claim_ids" => ["worker.queue"],
      "cause_status" => "identified",
      "evidence_refs" => ["record:evidence:worker"],
      "impact" => "Checkout processing is delayed.",
      "immediate_action" => "Drain the stalled worker.",
      "long_term_solution" => "Add a queue-age SLO.",
      "verification" => "Observe queue age below 30 seconds.",
      "verdict" => verdict
    }

  defp home_snapshot do
    %{
      behaviors: [],
      counts: %{},
      incidents: [],
      memories: [],
      memory_review_count: 0,
      memory_reviews: [],
      needs_attention: [],
      schedules: [],
      work: []
    }
  end

  defp home_collection do
    titles = [
      "Daily deploy readiness",
      "Weekly capacity review",
      "Nightly backup verification",
      "Monday release notes",
      "Quarterly access review",
      "Disk growth follow-up",
      "Certificate expiry sweep",
      "Staging data refresh",
      "On-call handover summary",
      "Month-end cost report"
    ]

    %{
      kind: :schedules,
      offset: 10,
      outcome: :listed,
      page_size: 10,
      rows:
        titles
        |> Enum.with_index(11)
        |> Enum.map(fn {title, index} ->
          %{
            detail: if(index == 14, do: "Schedule paused", else: "Schedule active"),
            ref: "schedule:#{index}",
            title: title,
            url: "https://slack.com/app_redirect?channel=C123"
          }
        end),
      total: 27
    }
  end

  defp active_home_snapshot do
    %{
      home_snapshot()
      | behaviors: [
          %{
            kind: :guidance,
            ref: "behavior:1",
            revision: 3,
            status: :active,
            subject: "Production reviews",
            url: "https://slack.com/app_redirect?channel=C123"
          }
        ],
        counts: %{
          active_behaviors: 1,
          active_commitments: 2,
          active_memory: 1,
          active_schedules: 1,
          blocked_work: 1,
          incident_history: 4,
          open_incidents: 1,
          published_work: 2,
          retained_workspaces: 1
        },
        incidents: [
          %{
            ref: "incident-room:card-lab",
            status: :investigating,
            title: "Checkout errors",
            url: "https://slack.com/app_redirect?channel=CINCIDENT"
          }
        ],
        memories: [
          %{
            kind: :repository_binding,
            ref: "memory:1",
            subject: "Primary repository",
            url: "https://slack.com/app_redirect?channel=C123"
          }
        ],
        needs_attention: [
          %{
            controls: ["retry", "discard"],
            kind: :publication,
            recovery_generation: 2,
            ref: "publication:card-lab",
            title: "Publication needs review",
            url: "https://slack.com/app_redirect?channel=C123"
          }
        ],
        schedules: [
          %{
            next_occurrence_at: ~U[2099-09-05 09:00:00Z],
            ref: "schedule:1",
            revision: 2,
            status: :active,
            title: "Daily health",
            url: "https://slack.com/app_redirect?channel=C123"
          }
        ],
        work: [
          %{
            next_action: :continue_work,
            ref: "task-card:card-lab",
            state: :working,
            title: "Fix parser retries",
            url: "https://slack.com/app_redirect?channel=C123"
          }
        ]
    }
  end

  defp stale_memory_review do
    %{
      "entries" => [
        %{
          "memory_ref" => "memory:stale",
          "scope" => "workspace",
          "scope_ref" => "T123",
          "subject" => "primary_repository",
          "url" => "https://slack.com/app_redirect?channel=C123",
          "value" => "responder",
          "visibility" => "workspace"
        }
      ],
      "kind" => "stale",
      "reason" => "This mapping has not been confirmed recently.",
      "review_ref" => "memory-review:stale-1"
    }
  end

  defp duplicate_memory_review do
    %{
      "entries" => [
        %{
          "memory_ref" => "memory:duplicate-1",
          "scope" => "workspace",
          "scope_ref" => "T123",
          "subject" => "primary_repository",
          "url" => "https://slack.com/app_redirect?channel=C123",
          "value" => "responder",
          "visibility" => "workspace"
        },
        %{
          "memory_ref" => "memory:duplicate-2",
          "scope" => "workspace",
          "scope_ref" => "T123",
          "subject" => "primary_repo",
          "url" => "https://slack.com/app_redirect?channel=C123",
          "value" => "responder",
          "visibility" => "workspace"
        }
      ],
      "kind" => "duplicate",
      "reason" => "These entries describe the same mapping.",
      "review_ref" => "memory-review:duplicate-1"
    }
  end

  defp slug(value), do: String.replace(value, "_", "-")

  defp humanize(value),
    do: value |> to_string() |> String.replace(["_", "-"], " ") |> String.capitalize()
end
