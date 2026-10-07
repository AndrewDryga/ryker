defmodule Ryker.Admission.Context do
  @moduledoc """
  Frozen input and bounded candidate set supplied to one model decision.

  `previous_answer` is set only for a person's message in Slack or Chat that
  follows one of Ryker's answers in the same place: the latest answer in the
  frozen conversation context, when it was sent and the request it belongs
  to. The router is told when it was sent and asked how the sender feels
  about it (`Ryker.Admission.Sentiment`); the host keeps what it says as
  feedback on that request.
  """
  alias Ryker.Admission.Candidate
  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Ingress.Input
  alias Ryker.People

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
                person_asking: nil,
                conversation_context: nil,
                context_manifest: nil,
                routing_receipt: nil,
                continuation_window: nil,
                repository_choices: [],
                candidate_messages: [],
                previous_answer: nil,
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
    |> put_model_person_asking(context.person_asking)
    |> put_repository_choices(context.repository_choices)
    |> put_repository_source_kinds(context.input_entry.repository_ref)
    |> put_model_previous_answer(context.previous_answer)
  end

  @doc "Whether routing is asked how the sender feels about Ryker's previous answer."
  @spec sentiment_offered?(t()) :: boolean()
  def sentiment_offered?(%__MODULE__{previous_answer: %{}}), do: true
  def sentiment_offered?(%__MODULE__{}), do: false

  # The router reads only when the answer was sent; the message itself is in
  # conversation_context, and which request it belongs to is the host's.
  defp put_model_previous_answer(document, %{"at" => at}),
    do: Map.put(document, "previous_answer", %{"at" => Candidate.model_time(at)})

  defp put_model_previous_answer(document, _none), do: document

  @doc "Whether the operator saved any instruction text for this request."
  @spec custom_instructions?(t()) :: boolean()
  def custom_instructions?(%__MODULE__{custom_instructions: snapshot}),
    do: instruction_text?(snapshot)

  defp instruction_text?(%{} = snapshot) do
    Enum.any?(
      ~w(global channel),
      &match?(%{"text" => text} when is_binary(text) and text != "", snapshot[&1])
    )
  end

  defp instruction_text?(_snapshot), do: false

  # A routing session answers one message, so an empty snapshot has no earlier
  # instruction to clear; it is left out with the paragraph that explains it.
  defp put_model_custom_instructions(document, snapshot) do
    if instruction_text?(snapshot),
      do: Map.put(document, "custom_instructions", snapshot),
      else: document
  end

  # What the sender said about themselves (`Ryker.People`), with how to use
  # it; left out when nothing is known, so most prompts are as they were.
  defp put_model_person_asking(document, nil), do: document

  defp put_model_person_asking(document, facts),
    do: Map.put(document, "person_asking", People.model_context(facts))

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
    |> put_person_asking(context.person_asking)
    |> put_repository_choices(context.repository_choices)
    |> put_candidate_messages(context.candidate_messages)
    |> put_previous_answer(context.previous_answer)
  end

  defp put_previous_answer(document, nil), do: document

  defp put_previous_answer(document, answer),
    do: Map.put(document, "previous_answer", answer)

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
                   "custom_instructions",
                   "person_asking",
                   "repository_choices",
                   "candidate_messages",
                   "previous_answer"
                 ])
               )
             ) ==
               Enum.sort(fields),
         {:ok, slack_addressing} <- restore_slack_addressing(snapshot, input),
         {:ok, custom_instructions} <- restore_custom_instructions(snapshot, input),
         {:ok, person_asking} <- restore_person_asking(snapshot),
         {:ok, repository_choices} <- restore_repository_choices(snapshot),
         {:ok, candidate_messages} <- restore_candidate_messages(snapshot),
         {:ok, previous_answer} <- restore_previous_answer(snapshot),
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
         person_asking: person_asking,
         conversation_context: conversation_context,
         context_manifest: context_manifest,
         routing_receipt: routing_receipt,
         observations: observations,
         knowledge: knowledge,
         knowledge_omissions: omissions,
         repository_choices: repository_choices,
         candidate_messages: candidate_messages,
         previous_answer: previous_answer,
         source_dependencies: snapshot["source_dependencies"]
       }}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, {:invalid_admission_context_snapshot, :document}}
    end
  end

  def restore(_snapshot, _input, _entry, _episodes),
    do: {:error, {:invalid_admission_context_snapshot, :document}}

  # The repositories a new episode chooses among, each by ref with what the
  # operator wrote about it, frozen so the receipt shows the exact choices
  # the model had. A context frozen before the choice existed offered none;
  # a present list is a choice only with two or more distinct repositories.
  @maximum_repository_choices 33
  defp restore_repository_choices(snapshot) do
    case Map.fetch(snapshot, "repository_choices") do
      :error ->
        {:ok, []}

      {:ok, choices}
      when is_list(choices) and length(choices) in 2..@maximum_repository_choices ->
        refs = Enum.map(choices, &choice_ref/1)

        if Enum.all?(choices, &repository_choice?/1) and Enum.uniq(refs) == refs,
          do: {:ok, choices},
          else: {:error, {:invalid_admission_context_snapshot, :repository_choices}}

      {:ok, _invalid} ->
        {:error, {:invalid_admission_context_snapshot, :repository_choices}}
    end
  end

  defp choice_ref(%{"ref" => ref}), do: ref
  defp choice_ref(_choice), do: nil

  # A context frozen before routing read sentiment has none.
  defp restore_previous_answer(snapshot) do
    case Map.fetch(snapshot, "previous_answer") do
      :error ->
        {:ok, nil}

      {:ok, %{"at" => at, "message_ref" => ref, "request" => request} = answer}
      when map_size(answer) == 3 and is_binary(ref) and byte_size(ref) in 1..1_024 ->
        if match?({:ok, _at, 0}, DateTime.from_iso8601(to_string(at))) and request?(request),
          do: {:ok, answer},
          else: {:error, {:invalid_admission_context_snapshot, :previous_answer}}

      {:ok, _invalid} ->
        {:error, {:invalid_admission_context_snapshot, :previous_answer}}
    end
  end

  defp request?(%{} = request) when map_size(request) == 1 do
    case request do
      %{"episode_id" => id} when is_binary(id) -> match?({:ok, _id}, Ecto.UUID.cast(id))
      %{"input_id" => id} when is_binary(id) -> match?({:ok, _id}, Ecto.UUID.cast(id))
      _other -> false
    end
  end

  defp request?(_request), do: false

  defp repository_choice?(%{"ref" => ref} = choice) when is_binary(ref) do
    String.trim(ref) != "" and byte_size(ref) <= 1_024 and
      Map.keys(choice) -- ["description", "ref"] == [] and
      (not Map.has_key?(choice, "description") or is_binary(choice["description"]))
  end

  defp repository_choice?(_choice), do: false

  # The messages the candidates' previews quote, which forgetting reaches a
  # copy of the prompt by (`Ryker.Admission.Candidate.previewed_messages/1`):
  # two for each of at most twenty candidates, and none recorded when no
  # candidate had a preview.
  @maximum_candidate_messages 40
  defp restore_candidate_messages(snapshot) do
    case Map.fetch(snapshot, "candidate_messages") do
      :error ->
        {:ok, []}

      {:ok, messages}
      when is_list(messages) and length(messages) in 1..@maximum_candidate_messages ->
        if Enum.all?(messages, &candidate_message?/1),
          do: {:ok, messages},
          else: {:error, {:invalid_admission_context_snapshot, :candidate_messages}}

      {:ok, _invalid} ->
        {:error, {:invalid_admission_context_snapshot, :candidate_messages}}
    end
  end

  defp candidate_message?(%{"conversation_ref" => conversation, "message_ref" => message} = entry)
       when map_size(entry) == 2,
       do: is_binary(conversation) and is_binary(message)

  defp candidate_message?(_message), do: false

  defp put_candidate_messages(document, []), do: document

  defp put_candidate_messages(document, messages),
    do: Map.put(document, "candidate_messages", messages)

  defp put_repository_choices(document, []), do: document

  defp put_repository_choices(document, choices),
    do: Map.put(document, "repository_choices", choices)

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

  defp put_person_asking(document, nil), do: document
  defp put_person_asking(document, facts), do: Map.put(document, "person_asking", facts)

  defp restore_person_asking(snapshot) do
    case Map.fetch(snapshot, "person_asking") do
      :error ->
        {:ok, nil}

      {:ok, facts} ->
        if People.valid_facts?(facts),
          do: {:ok, facts},
          else: {:error, {:invalid_admission_context_snapshot, :person_asking}}
    end
  end

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
