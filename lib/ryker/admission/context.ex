defmodule Ryker.Admission.Context do
  @moduledoc """
  Frozen input and bounded candidate set supplied to one model decision.
  """

  alias Ryker.Admission.Candidate
  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Ingress.Input

  @enforce_keys [
    :active_episode_fingerprint,
    :built_at,
    :candidates,
    :conversation_episode_count,
    :input,
    :input_entry
  ]
  defstruct @enforce_keys ++
              [
                observations: [],
                knowledge: [],
                knowledge_omissions: [],
                source_dependencies: nil,
                slack_addressing: nil,
                custom_instructions: nil,
                conversation_context: nil,
                context_manifest: nil,
                routing_receipt: nil,
                continuation_window: nil,
                fitted?: false
              ]

  @type t :: %__MODULE__{
          active_episode_fingerprint: String.t(),
          built_at: DateTime.t(),
          candidates: [Candidate.t()],
          conversation_episode_count: non_neg_integer(),
          input: Input.t(),
          input_entry: Entry.t()
        }

  # What the router reads. The frozen snapshot keeps each document's full
  # provenance; routing reads who said what and when, so where a message can
  # be re-read, its revision and retention, the manifest's byte count and the
  # summary status both the bundle and the manifest carried stay out of it.
  @spec for_model(t()) :: map()
  def for_model(%__MODULE__{} = context) do
    %{
      "allowed_actions" => Enum.map(Input.allowed_actions(context.input), &Atom.to_string/1),
      "candidates" => Enum.map(context.candidates, &Candidate.for_model/1),
      "input" => Input.model_document(context.input)
    }
    |> put_model_conversation(context.conversation_context, context.context_manifest)
    |> put_observations(model_observations(context.observations, context.conversation_context))
    |> put_knowledge(context.knowledge)
    |> put_slack_addressing(context.slack_addressing)
    |> put_model_custom_instructions(context.custom_instructions)
    |> put_repository_source_kinds(context.input_entry.repository_ref)
  end

  @doc "Whether the operator saved any instruction text for this request."
  @spec custom_instructions?(t()) :: boolean()
  def custom_instructions?(%__MODULE__{custom_instructions: snapshot}),
    do: instruction_text?(snapshot)

  defp instruction_text?(%{} = snapshot) do
    Enum.any?(~w(global channel), fn scope ->
      match?(%{"text" => text} when is_binary(text) and text != "", snapshot[scope])
    end)
  end

  defp instruction_text?(_snapshot), do: false

  # A routing session answers one message, so an empty snapshot has no earlier
  # instruction to clear; it is left out with the paragraph that explains it.
  defp put_model_custom_instructions(document, snapshot) do
    if instruction_text?(snapshot),
      do: Map.put(document, "custom_instructions", snapshot),
      else: document
  end

  defp put_model_conversation(document, nil, _manifest), do: document

  defp put_model_conversation(document, bundle, manifest) do
    document
    |> Map.put("conversation_context", model_bundle(bundle))
    |> Map.put("context_manifest", model_manifest(manifest))
  end

  # The current message is the input document itself; a null summary says the
  # same thing its absence does.
  defp model_bundle(bundle) when is_map(bundle) do
    bundle
    |> Map.delete("current")
    |> Map.update(
      "messages",
      [],
      &Enum.map(List.wrap(&1), fn message -> model_message(message) end)
    )
    |> Map.update("root", nil, &model_message/1)
    |> Map.reject(fn {_key, value} -> value in [nil, []] end)
  end

  defp model_bundle(_bundle), do: %{}

  defp model_message(%{} = message) do
    %{
      "actor" => message["actor_ref"],
      "at" => Candidate.model_time(message["occurred_at"]),
      "text" => message |> get_in(["content", "text"]) |> Candidate.model_text()
    }
  end

  defp model_message(_message), do: nil

  @manifest_fields ~w(cutoff included narrowed range requested root)
  # A message outside a thread has no root to report; the frozen manifest
  # still records that it did not apply.
  defp model_manifest(%{} = manifest) do
    manifest
    |> Map.take(@manifest_fields)
    |> Map.reject(&(&1 == {"root", "not_applicable"}))
    |> Map.update("cutoff", nil, &Candidate.model_time/1)
    |> Map.update("range", nil, fn
      %{} = range -> Map.new(range, fn {key, at} -> {key, Candidate.model_time(at)} end)
      range -> range
    end)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp model_manifest(_manifest), do: nil

  # Notes about messages the router already reads verbatim add nothing; the
  # rest keep who, when and what, and their topics when there are any.
  defp model_observations(notes, bundle) do
    supplied =
      [bundle && bundle["root"] | List.wrap(bundle && bundle["messages"])]
      |> Enum.flat_map(fn
        %{"source_message_ref" => ref} when is_binary(ref) -> [ref]
        _message -> []
      end)
      |> MapSet.new()

    notes
    |> Enum.reject(&MapSet.member?(supplied, &1["source_message_ref"]))
    |> Enum.map(fn note ->
      %{
        "actor" => note["actor_ref"],
        "at" => Candidate.model_time(note["occurred_at"]),
        "summary" => Candidate.model_text(note["summary"]),
        "topics" => note["topics"]
      }
      |> Map.reject(fn {_key, value} -> value in [nil, []] end)
    end)
  end

  @doc false
  @spec snapshot(t()) :: map()
  def snapshot(%__MODULE__{} = context) do
    %{
      "active_episode_fingerprint" => context.active_episode_fingerprint,
      "built_at" => DateTime.to_iso8601(context.built_at),
      "continuation_window" => context.continuation_window,
      "candidates" => Enum.map(context.candidates, &Candidate.snapshot/1),
      "conversation_episode_count" => context.conversation_episode_count,
      "source_dependencies" => context.source_dependencies,
      "knowledge_omissions" => context.knowledge_omissions
    }
    |> put_conversation_context(context.conversation_context, context.context_manifest)
    |> put_routing_receipt(context.routing_receipt)
    |> put_observations(context.observations)
    |> put_knowledge(context.knowledge)
    |> put_slack_addressing(context.slack_addressing)
    |> put_custom_instructions(context.custom_instructions)
  end

  @doc false
  @spec episode_ids(map()) :: {:ok, [Ecto.UUID.t()]} | {:error, term()}
  def episode_ids(%{"candidates" => candidates}) when is_list(candidates) do
    ids = Enum.map(candidates, &candidate_episode_id/1)

    if Enum.all?(ids, &match?({:ok, _id}, &1)),
      do: {:ok, Enum.map(ids, fn {:ok, id} -> id end)},
      else: {:error, {:invalid_admission_context_snapshot, :episode_ids}}
  end

  def episode_ids(_snapshot),
    do: {:error, {:invalid_admission_context_snapshot, :episode_ids}}

  @doc false
  @spec restore(map(), Input.t(), Entry.t(), %{Ecto.UUID.t() => Episode.t()}) ::
          {:ok, t()} | {:error, term()}
  def restore(snapshot, %Input{} = input, %Entry{} = entry, episodes) when is_map(episodes) do
    fields =
      ~w(active_episode_fingerprint built_at candidates continuation_window conversation_episode_count)

    with true <-
           is_map(snapshot) and
             Enum.sort(
               Map.keys(
                 Map.drop(snapshot, [
                   "conversation_observations",
                   "conversation_knowledge",
                   "conversation_context",
                   "context_manifest",
                   "routing_receipt",
                   "source_dependencies",
                   "knowledge_omissions",
                   "slack_addressing",
                   "custom_instructions"
                 ])
               )
             ) ==
               Enum.sort(fields),
         {:ok, slack_addressing} <- restore_slack_addressing(snapshot, input),
         {:ok, custom_instructions} <- restore_custom_instructions(snapshot, input),
         observations when is_list(observations) <-
           Map.get(snapshot, "conversation_observations", []),
         true <- length(observations) <= 5,
         knowledge when is_list(knowledge) <- Map.get(snapshot, "conversation_knowledge", []),
         true <- length(knowledge) <= 8,
         omissions when is_list(omissions) <- Map.get(snapshot, "knowledge_omissions", []),
         true <- length(omissions) <= 8 and Enum.all?(omissions, &is_map/1),
         {:ok, built_at} <- parse_datetime(snapshot["built_at"]),
         true <- valid_fingerprint?(snapshot["active_episode_fingerprint"]),
         true <- valid_count?(snapshot["conversation_episode_count"]),
         true <- valid_window?(snapshot["continuation_window"]),
         {:ok, conversation_context} <- restore_document(snapshot, :conversation_context),
         {:ok, context_manifest} <- restore_document(snapshot, :context_manifest),
         {:ok, routing_receipt} <- restore_document(snapshot, :routing_receipt),
         {:ok, candidates} <- restore_candidates(snapshot["candidates"], episodes) do
      {:ok,
       %__MODULE__{
         active_episode_fingerprint: snapshot["active_episode_fingerprint"],
         built_at: built_at,
         candidates: candidates,
         conversation_episode_count: snapshot["conversation_episode_count"],
         continuation_window: snapshot["continuation_window"],
         input: input,
         input_entry: entry,
         fitted?: true,
         slack_addressing: slack_addressing,
         custom_instructions: custom_instructions,
         conversation_context: conversation_context,
         context_manifest: context_manifest,
         routing_receipt: routing_receipt,
         observations: observations,
         knowledge: knowledge,
         knowledge_omissions: omissions,
         source_dependencies: snapshot["source_dependencies"]
       }}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, {:invalid_admission_context_snapshot, :document}}
    end
  end

  def restore(_snapshot, _input, _entry, _episodes),
    do: {:error, {:invalid_admission_context_snapshot, :document}}

  defp valid_window?(nil), do: true
  defp valid_window?(seconds), do: is_integer(seconds) and seconds > 0

  # The frozen bundle and its manifest travel together: a receipt that claimed
  # coverage the model never received would be worse than no receipt at all.
  defp put_conversation_context(document, nil, _manifest), do: document

  defp put_conversation_context(document, bundle, manifest) do
    document
    |> Map.put("conversation_context", bundle)
    |> Map.put("context_manifest", manifest)
  end

  defp put_routing_receipt(document, nil), do: document
  defp put_routing_receipt(document, receipt), do: Map.put(document, "routing_receipt", receipt)

  defp restore_document(snapshot, field) do
    case Map.fetch(snapshot, Atom.to_string(field)) do
      :error -> {:ok, nil}
      {:ok, %{} = document} -> {:ok, document}
      {:ok, _invalid} -> {:error, {:invalid_admission_context_snapshot, field}}
    end
  end

  defp put_slack_addressing(document, nil), do: document

  defp put_slack_addressing(document, addressing),
    do: Map.put(document, "slack_addressing", addressing)

  defp put_custom_instructions(document, nil), do: document

  defp put_custom_instructions(document, snapshot),
    do: Map.put(document, "custom_instructions", snapshot)

  defp restore_custom_instructions(snapshot, input) do
    case Map.fetch(snapshot, "custom_instructions") do
      :error ->
        {:ok, nil}

      {:ok, saved} ->
        if Ryker.Instructions.valid_snapshot?(saved, input.destination),
          do: {:ok, saved},
          else: {:error, {:invalid_admission_context_snapshot, :custom_instructions}}
    end
  end

  defp restore_slack_addressing(snapshot, input) do
    case Map.fetch(snapshot, "slack_addressing") do
      :error -> {:ok, nil}
      {:ok, addressing} -> validate_slack_addressing(addressing, input.source.kind)
    end
  end

  defp validate_slack_addressing(
         %{"audience" => audience, "ryker_user_ref" => ref} = addressing,
         "slack"
       )
       when map_size(addressing) == 2 and audience in ["ambient", "direct", "mention"] and
              is_binary(ref) and byte_size(ref) <= 256 do
    if Regex.match?(~r/\A[A-Z0-9]+\z/, ref),
      do: {:ok, addressing},
      else: {:error, {:invalid_admission_context_snapshot, :slack_addressing}}
  end

  defp validate_slack_addressing(_addressing, _source),
    do: {:error, {:invalid_admission_context_snapshot, :slack_addressing}}

  # Present only when the host already selected a repository for this route, so a
  # conversational route never reads a source selector as available.
  defp put_repository_source_kinds(document, nil), do: document

  defp put_repository_source_kinds(document, repository_ref) when is_binary(repository_ref),
    do: Map.put(document, "repository_source_kinds", ~w(default branch pull_request commit))

  defp put_observations(document, []), do: document

  defp put_observations(document, notes),
    do: Map.put(document, "conversation_observations", notes)

  defp put_knowledge(document, []), do: document
  defp put_knowledge(document, items), do: Map.put(document, "conversation_knowledge", items)

  defp restore_candidates(candidates, episodes) when is_list(candidates) do
    candidates
    |> Enum.reduce_while({:ok, []}, fn snapshot, {:ok, restored} ->
      with {:ok, id} <- candidate_episode_id(snapshot),
           %Episode{} = episode <- Map.get(episodes, id),
           {:ok, candidate} <- Candidate.restore(snapshot, episode) do
        {:cont, {:ok, [candidate | restored]}}
      else
        _invalid -> {:halt, {:error, {:invalid_admission_context_snapshot, :candidates}}}
      end
    end)
    |> case do
      {:ok, restored} -> {:ok, Enum.reverse(restored)}
      {:error, _reason} = error -> error
    end
  end

  defp restore_candidates(_candidates, _episodes),
    do: {:error, {:invalid_admission_context_snapshot, :candidates}}

  defp candidate_episode_id(%{"episode_id" => id}) do
    case Ecto.UUID.cast(id) do
      {:ok, normalized} when normalized == id -> {:ok, id}
      _invalid -> {:error, :episode_id}
    end
  end

  defp candidate_episode_id(_candidate), do: {:error, :episode_id}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _invalid -> {:error, {:invalid_admission_context_snapshot, :built_at}}
    end
  end

  defp parse_datetime(_value),
    do: {:error, {:invalid_admission_context_snapshot, :built_at}}

  defp valid_count?(count), do: is_integer(count) and count >= 0

  defp valid_fingerprint?(fingerprint) do
    is_binary(fingerprint) and byte_size(fingerprint) == 64 and
      Regex.match?(~r/^[0-9a-f]{64}$/, fingerprint)
  end
end
