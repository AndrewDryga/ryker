defmodule Responder.Webhooks.Preview do
  @moduledoc """
  Checks a saved webhook source against a sample payload, and does nothing else.

  The preview runs the same bounded transform the live route runs, then stops:
  it records no ingress entry, opens no incident, submits no model work and
  sends nothing anywhere. It cannot, structurally — the route it builds has no
  Work profile and a credential it never uses, so there is nothing for a
  preview to authorize or spend.

  A failure names the field that could not be mapped, which is the answer an
  operator needs before an incident depends on the mapping.
  """

  alias Responder.Webhooks.{Route, Transforms}

  @maximum_bytes 40_000
  @preview_secret String.duplicate("preview", 8)

  @type mapped :: %{
          event_ref: String.t(),
          occurred_at: DateTime.t(),
          revision: pos_integer(),
          summary: map()
        }

  @spec check(struct(), String.t(), DateTime.t()) ::
          {:ok, [mapped()]} | {:error, atom() | tuple()}
  def check(source, body, now \\ DateTime.utc_now())

  def check(source, body, now) when is_binary(body) do
    with :ok <- bounded(body),
         {:ok, payload} <- decode(body),
         {:ok, route} <- route(source),
         {:ok, %{inputs: inputs}} <- Transforms.normalize(route, payload, metadata(now)) do
      {:ok, Enum.map(inputs, &mapped/1)}
    end
  end

  def check(_source, _body, _now), do: {:error, :invalid_sample}

  defp bounded(body) do
    if byte_size(body) in 1..@maximum_bytes, do: :ok, else: {:error, :sample_too_large}
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, payload} -> {:ok, payload}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  # The route mirrors the saved source except for the two fields a preview must
  # not carry: a real credential and a Work profile.
  defp route(source) do
    Route.new(%{
      adapter: adapter(source),
      auth: {source.auth_kind, @preview_secret},
      destination: %{
        conversation_ref: source.destination_conversation_ref,
        thread_ref: source.destination_thread_ref,
        transport: source.destination_transport
      },
      name: source.name,
      publication_lifecycle: lifecycle(source.publication_lifecycle),
      work_profile: nil
    })
  end

  defp adapter(%{adapter_kind: :universal}), do: %{kind: :universal}

  defp adapter(%{adapter_kind: :grafana} = source),
    do: %{kind: :grafana, group_by_labels: source.group_by_labels}

  defp adapter(%{adapter_kind: :mapped_json} = source) do
    %{
      kind: :mapped_json,
      group_by_labels: source.group_by_labels,
      mapping: Map.new(source.mapping || %{}, fn {field, path} -> {field(field), path} end)
    }
  end

  defp field(name) when is_binary(name), do: String.to_existing_atom(name)
  defp field(name) when is_atom(name), do: name

  defp lifecycle(nil), do: nil

  defp lifecycle(scope) do
    Map.new(~w(environments kinds repositories targets), fn field ->
      {String.to_existing_atom(field), Map.get(scope, field, [])}
    end)
  end

  # Identity a signed request would supply in headers. Named, not invented: a
  # mapped source reads its own identity out of the payload instead.
  defp metadata(now) do
    [
      event_id: "preview",
      event_type: nil,
      item_id: "preview",
      occurred_at: now,
      occurred_at_source: :ingress,
      revision: 1
    ]
  end

  defp mapped(input) do
    %{
      event_ref: input.event_ref,
      occurred_at: input.occurred_at,
      revision: input.revision,
      summary: input.content
    }
  end
end
