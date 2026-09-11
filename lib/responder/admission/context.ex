defmodule Responder.Admission.Context do
  @moduledoc """
  Frozen input and bounded candidate set supplied to one model decision.
  """

  alias Responder.Admission.Candidate
  alias Responder.Episodes.Episode
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Ingress.Input

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

  @spec for_model(t()) :: map()
  def for_model(%__MODULE__{} = context) do
    %{
      "allowed_actions" => Enum.map(Input.allowed_actions(context.input), &Atom.to_string/1),
      "candidates" => Enum.map(context.candidates, &Candidate.for_model/1),
      "execution_mode" => Atom.to_string(context.input_entry.execution_mode),
      "input" => Input.model_document(context.input)
    }
    |> put_conversation_context(context.conversation_context, context.context_manifest)
    |> put_observations(context.observations)
    |> put_knowledge(context.knowledge)
    |> put_slack_addressing(context.slack_addressing)
    |> put_custom_instructions(context.custom_instructions)
    |> put_repository_source_kinds(context.input_entry.repository_ref)
  end

  @doc false
  @spec snapshot(t()) :: map()
  def snapshot(%__MODULE__{} = context) do
    %{
      "active_episode_fingerprint" => context.active_episode_fingerprint,
      "built_at" => DateTime.to_iso8601(context.built_at),
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
    fields = ~w(active_episode_fingerprint built_at candidates conversation_episode_count)

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
         {:ok, conversation_context} <- restore_document(snapshot, "conversation_context"),
         {:ok, context_manifest} <- restore_document(snapshot, "context_manifest"),
         {:ok, routing_receipt} <- restore_document(snapshot, "routing_receipt"),
         {:ok, candidates} <- restore_candidates(snapshot["candidates"], episodes) do
      {:ok,
       %__MODULE__{
         active_episode_fingerprint: snapshot["active_episode_fingerprint"],
         built_at: built_at,
         candidates: candidates,
         conversation_episode_count: snapshot["conversation_episode_count"],
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

  defp restore_document(snapshot, key) do
    case Map.fetch(snapshot, key) do
      :error -> {:ok, nil}
      {:ok, %{} = document} -> {:ok, document}
      {:ok, _invalid} -> {:error, {:invalid_admission_context_snapshot, String.to_atom(key)}}
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
        if Responder.Instructions.valid_snapshot?(saved, input.destination),
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
         %{"audience" => audience, "responder_user_ref" => ref} = addressing,
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
