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
  defstruct @enforce_keys

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
  end

  @doc false
  @spec snapshot(t()) :: map()
  def snapshot(%__MODULE__{} = context) do
    %{
      "active_episode_fingerprint" => context.active_episode_fingerprint,
      "built_at" => DateTime.to_iso8601(context.built_at),
      "candidates" => Enum.map(context.candidates, &Candidate.snapshot/1),
      "conversation_episode_count" => context.conversation_episode_count
    }
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

    with true <- is_map(snapshot) and Enum.sort(Map.keys(snapshot)) == Enum.sort(fields),
         {:ok, built_at} <- parse_datetime(snapshot["built_at"]),
         true <- valid_fingerprint?(snapshot["active_episode_fingerprint"]),
         true <- valid_count?(snapshot["conversation_episode_count"]),
         {:ok, candidates} <- restore_candidates(snapshot["candidates"], episodes) do
      {:ok,
       %__MODULE__{
         active_episode_fingerprint: snapshot["active_episode_fingerprint"],
         built_at: built_at,
         candidates: candidates,
         conversation_episode_count: snapshot["conversation_episode_count"],
         input: input,
         input_entry: entry
       }}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, {:invalid_admission_context_snapshot, :document}}
    end
  end

  def restore(_snapshot, _input, _entry, _episodes),
    do: {:error, {:invalid_admission_context_snapshot, :document}}

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
