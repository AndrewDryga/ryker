defmodule Responder.Admission.Candidate do
  @moduledoc """
  A bounded episode option the host permits the model to select.

  The model sees only the opaque reference and the context needed to judge the
  relationship. Database identity, episode key, and destination remain
  host-owned fields on this struct.
  """

  alias Responder.CanonicalJSON
  alias Responder.Episodes.Episode

  @preview_limit 256

  @enforce_keys [
    :allowed_relations,
    :episode,
    :first_input_preview,
    :latest_input_preview,
    :model_state,
    :ref,
    :same_thread
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          allowed_relations: [:same_work | :history_only],
          episode: Episode.t(),
          first_input_preview: map() | nil,
          latest_input_preview: map() | nil,
          model_state: String.t(),
          ref: String.t(),
          same_thread: boolean()
        }

  @type input_endpoint :: %{occurred_at: DateTime.t(), payload: map()}

  @spec new(
          Episode.t(),
          %{optional(:first) => input_endpoint(), optional(:latest) => input_endpoint()},
          String.t(),
          DateTime.t(),
          non_neg_integer()
        ) :: t()
  def new(%Episode{} = episode, endpoints, current_thread, now, continuation_window) do
    new(episode, endpoints, current_thread, now, continuation_window, true)
  end

  @doc false
  @spec new(
          Episode.t(),
          %{optional(:first) => input_endpoint(), optional(:latest) => input_endpoint()},
          String.t(),
          DateTime.t(),
          non_neg_integer(),
          :all | :none | :active_only | {:same_actor, String.t()} | boolean()
        ) :: t()
  def new(
        %Episode{} = episode,
        endpoints,
        current_thread,
        now,
        continuation_window,
        cross_thread_relation_scope
      )
      when cross_thread_relation_scope in [:all, :none, :active_only, true, false] or
             (is_tuple(cross_thread_relation_scope) and
                tuple_size(cross_thread_relation_scope) == 2 and
                elem(cross_thread_relation_scope, 0) == :same_actor and
                is_binary(elem(cross_thread_relation_scope, 1))) do
    same_thread = not is_nil(current_thread) and episode.destination_thread_ref == current_thread
    cross_thread_scope = normalize_cross_thread_scope(cross_thread_relation_scope, endpoints)

    %__MODULE__{
      allowed_relations:
        allowed_relations(
          episode,
          same_thread,
          now,
          continuation_window,
          cross_thread_scope
        ),
      episode: episode,
      first_input_preview: endpoints |> Map.get(:first) |> preview(),
      latest_input_preview: endpoints |> Map.get(:latest) |> preview(),
      model_state: model_state(episode.state),
      ref: opaque_ref(episode.id),
      same_thread: same_thread
    }
  end

  @spec for_model(t()) :: map()
  def for_model(%__MODULE__{} = candidate) do
    %{
      "allowed_relations" => Enum.map(candidate.allowed_relations, &Atom.to_string/1),
      "episode_ref" => candidate.ref,
      "first_input" => candidate.first_input_preview,
      "latest_input" => candidate.latest_input_preview,
      "same_thread" => candidate.same_thread,
      "state" => candidate.model_state
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
      ~w(allowed_relations episode_id episode_ref first_input latest_input same_thread state)

    with true <- Enum.sort(Map.keys(snapshot)) == Enum.sort(fields),
         true <- snapshot["episode_id"] == episode.id,
         true <- snapshot["episode_ref"] == opaque_ref(episode.id),
         {:ok, relations} <- restore_relations(snapshot["allowed_relations"]),
         true <- is_boolean(snapshot["same_thread"]),
         true <- snapshot["state"] in ~w(active complete cancelled),
         true <- valid_preview?(snapshot["first_input"]),
         true <- valid_preview?(snapshot["latest_input"]) do
      {:ok,
       %__MODULE__{
         allowed_relations: relations,
         episode: episode,
         first_input_preview: snapshot["first_input"],
         latest_input_preview: snapshot["latest_input"],
         model_state: snapshot["state"],
         ref: snapshot["episode_ref"],
         same_thread: snapshot["same_thread"]
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

  defp valid_preview?(nil), do: true

  defp valid_preview?(%{} = preview) do
    Map.keys(preview) |> Enum.sort() == ~w(content_preview occurred_at truncated) and
      is_binary(preview["content_preview"]) and is_binary(preview["occurred_at"]) and
      is_boolean(preview["truncated"])
  end

  defp valid_preview?(_preview), do: false

  defp allowed_relations(
         %Episode{state: :cancelled},
         _same_thread,
         _now,
         _window,
         _cross_thread_scope
       ),
       do: [:history_only]

  defp allowed_relations(_episode, true, _now, _window, _cross_thread_scope),
    do: [:same_work, :history_only]

  defp allowed_relations(_episode, false, _now, _window, :none), do: [:history_only]

  defp allowed_relations(%Episode{state: state}, false, _now, _window, scope)
       when scope in [:all, :active_only] and
              state in [:working, :waiting_for_input, :waiting_for_event],
       do: [:same_work, :history_only]

  defp allowed_relations(%Episode{state: :complete}, false, _now, _window, :active_only),
    do: [:history_only]

  defp allowed_relations(
         %Episode{state: :complete, updated_at: updated_at},
         false,
         now,
         window,
         :all
       ) do
    if DateTime.diff(now, updated_at, :second) <= window,
      do: [:same_work, :history_only],
      else: [:history_only]
  end

  defp model_state(state) when state in [:working, :waiting_for_input, :waiting_for_event],
    do: "active"

  defp model_state(state), do: Atom.to_string(state)

  defp normalize_cross_thread_scope(true, _endpoints), do: :all
  defp normalize_cross_thread_scope(false, _endpoints), do: :none

  defp normalize_cross_thread_scope({:same_actor, actor_ref}, endpoints) do
    if get_in(endpoints, [:first, :payload, "actor_ref"]) == actor_ref,
      do: :all,
      else: :none
  end

  defp normalize_cross_thread_scope(scope, _endpoints), do: scope

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

  defp preview_payload(payload) when is_map(payload), do: payload
  defp preview_payload(payload), do: %{"content" => payload}
end
