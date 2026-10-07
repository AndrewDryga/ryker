defmodule Ryker.Settings.RetentionImpact do
  @moduledoc """
  Bounded estimates of what a shorter horizon would newly expose to cleanup.

  Each count is of rows older than the proposed limit but not the current one:
  rows the current limit already lets go are deleted whatever the change. The
  rules are the ones `Ryker.Retention.Data` deletes by, named the way the
  console shows them, without the custody pins pruning also checks, so a count
  can include a row something still holds. Ages use PostgreSQL time.
  """
  alias Ryker.Repo

  # Each label counts one or more sources: {from, age column, condition}.
  @rules %{
    operational_data_seconds: [
      {"received messages",
       [{"ingress_inbox_entries", "updated_at", "operational_pruned_at IS NULL"}]},
      {"model and tool steps",
       [{"episode_work_turns", "updated_at", "operational_pruned_at IS NULL"}]}
    ],
    conversation_memory_seconds: [
      {"memory entries",
       [
         {"operational_memory_entries", "updated_at",
          "scope_kind <> 'global' OR status <> 'active'"}
       ]},
      {"conversation topics", [{"conversation_knowledge", "updated_at", "true"}]}
    ],
    closed_work_seconds: [
      {"closed incident rooms", [{"slack_incident_rooms", "updated_at", "status = 'closed'"}]},
      {"task cards",
       [
         {"slack_task_cards AS card JOIN episode_kernel_episodes AS episode " <>
            "ON episode.id = card.episode_id", "card.updated_at",
          "episode.state IN ('complete', 'cancelled')"}
       ]}
    ],
    episode_history_seconds: [
      {"finished requests",
       [
         {"episode_kernel_episodes", "updated_at",
          "state IN ('complete', 'cancelled') AND history_pruned_at IS NULL"}
       ]}
    ],
    audit_data_seconds: [
      {"finished requests",
       [{"episode_kernel_episodes", "updated_at", "history_pruned_at IS NOT NULL"}]},
      {"settings and credential changes",
       [
         {"settings_edits", "inserted_at", "true"},
         {"integration_credential_events", "inserted_at", "true"},
         {"model_instruction_edits", "inserted_at", "true"},
         {"slack_channel_setting_audit", "inserted_at", "true"}
       ]},
      {"failures people left", [{"failure_dismissals", "left_at", "true"}]},
      {"Slack button presses",
       [
         {"slack_interaction_audit", "inserted_at",
          "repaint_status IN ('none', 'settled', 'blocked')"}
       ]},
      {"channel joins and leaves", [{"slack_channel_membership_events", "inserted_at", "true"}]},
      {"operator actions",
       [
         {"ryker_operator_actions", "inserted_at", "true"},
         {"retention_operator_actions", "inserted_at", "true"}
       ]},
      {"settled memory reviews", [{"memory_review_items", "updated_at", "status <> 'pending'"}]}
    ],
    routing_examples_seconds: [
      {"routing examples", [{"routing_examples", "decided_at", "forgotten_at IS NULL"}]},
      {"accepted eval cases", [{"improvement_candidates", "decided_at", "status = 'accepted'"}]}
    ],
    work_examples_seconds: [
      {"work examples", [{"work_examples", "settled_at", "forgotten_at IS NULL"}]}
    ]
  }

  # Turning off keeping routing or work examples deletes every one kept.
  @all_examples %{
    routing_examples: "SELECT count(*) FROM routing_examples WHERE forgotten_at IS NULL",
    work_examples: "SELECT count(*) FROM work_examples WHERE forgotten_at IS NULL"
  }

  @spec estimate(map(), map()) :: %{atom() => [%{label: String.t(), count: non_neg_integer()}]}
  def estimate(current, proposed) do
    shorter =
      @rules
      |> Enum.filter(fn {field, _rules} ->
        Map.fetch!(proposed, field) < Map.fetch!(current, field)
      end)
      |> Map.new(fn {field, rules} ->
        window = [Map.fetch!(proposed, field), Map.fetch!(current, field)]
        {field, Enum.map(rules, fn {label, sources} -> count(label, sources, window) end)}
      end)

    shorter
    |> turned_off(current, proposed, :routing_examples, "routing examples")
    |> turned_off(current, proposed, :work_examples, "work examples")
  end

  # Table names and conditions come from the literals above, never from data.
  defp count(label, sources, window) do
    sql =
      "SELECT " <>
        Enum.map_join(sources, " + ", fn {from, age, condition} ->
          "(SELECT count(*) FROM #{from} WHERE (#{condition}) " <>
            "AND #{age} < clock_timestamp() - ($1 * interval '1 second') " <>
            "AND #{age} >= clock_timestamp() - ($2 * interval '1 second'))"
        end)

    %{rows: [[count]]} = Repo.query!(sql, window, log: false)
    %{label: label, count: count}
  end

  defp turned_off(shorter, current, proposed, kind, label) do
    {enabled, seconds} = example_fields(kind)

    if Map.fetch!(current, enabled) and not Map.fetch!(proposed, enabled) do
      %{rows: [[count]]} = Repo.query!(Map.fetch!(@all_examples, kind), [], log: false)

      shorter
      |> Map.delete(seconds)
      |> Map.put(enabled, [%{label: label, count: count} | also_deleted(kind, proposed)])
    else
      shorter
    end
  end

  # The switch and the window of each kind of example.
  defp example_fields(:routing_examples),
    do: {:routing_examples_enabled, :routing_examples_seconds}

  defp example_fields(:work_examples), do: {:work_examples_enabled, :work_examples_seconds}

  # An accepted eval case is kept over the routing examples window only while
  # they are kept; with them off it ages at the prompts limit, and the question
  # counted routing examples alone (2026-10-04 review).
  defp also_deleted(:routing_examples, proposed) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM improvement_candidates WHERE status = 'accepted' " <>
          "AND decided_at < clock_timestamp() - ($1 * interval '1 second')",
        [Map.fetch!(proposed, :operational_data_seconds)],
        log: false
      )

    [%{label: "accepted eval cases", count: count}]
  end

  defp also_deleted(_kind, _proposed), do: []
end
