defmodule Ryker.Admission.Candidate do
  @moduledoc """
  A bounded episode option the host permits the model to select.

  The model sees a short opaque reference, the work's own title, its first and
  latest message as plain text, how long it has been idle, what it last said,
  the evidence that made it a candidate as plain labels, and the relations the
  host allows. Database identity, episode key, destination, retrieval scores
  and every conversation name outside the incoming source's own scope remain
  host-owned; the snapshot keeps the raw match for inspection.
  """

  alias Ryker.CanonicalJSON
  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.MessageText

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
  defstruct @enforce_keys ++ [source_documents: [], outcome: nil, idle_minutes: 0]

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
          source_owner: boolean(),
          outcome: String.t() | nil,
          idle_minutes: non_neg_integer()
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
      source_documents: endpoints |> Map.values() |> Enum.map(&source_document/1),
      outcome: Map.get(attributes, :outcome),
      idle_minutes: Map.get(attributes, :idle_minutes, 0)
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

  # Empty values are left out rather than sent as null: every absent field is a
  # token the model reads on every routing turn for nothing.
  @spec for_model(t()) :: map()
  def for_model(%__MODULE__{} = candidate) do
    digest = candidate.digest || %{}
    opening = candidate.first_input_preview
    latest = candidate.latest_input_preview

    # The work's own name says what a human opening message said; an opening
    # message is sent when there is no name, or when an app, bot or system
    # opened the work and its first message carries the alert, run or
    # deployment identity a new event is compared against.
    first =
      if is_nil(digest["title"]) or (is_map(opening) and opening["automated"]),
        do: model_message(opening)

    latest = if different_message?(latest, opening), do: model_message(latest)

    %{
      "allowed_relations" => Enum.map(candidate.allowed_relations, &Atom.to_string/1),
      "conversations" =>
        if(is_integer(digest["conversations"]) and digest["conversations"] > 1,
          do: digest["conversations"]
        ),
      "episode_ref" => candidate.ref,
      "evidence" => evidence(candidate.match),
      "first_message" => first,
      "idle_minutes" => candidate.idle_minutes,
      "latest_message" => latest,
      "message_count" => digest["message_count"],
      "outcome" => candidate.outcome,
      "state" => candidate.model_state,
      "title" => digest["title"]
    }
    |> Map.reject(fn {_key, value} -> value in [nil, []] end)
  end

  defp different_message?(%{} = latest, %{} = opening),
    do: Map.take(latest, ~w(at text)) != Map.take(opening, ~w(at text))

  defp different_message?(latest, _opening), do: is_map(latest)

  defp model_message(nil), do: nil

  defp model_message(preview) do
    message = Map.take(preview, ~w(actor at text))
    if preview["truncated"], do: Map.put(message, "truncated", true), else: message
  end

  # Why the host offered this candidate, as labels a reader can use. The raw
  # rank features stay in the snapshot: their points and lanes are retrieval
  # internals with no scale the model could act on.
  @evidence ~w(source_owner occurrence_identity direct_references same_thread same_conversation topic_fit)
  # The text rank is rank / (rank + 1) over weighted words: 0.1 for each
  # shared word in the messages, 0.2 more in the opening or latest message,
  # 0.4 in the title. A few shared words reach this; one or two do not.
  @similar_wording 0.5

  defp evidence(match) when is_map(match) do
    @evidence
    |> Enum.map(&evidence_label(&1, match[&1], match))
    |> Enum.filter(&is_binary/1)
  end

  defp evidence(_match), do: []

  defp evidence_label("source_owner", true, _match), do: "owns this exact source message"
  defp evidence_label("occurrence_identity", true, _match), do: "same source occurrence"
  defp evidence_label("direct_references", 1, _match), do: "shares 1 identifier"

  defp evidence_label("direct_references", count, _match) when is_integer(count) and count > 1,
    do: "shares #{count} identifiers"

  defp evidence_label("same_thread", true, _match), do: "same thread"

  # The thread already says the conversation.
  defp evidence_label("same_conversation", true, match),
    do: if(match["same_thread"] == true, do: nil, else: "same conversation")

  defp evidence_label("topic_fit", fit, _match) when is_number(fit) and fit >= @similar_wording,
    do: "similar wording"

  defp evidence_label(_feature, _value, _match), do: nil

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

  # The frozen record keeps every host fact the model text is derived from,
  # including the raw rank features, so a restored context renders the same
  # text and an inspector can still say why the candidate was offered.
  @doc false
  @spec snapshot(t()) :: map()
  def snapshot(%__MODULE__{} = candidate) do
    %{
      "allowed_relations" => Enum.map(candidate.allowed_relations, &Atom.to_string/1),
      "digest" => candidate.digest,
      "episode_id" => candidate.episode.id,
      "episode_ref" => candidate.ref,
      "first_input" => candidate.first_input_preview,
      "idle_minutes" => candidate.idle_minutes,
      "latest_input" => candidate.latest_input_preview,
      "match" => candidate.match,
      "outcome" => candidate.outcome,
      "same_thread" => candidate.same_thread,
      "source_owner" => candidate.source_owner,
      "state" => candidate.model_state
    }
  end

  @doc false
  @spec restore(map(), Episode.t()) :: {:ok, t()} | {:error, term()}
  def restore(%{} = snapshot, %Episode{} = episode) do
    fields =
      ~w(allowed_relations digest episode_id episode_ref first_input idle_minutes latest_input match outcome same_thread source_owner state)

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
         true <- valid_preview?(snapshot["latest_input"]),
         true <- is_nil(snapshot["outcome"]) or is_binary(snapshot["outcome"]),
         true <- is_integer(snapshot["idle_minutes"]) and snapshot["idle_minutes"] >= 0 do
      {:ok,
       %__MODULE__{
         allowed_relations: relations,
         digest: snapshot["digest"],
         episode: episode,
         first_input_preview: snapshot["first_input"],
         idle_minutes: snapshot["idle_minutes"],
         latest_input_preview: snapshot["latest_input"],
         match: snapshot["match"],
         model_state: snapshot["state"],
         outcome: snapshot["outcome"],
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
    Map.keys(digest) |> Enum.sort() == ~w(conversations message_count title) and
      is_integer(digest["message_count"]) and is_integer(digest["conversations"]) and
      (is_nil(digest["title"]) or is_binary(digest["title"]))
  end

  defp valid_digest?(_digest), do: false

  defp valid_preview?(nil), do: true

  defp valid_preview?(%{} = preview) do
    Map.keys(preview) |> Enum.sort() == ~w(actor at automated text truncated) and
      (is_nil(preview["actor"]) or is_binary(preview["actor"])) and
      is_boolean(preview["automated"]) and
      is_binary(preview["text"]) and is_binary(preview["at"]) and
      is_boolean(preview["truncated"])
  end

  defp valid_preview?(_preview), do: false

  defp model_state(state) when state in [:working, :waiting_for_input, :waiting_for_event],
    do: "active"

  defp model_state(state), do: Atom.to_string(state)

  # Twelve hex characters are unique among twenty candidates and cost the
  # model a few tokens to echo; the whole digest cost thirty-two.
  defp opaque_ref(episode_id) do
    digest = CanonicalJSON.digest(["ingress-admission-candidate", episode_id])
    "candidate:" <> binary_part(digest, 0, 12)
  end

  defp preview(nil), do: nil

  # Plain fields instead of the source document as a JSON string: the escaped
  # quotes cost tokens and the model read the text through them anyway.
  defp preview(%{occurred_at: occurred_at, payload: event_payload}) when is_map(event_payload) do
    payload = preview_payload(event_payload["payload"])
    text = payload |> Map.get("content", payload) |> MessageText.from() |> model_text()

    %{
      "actor" => actor(payload["actor"]),
      "automated" => automated?(payload["actor"]),
      "at" => occurred_at |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "text" => String.byte_slice(text, 0, @preview_limit),
      "truncated" => byte_size(text) > @preview_limit
    }
  end

  defp preview(_endpoint), do: nil

  defp narrow_preview(nil, _limit), do: nil

  defp narrow_preview(preview, limit) do
    text = preview["text"]

    %{
      preview
      | "text" => String.byte_slice(text, 0, limit),
        "truncated" => preview["truncated"] or byte_size(text) > limit
    }
  end

  defp actor(%{"ref" => ref}) when is_binary(ref), do: ref
  defp actor(_actor), do: nil

  defp automated?(%{"kind" => kind}), do: kind in ~w(app bot system)
  defp automated?(_actor), do: false

  @doc "Message text as the model reads it: line endings normalized, edges trimmed."
  @spec model_text(term()) :: String.t()
  def model_text(text) when is_binary(text),
    do: text |> String.replace("\r\n", "\n") |> String.trim()

  def model_text(_text), do: ""

  @doc "A time as the model reads it: whole seconds, no microseconds to tokenize."
  @spec model_time(term()) :: term()
  def model_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      _other -> value
    end
  end

  def model_time(value), do: value

  defp preview_payload(payload) when is_map(payload), do: payload
  defp preview_payload(payload), do: %{"content" => payload}

  defp source_document(%{payload: %{"payload" => payload}}) when is_map(payload), do: payload
  defp source_document(_), do: nil
end
