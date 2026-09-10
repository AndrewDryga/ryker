defmodule Responder.Evals.AdmissionCase do
  @moduledoc """
  Compiles harvested admission fixtures into provider-neutral model eval cases.

  The deterministic replay fixtures contain both a real sanitized input and the
  decision that should have preserved its lifecycle. This module deliberately
  rebuilds only the model-visible prompt and opaque candidate references. It
  never exposes the episode key, database identity, or destination authority to
  the evaluator.
  """

  alias Responder.Admission
  alias Responder.Admission.{Candidate, Context, Decision, Prompt}
  alias Responder.Episodes.Episode
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Ingress.Input
  alias Responder.Slack.Input, as: SlackInput

  @manifest_path "testdata/eval/admission.json"
  @manifest_fields ~w(context_fixture reason)

  @enforce_keys [
    :accepted_alternatives,
    :eval_id,
    :expectation,
    :fixture_path,
    :prompt,
    :reason,
    :schema,
    :source
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          accepted_alternatives: [Decision.t()],
          eval_id: String.t(),
          expectation: map(),
          fixture_path: Path.t(),
          prompt: map(),
          reason: String.t(),
          schema: map(),
          source: map()
        }

  @spec all(Path.t()) :: {:ok, [t()]} | {:error, term()}
  def all(manifest_path \\ @manifest_path) do
    with {:ok, manifest} <- decode_file(manifest_path),
         evals when is_list(evals) <- manifest["cases"],
         {:ok, cases} <- compile_all(evals) do
      unique_cases(cases)
    else
      nil -> {:error, {:invalid_admission_eval_manifest, :cases}}
      {:error, _reason} = error -> error
      _invalid -> {:error, {:invalid_admission_eval_manifest, :document}}
    end
  end

  @spec compile(map()) :: {:ok, t()} | {:error, term()}
  def compile(%{} = descriptor) do
    with :ok <- descriptor_fields(descriptor),
         {:ok, eval_id} <- eval_id(descriptor),
         :ok <- nonblank(descriptor["reason"], :reason),
         {:ok, fixture} <- decode_file(descriptor["context_fixture"]),
         {:ok, now} <- datetime(fixture["now"], :now),
         {:ok, input} <- input(fixture["input"]),
         {:ok, candidate} <-
           candidate(fixture["seed"], input.destination.thread_ref, now, fixture),
         context <- context(input, candidate, now),
         {:ok, expectation} <- expectation(fixture["decision"], context, candidate),
         {:ok, accepted_alternatives} <-
           accepted_alternatives(
             fixture["accepted_alternatives"],
             context,
             candidate,
             expectation
           ) do
      {:ok,
       %__MODULE__{
         accepted_alternatives: accepted_alternatives,
         eval_id: eval_id,
         expectation: expectation,
         fixture_path: descriptor["context_fixture"],
         prompt: Prompt.build(context),
         reason: descriptor["reason"],
         schema: Decision.json_schema(Input.allowed_actions(input), Input.reaction_names(input)),
         source: fixture["source"]
       }}
    end
  end

  def compile(_descriptor), do: {:error, {:invalid_admission_eval, :descriptor}}

  @spec document(t()) :: map()
  def document(%__MODULE__{} = eval) do
    %{
      "accepted_alternatives" => Enum.map(eval.accepted_alternatives, &Decision.document/1),
      "eval_id" => eval.eval_id,
      "expectation" => eval.expectation,
      "fixture_path" => eval.fixture_path,
      "prompt" => eval.prompt,
      "reason" => eval.reason,
      "schema" => eval.schema,
      "source" => eval.source
    }
  end

  @spec assess(t(), map()) :: {:ok, Decision.t()} | {:error, term()}
  def assess(%__MODULE__{} = eval, candidate_document) do
    with {:ok, decision} <- Decision.parse(candidate_document),
         submitted <- comparable(Decision.document(decision)),
         true <- accepted?(eval, submitted) do
      {:ok, decision}
    else
      false ->
        {:error,
         {:admission_eval_mismatch,
          expected: eval.expectation, submitted: comparable(candidate_document)}}

      {:error, _reason} = error ->
        error
    end
  end

  defp compile_all(evals) do
    Enum.reduce_while(evals, {:ok, []}, fn descriptor, {:ok, cases} ->
      case compile(descriptor) do
        {:ok, eval} -> {:cont, {:ok, [eval | cases]}}
        {:error, reason} -> {:halt, {:error, {descriptor["context_fixture"], reason}}}
      end
    end)
    |> case do
      {:ok, cases} -> {:ok, Enum.reverse(cases)}
      {:error, _reason} = error -> error
    end
  end

  defp unique_cases(cases) do
    ids = Enum.map(cases, & &1.eval_id)

    if Enum.uniq(ids) == ids,
      do: {:ok, cases},
      else: {:error, {:invalid_admission_eval_manifest, :duplicate_eval_id}}
  end

  defp descriptor_fields(descriptor) do
    keys = Map.keys(descriptor)

    valid? =
      Enum.all?(@manifest_fields, &(&1 in keys)) and
        Enum.sort(keys) == Enum.sort(@manifest_fields ++ ~w(eval_id))

    if valid?,
      do: :ok,
      else: {:error, {:invalid_admission_eval, :descriptor_fields}}
  end

  defp eval_id(%{"eval_id" => eval_id}) do
    with :ok <- nonblank(eval_id, :eval_id), do: {:ok, eval_id}
  end

  defp candidate(nil, _current_thread, _now, _fixture), do: {:ok, nil}

  defp candidate(%{} = seed, current_thread, now, fixture) do
    with {:ok, seed_input} <- input(seed["input"]),
         {:ok, updated_at} <- datetime(seed["updated_at"], :updated_at),
         {:ok, state} <- state(seed["state"]),
         {:ok, episode_id} <- uuid(seed["episode_id"]) do
      episode = %Episode{
        destination_conversation_ref: seed_input.destination.conversation_ref,
        destination_thread_ref: seed_input.destination.thread_ref,
        destination_transport: seed_input.destination.transport,
        execution_mode: :live,
        id: episode_id,
        input_revisions: %{seed_input.native_input_id => seed_input.revision},
        state: state,
        updated_at: updated_at
      }

      endpoint = %{
        occurred_at: seed_input.occurred_at,
        payload: %{"payload" => Input.document(seed_input)}
      }

      continuation_window = fixture["continuation_window_seconds"]

      if is_integer(continuation_window) and continuation_window >= 0 do
        {:ok,
         Candidate.new(
           episode,
           %{first: endpoint, latest: endpoint},
           current_thread,
           now,
           continuation_window
         )}
      else
        {:error, {:invalid_admission_eval, :continuation_window_seconds}}
      end
    end
  end

  defp candidate(_seed, _current_thread, _now, _fixture),
    do: {:error, {:invalid_admission_eval, :seed}}

  defp context(input, candidate, now) do
    candidates = if candidate, do: [candidate], else: []

    %Context{
      active_episode_fingerprint: Responder.CanonicalJSON.digest([]),
      built_at: now,
      candidates: candidates,
      conversation_episode_count: length(candidates),
      input: input,
      input_entry: %Entry{execution_mode: :live, id: Ecto.UUID.generate()}
    }
  end

  defp expectation(%{} = document, context, candidate) do
    with {:ok, decision} <- fixture_decision(document, context, candidate),
         do: {:ok, comparable(Decision.document(decision))}
  end

  defp expectation(_document, _context, _candidate),
    do: {:error, {:invalid_admission_eval, :decision}}

  defp accepted_alternatives(nil, _context, _candidate, _expectation), do: {:ok, []}

  defp accepted_alternatives(documents, context, candidate, expectation)
       when is_list(documents) do
    documents
    |> Enum.reduce_while({:ok, []}, fn document, {:ok, alternatives} ->
      case fixture_decision(document, context, candidate) do
        {:ok, decision} -> {:cont, {:ok, [decision | alternatives]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, alternatives} ->
        alternatives = Enum.reverse(alternatives)

        if unique_alternatives?(alternatives, expectation),
          do: {:ok, alternatives},
          else: {:error, {:invalid_admission_eval, :accepted_alternatives}}

      {:error, _reason} = error ->
        error
    end
  end

  defp accepted_alternatives(_documents, _context, _candidate, _expectation),
    do: {:error, {:invalid_admission_eval, :accepted_alternatives}}

  defp fixture_decision(%{} = document, context, candidate) do
    document = resolve_seed(document, candidate)

    with {:ok, decision} <- Decision.parse(document),
         {:ok, _selection} <- Admission.validate(context, decision) do
      {:ok, decision}
    end
  end

  defp fixture_decision(_document, _context, _candidate),
    do: {:error, {:invalid_admission_eval, :accepted_alternatives}}

  defp resolve_seed(document, candidate) do
    if document["episode_ref"] == "$seed" and candidate,
      do: Map.put(document, "episode_ref", candidate.ref),
      else: document
  end

  defp unique_alternatives?(alternatives, expectation) do
    comparisons = Enum.map(alternatives, &comparable(Decision.document(&1)))
    expectation not in comparisons and Enum.uniq(comparisons) == comparisons
  end

  defp accepted?(eval, submitted) do
    submitted == eval.expectation or
      Enum.any?(eval.accepted_alternatives, fn alternative ->
        submitted == comparable(Decision.document(alternative))
      end)
  end

  defp comparable(%{} = document) do
    Map.take(document, ~w(action episode_ref reaction relation work_class))
  end

  defp comparable(_document), do: nil

  defp input(%{} = document) do
    with {:ok, occurred_at} <- datetime(document["occurred_at"], :occurred_at),
         {:ok, actor_kind} <- actor_kind(document["actor"] && document["actor"]["kind"]),
         {:ok, event_kind} <- event_kind(document["event_kind"]) do
      SlackInput.new(%{
        actor: %{kind: actor_kind, ref: document["actor"]["ref"]},
        channel_ref: document["channel_ref"],
        content: document["content"],
        event_kind: event_kind,
        event_ref: document["event_ref"],
        message_ref: document["message_ref"],
        occurred_at: occurred_at,
        revision: document["revision"],
        thread_ref: document["thread_ref"],
        workspace_ref: document["workspace_ref"]
      })
    end
  end

  defp input(_document), do: {:error, {:invalid_admission_eval, :input}}

  defp actor_kind("user"), do: {:ok, :user}
  defp actor_kind("app"), do: {:ok, :app}
  defp actor_kind("bot"), do: {:ok, :bot}
  defp actor_kind(_kind), do: {:error, {:invalid_admission_eval, :actor_kind}}

  defp event_kind("message"), do: {:ok, :message}
  defp event_kind("edit"), do: {:ok, :edit}
  defp event_kind("delete"), do: {:ok, :delete}
  defp event_kind(_kind), do: {:error, {:invalid_admission_eval, :event_kind}}

  defp state("working"), do: {:ok, :working}
  defp state("waiting_for_input"), do: {:ok, :waiting_for_input}
  defp state("waiting_for_event"), do: {:ok, :waiting_for_event}
  defp state("complete"), do: {:ok, :complete}
  defp state("cancelled"), do: {:ok, :cancelled}
  defp state(_state), do: {:error, {:invalid_admission_eval, :state}}

  defp datetime(value, field) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _invalid -> {:error, {:invalid_admission_eval, field}}
    end
  end

  defp datetime(_value, field), do: {:error, {:invalid_admission_eval, field}}

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, normalized} when normalized == value -> {:ok, value}
      _invalid -> {:error, {:invalid_admission_eval, :episode_id}}
    end
  end

  defp decode_file(path) when is_binary(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, document} <- Jason.decode(contents),
         true <- is_map(document) do
      {:ok, document}
    else
      false -> {:error, {:invalid_admission_eval, :json_document}}
      {:error, reason} -> {:error, {:invalid_admission_eval_file, path, reason}}
    end
  end

  defp decode_file(_path), do: {:error, {:invalid_admission_eval, :path}}

  defp nonblank(value, _field)
       when is_binary(value) and byte_size(value) in 1..2_048 do
    if String.valid?(value) and String.trim(value) != "" and
         :binary.match(value, <<0>>) == :nomatch,
       do: :ok,
       else: {:error, {:invalid_admission_eval, :text}}
  end

  defp nonblank(_value, field), do: {:error, {:invalid_admission_eval, field}}
end
