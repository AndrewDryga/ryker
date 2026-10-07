defmodule Ryker.Behaviors.Recall do
  @moduledoc """
  Reading confirmed behavior for a model: the preferences, guidance and
  standing assignments one turn is given, and the guidance a memory search
  reaches. A live read counts a use of the guidance it returns; a shadow turn
  reads the same and counts nothing.

  `Ryker.Behaviors` is the context's public boundary and forwards here.
  """
  alias Ryker.Behaviors
  alias Ryker.Behaviors.Behavior
  alias Ryker.Behaviors.StandingAssignmentRun
  alias Ryker.Episodes.Episode
  alias Ryker.Episodes.Scope
  alias Ryker.Memories.MemorySearchPage
  alias Ryker.Memories.MemorySourceLink
  alias Ryker.Memories.SearchPage
  alias Ryker.Reference
  alias Ryker.Repo

  @doc "Returns the bounded confirmed behavior context for one exact episode turn."
  @spec model_context(Episode.t(), String.t(), String.t() | nil) :: map()
  def model_context(%Episode{} = episode, operator_ref, repository)
      when is_binary(operator_ref) and (is_binary(repository) or is_nil(repository)) do
    context = %{
      conversation_ref: episode.destination_conversation_ref,
      execution_mode: episode.execution_mode,
      operator_ref: operator_ref,
      repository: repository,
      workspace_ref: Scope.workspace_ref(episode)
    }

    %{
      "guidance" => guidance(context),
      "preferences" => effective_preferences(context),
      "standing_assignments" => assignment_context(episode.id)
    }
  end

  def model_context(_episode, _operator_ref, _repository),
    do: %{"guidance" => [], "preferences" => %{}, "standing_assignments" => []}

  @spec guidance(map(), pos_integer()) :: [map()]
  def guidance(context, limit \\ 20)

  def guidance(context, limit) when is_map(context) and is_integer(limit) and limit in 1..50 do
    case retrieval_context(context) do
      {:ok, context} -> guidance_context(context, limit)
      {:error, _reason} -> []
    end
  end

  def guidance(_context, _limit), do: []

  @doc false
  def search_page(context, page) do
    case retrieval_context(context) do
      {:ok, context} -> search_visible_page(context, page)
      _ -> :done
    end
  end

  defp effective_preferences(context) do
    case retrieval_context(context) do
      {:ok, context} -> preference_context(context)
      {:error, _reason} -> %{}
    end
  end

  defp preference_context(context) do
    active_for_context(:preference, context)
    |> Enum.sort_by(&preference_rank/1)
    |> Enum.reduce(%{}, fn behavior, preferences ->
      Map.put_new(preferences, behavior.payload["key"], %{
        "behavior_ref" => behavior.ref,
        "scope" => Atom.to_string(behavior.scope_kind),
        "value" => behavior.payload["value"]
      })
    end)
  end

  defp guidance_context(context, limit) do
    active_for_context(:guidance, context)
    |> Enum.sort_by(&{preference_rank(&1), DateTime.to_unix(&1.updated_at, :microsecond) * -1})
    |> Enum.take(limit)
    |> account_guidance(context)
  end

  defp account_guidance([], _context), do: []

  defp account_guidance(behaviors, context) do
    current =
      Behavior.Query.unchanged(behaviors)
      |> Behavior.Query.by_status(:active)
      |> Behavior.Query.unexpired()
      |> Behavior.Query.select_ids()

    retained = current |> charge_use(context) |> MapSet.new()
    behaviors |> Enum.filter(&MapSet.member?(retained, &1.id)) |> Enum.map(&guidance_document/1)
  end

  # A shadow turn reads what a live one would and counts no use: its reads kept
  # stale guidance out of the review queue (2026-10-04 review).
  defp charge_use(current, %{execution_mode: :shadow}), do: Repo.all(current)

  defp charge_use(current, _context) do
    {_count, ids} =
      Repo.update_all(current, inc: [use_count: 1], set: [last_used_at: Repo.now!()])

    # One announcement for the guidance a turn uses, which a page redraws for
    # once: it sent one per row (2026-10-04 review).
    with [id | _rest] <- ids, do: Behaviors.broadcast_behavior_updated(id)
    ids
  end

  defp guidance_document(behavior) do
    %{
      "behavior_ref" => behavior.ref,
      "confirmed_at" => DateTime.to_iso8601(behavior.confirmed_at),
      "expires_at" => if(behavior.expires_at, do: DateTime.to_iso8601(behavior.expires_at)),
      "source_read" =>
        MemorySourceLink.message(
          behavior.source_transport,
          behavior.source_conversation_ref,
          behavior.source_message_ref,
          behavior.source_thread_ref
        ),
      "kind" => "guidance",
      "scope" => Atom.to_string(behavior.scope_kind),
      "subject" => behavior.payload["subject"],
      "summary" => behavior.payload["summary"],
      "text" => behavior.payload["text"],
      "visibility" => behavior.payload["visibility"]
    }
    |> put_edit_provenance(behavior)
  end

  defp put_edit_provenance(document, %Behavior{edited_at: %DateTime{} = edited_at} = behavior) do
    Map.put(document, "edit", %{
      "actor_ref" => behavior.edited_by_actor_ref,
      "edited_at" => DateTime.to_iso8601(edited_at),
      "review_ref" => behavior.edit_review_ref
    })
  end

  defp put_edit_provenance(document, _behavior), do: document

  defp search_visible_page(context, page) do
    fields = Behavior.Query.search_fields()

    Behavior.Query.by_workspace(context.workspace_ref)
    |> Behavior.Query.by_kind(:guidance)
    |> Behavior.Query.by_status(:active)
    |> Behavior.Query.unexpired()
    |> Behavior.Query.in_search_scope(context, page.scope)
    |> Behavior.Query.visible_to(:guidance, context)
    |> SearchPage.Query.related_originals(
      page,
      fields.conversation,
      fields.thread,
      fields.message
    )
    |> MemorySearchPage.one(page, fields.text, fields.changed, fields.source)
    |> account_search_result(context)
  end

  defp account_search_result({:ok, behavior, position}, context) do
    case account_guidance([behavior], context) do
      [document] -> {:ok, document, position}
      [] -> {:skip, position}
    end
  end

  defp account_search_result(:done, _context), do: :done

  defp active_for_context(kind, context) do
    now = Repo.now!()

    Behavior.Query.by_kind(kind)
    |> Behavior.Query.by_status(:active)
    |> Behavior.Query.by_workspace(context.workspace_ref)
    |> Behavior.Query.unexpired_at(now)
    |> Behavior.Query.by_any_scope(context_clauses(context))
    |> Behavior.Query.visible_to(kind, context)
    |> Behavior.Query.ordered_by_scope_precedence()
    |> Behavior.Query.limit_to(100)
    |> Repo.all()
  end

  defp assignment_context(episode_id) do
    episode_id
    |> StandingAssignmentRun.Query.decided_for_episode()
    |> Repo.all()
    |> Enum.reverse()
    |> Enum.map(fn {_run, behavior} ->
      %{
        "action" => "run_source_event_automation",
        "allowed_outputs" => ["ignore", "react", "reply"],
        "assignment_ref" => behavior.ref,
        "authority_ceiling" => "read_only",
        "repository" => behavior.payload["repository"],
        "task" => behavior.payload["task"],
        "trigger" => %{
          "filter" => behavior.payload["filter"],
          "source_kind" => behavior.payload["source_kind"]
        }
      }
    end)
  end

  defp context_clauses(context) do
    [
      {:workspace, context.workspace_ref},
      {:conversation, context.conversation_ref},
      {:operator, context.operator_ref}
    ]
    |> maybe_repository(context.repository)
    |> Enum.reject(fn {_kind, ref} -> is_nil(ref) end)
  end

  defp maybe_repository(clauses, nil), do: clauses
  defp maybe_repository(clauses, repository), do: [{:repository, repository} | clauses]

  defp preference_rank(%Behavior{scope_kind: :operator}), do: 0
  defp preference_rank(%Behavior{scope_kind: :conversation}), do: 1
  defp preference_rank(%Behavior{scope_kind: :repository}), do: 2
  defp preference_rank(%Behavior{scope_kind: :workspace}), do: 3

  # A turn with no active message has no operator; it found no guidance at
  # all, the workspace's included (2026-10-04 review).
  defp retrieval_context(context) do
    fields = [:conversation_ref, :operator_ref, :repository, :workspace_ref]

    if Map.get(context, :execution_mode, :live) in [:live, :shadow] and
         (Map.keys(context) -- [:execution_mode]) |> Enum.sort() == Enum.sort(fields) and
         Enum.all?([:conversation_ref, :workspace_ref], &Reference.valid?(context[&1])) and
         Enum.all?([:operator_ref, :repository], &optional_reference?(context[&1])) do
      {:ok, context}
    else
      {:error, :invalid_behavior_context}
    end
  end

  defp optional_reference?(value), do: is_nil(value) or Reference.valid?(value)
end
