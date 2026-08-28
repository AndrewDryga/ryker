defmodule Responder.Slack.Admission.Candidate do
  @moduledoc """
  A bounded episode option the host permits the model to select.

  The model sees only the opaque reference and the context needed to judge the
  relationship. Database identity, episode key, and Slack destination remain
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
    :ref,
    :same_thread
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          allowed_relations: [:same_work | :history_only],
          episode: Episode.t(),
          first_input_preview: map() | nil,
          latest_input_preview: map() | nil,
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
    same_thread = episode.destination_thread_ref == current_thread

    %__MODULE__{
      allowed_relations: allowed_relations(episode, same_thread, now, continuation_window),
      episode: episode,
      first_input_preview: endpoints |> Map.get(:first) |> preview(),
      latest_input_preview: endpoints |> Map.get(:latest) |> preview(),
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
      "state" => model_state(candidate.episode.state)
    }
  end

  defp allowed_relations(%Episode{state: :cancelled}, _same_thread, _now, _window),
    do: [:history_only]

  defp allowed_relations(_episode, true, _now, _window),
    do: [:same_work, :history_only]

  defp allowed_relations(%Episode{state: state}, false, _now, _window)
       when state in [:working, :waiting_for_input, :waiting_for_event],
       do: [:same_work, :history_only]

  defp allowed_relations(%Episode{state: :complete, updated_at: updated_at}, false, now, window) do
    if DateTime.diff(now, updated_at, :second) <= window,
      do: [:same_work, :history_only],
      else: [:history_only]
  end

  defp model_state(state) when state in [:working, :waiting_for_input, :waiting_for_event],
    do: "active"

  defp model_state(state), do: Atom.to_string(state)

  defp opaque_ref(episode_id) do
    digest = CanonicalJSON.digest(["slack-admission-candidate", episode_id])
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
