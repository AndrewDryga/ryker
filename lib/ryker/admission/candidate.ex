defmodule Ryker.Admission.Candidate do
  @moduledoc """
  A bounded episode option the host permits the model to select.

  The model sees an opaque reference, the episode's source-backed digest, the
  evidence that made it a candidate, and the relations the host allows.
  Database identity, episode key, destination, and every conversation name
  outside the incoming source's own scope remain host-owned.

  First and latest previews supplement the digest; they are never its only
  evidence, because the message that identifies the work is usually neither.
  """

  alias Ryker.CanonicalJSON
  alias Ryker.Episodes.Episode

  @preview_limit 4_096
  @relations [:same_work, :history_only]

  @enforce_keys [
    :allowed_relations,
    :digest,
    :episode,
    :first_input_preview,
    :latest_input_preview,
    :match,
    :model_state,
    :ref,
    :same_thread,
    :source_owner
  ]
  defstruct @enforce_keys ++ [source_documents: []]

  @type t :: %__MODULE__{
          allowed_relations: [:same_work | :history_only],
          digest: map() | nil,
          episode: Episode.t(),
          first_input_preview: map() | nil,
          latest_input_preview: map() | nil,
          match: map(),
          model_state: String.t(),
          ref: String.t(),
          same_thread: boolean(),
          source_owner: boolean()
        }

  @type input_endpoint :: %{occurred_at: DateTime.t(), payload: map()}

  @doc """
  Builds one offered candidate.

  `allowed` is the host's relation decision; ranking supplies `match`, and the
  digest is the episode's own maintained projection.
  """
  @spec new(map()) :: t()
  def new(%{episode: %Episode{} = episode} = attributes) do
    endpoints = Map.get(attributes, :endpoints, %{})

    %__MODULE__{
      allowed_relations: Map.fetch!(attributes, :allowed_relations),
      digest: Map.get(attributes, :digest),
      episode: episode,
      first_input_preview: endpoints |> Map.get(:first) |> preview(),
      latest_input_preview: endpoints |> Map.get(:latest) |> preview(),
      match: Map.get(attributes, :match, %{}),
      model_state: model_state(episode.state),
      ref: opaque_ref(episode.id),
      same_thread: Map.get(attributes, :same_thread, false),
      source_owner: Map.get(attributes, :source_owner, false),
      source_documents: endpoints |> Map.values() |> Enum.map(&source_document/1)
    }
  end

  @doc """
  The relations the host permits for this candidate.

  Cancelled work stays history-only unless a separately authorized restore
  makes it active again. Work pinned to a different repository cannot become
  the same work, because merging evidence never broadens pinned authority.
  Completed work may continue only inside the continuation window, and the
  exact source item's owner must remain selectable so a revision cannot be
  reassigned by rank.
  """
  @spec allowed_relations(Episode.t(), map()) :: [:same_work | :history_only]
  def allowed_relations(%Episode{state: :cancelled}, _context), do: [:history_only]

  def allowed_relations(%Episode{} = episode, context) do
    cond do
      Map.get(context, :source_owner, false) -> @relations
      not repository_compatible?(episode, context) -> [:history_only]
      episode.state in [:working, :waiting_for_input, :waiting_for_event] -> @relations
      continuable_completion?(episode, context) -> @relations
      true -> [:history_only]
    end
  end

  defp repository_compatible?(_episode, %{pinned_repository: nil}), do: true
  defp repository_compatible?(_episode, %{input_repository: nil}), do: true

  defp repository_compatible?(_episode, %{pinned_repository: pinned, input_repository: input}),
    do: pinned == input

  defp repository_compatible?(_episode, _context), do: true

  defp continuable_completion?(%Episode{state: :complete, updated_at: updated_at}, context) do
    now = Map.fetch!(context, :now)
    window = Map.fetch!(context, :continuation_window)
    DateTime.diff(now, updated_at, :second) <= window
  end

  defp continuable_completion?(_episode, _context), do: false

  @spec for_model(t()) :: map()
  def for_model(%__MODULE__{} = candidate) do
    %{
      "allowed_relations" => Enum.map(candidate.allowed_relations, &Atom.to_string/1),
      "digest" => candidate.digest,
      "episode_ref" => candidate.ref,
      "first_input" => candidate.first_input_preview,
      "latest_input" => candidate.latest_input_preview,
      "match" => candidate.match,
      "same_thread" => candidate.same_thread,
      "source_owner" => candidate.source_owner,
      "state" => candidate.model_state
    }
  end

  @doc false
  def preview_limit, do: @preview_limit

  @doc "Narrow captured source text without rereading an episode or inventing omitted bytes."
  @spec with_preview_limit(t(), pos_integer()) :: t()
  def with_preview_limit(%__MODULE__{} = candidate, limit)
      when is_integer(limit) and limit > 0 and limit <= @preview_limit do
    %{
      candidate
      | first_input_preview: narrow_preview(candidate.first_input_preview, limit),
        latest_input_preview: narrow_preview(candidate.latest_input_preview, limit)
    }
  end

  @doc false
  @spec snapshot(t()) :: map()
  def snapshot(%__MODULE__{} = candidate) do
    candidate
    |> for_model()
    |> Map.put("episode_id", candidate.episode.id)
  end

  @doc false
  @spec restore(map(), Episode.t()) :: {:ok, t()} | {:error, term()}
  def restore(%{} = snapshot, %Episode{} = episode) do
    fields =
      ~w(allowed_relations digest episode_id episode_ref first_input latest_input match same_thread source_owner state)

    with true <- Enum.sort(Map.keys(snapshot)) == Enum.sort(fields),
         true <- snapshot["episode_id"] == episode.id,
         true <- snapshot["episode_ref"] == opaque_ref(episode.id),
         {:ok, relations} <- restore_relations(snapshot["allowed_relations"]),
         true <- is_boolean(snapshot["same_thread"]),
         true <- is_boolean(snapshot["source_owner"]),
         true <- snapshot["state"] in ~w(active complete cancelled),
         true <- valid_digest?(snapshot["digest"]),
         true <- is_map(snapshot["match"]),
         true <- valid_preview?(snapshot["first_input"]),
         true <- valid_preview?(snapshot["latest_input"]) do
      {:ok,
       %__MODULE__{
         allowed_relations: relations,
         digest: snapshot["digest"],
         episode: episode,
         first_input_preview: snapshot["first_input"],
         latest_input_preview: snapshot["latest_input"],
         match: snapshot["match"],
         model_state: snapshot["state"],
         ref: snapshot["episode_ref"],
         same_thread: snapshot["same_thread"],
         source_owner: snapshot["source_owner"]
       }}
    else
      _invalid -> {:error, {:invalid_admission_context_snapshot, :candidate}}
    end
  end

  def restore(_snapshot, _episode),
    do: {:error, {:invalid_admission_context_snapshot, :candidate}}

  defp restore_relations(relations) when is_list(relations) do
    parsed =
      Enum.map(relations, fn
        "same_work" -> :same_work
        "history_only" -> :history_only
        _other -> :invalid
      end)

    if parsed != [] and :invalid not in parsed and Enum.uniq(parsed) == parsed,
      do: {:ok, parsed},
      else: {:error, :relations}
  end

  defp restore_relations(_relations), do: {:error, :relations}

  defp valid_digest?(nil), do: true

  defp valid_digest?(%{} = digest) do
    Map.keys(digest) |> Enum.sort() ==
      ~w(conversations covered_through freshness input_count latest_development objective) and
      is_binary(digest["objective"]) and is_integer(digest["input_count"]) and
      is_integer(digest["conversations"]) and is_binary(digest["covered_through"]) and
      digest["freshness"] in ~w(current stale)
  end

  defp valid_digest?(_digest), do: false

  defp valid_preview?(nil), do: true

  defp valid_preview?(%{} = preview) do
    Map.keys(preview) |> Enum.sort() == ~w(content_preview occurred_at truncated) and
      is_binary(preview["content_preview"]) and is_binary(preview["occurred_at"]) and
      is_boolean(preview["truncated"])
  end

  defp valid_preview?(_preview), do: false

  defp model_state(state) when state in [:working, :waiting_for_input, :waiting_for_event],
    do: "active"

  defp model_state(state), do: Atom.to_string(state)

  defp opaque_ref(episode_id) do
    digest = CanonicalJSON.digest(["ingress-admission-candidate", episode_id])
    "candidate:#{digest}"
  end

  defp preview(nil), do: nil

  defp preview(%{occurred_at: occurred_at, payload: event_payload}) when is_map(event_payload) do
    payload = preview_payload(event_payload["payload"])

    model_payload = %{
      "actor" => payload["actor"],
      "content" => Map.get(payload, "content", payload),
      "event_kind" => payload["event_kind"]
    }

    encoded = CanonicalJSON.encode!(model_payload)

    %{
      "content_preview" => String.byte_slice(encoded, 0, @preview_limit),
      "occurred_at" => DateTime.to_iso8601(occurred_at),
      "truncated" => byte_size(encoded) > @preview_limit
    }
  end

  defp preview(_endpoint), do: nil

  defp narrow_preview(nil, _limit), do: nil

  defp narrow_preview(preview, limit) do
    text = preview["content_preview"]

    %{
      preview
      | "content_preview" => String.byte_slice(text, 0, limit),
        "truncated" => preview["truncated"] or byte_size(text) > limit
    }
  end

  defp preview_payload(payload) when is_map(payload), do: payload
  defp preview_payload(payload), do: %{"content" => payload}

  defp source_document(%{payload: %{"payload" => payload}}) when is_map(payload), do: payload
  defp source_document(_), do: nil
end
