defmodule Ryker.Admission.Occurrences do
  @moduledoc """
  Occurrence identities an adapter actually authenticated.

  A trusted claim must identify the same occurrence or work object, not merely
  mention it. GitHub items and typed publication-lifecycle signals arrive with
  an identity and a lifecycle state the adapter itself resolved, so they may be
  claimed. A Slack message reference identifies a message, not an incident, and
  a service name, alert rule, URL or old incident id inside app text is a clue
  for ranking, never an exclusive claim — so this returns nothing for them.
  """

  alias Ryker.Ingress.Input
  alias Ryker.Publication.DeploymentSignal

  @type occurrence :: %{
          namespace: String.t(),
          occurrence_ref: String.t(),
          lifecycle_state: :active | :terminal
        }

  @spec for_input(Input.t()) :: [occurrence()]
  def for_input(%Input{
        source: %{kind: "github", ref: binding},
        source_item_ref: "github:" <> _ = item
      })
      when is_binary(binding) do
    [%{namespace: "github:#{binding}", occurrence_ref: item, lifecycle_state: :active}]
  end

  def for_input(
        %Input{
          actor: %{kind: :system},
          source: %{kind: "webhook"},
          source_capabilities: %{"publication_lifecycle" => authority}
        } = input
      ) do
    with {:ok, signal} <- DeploymentSignal.prepare(input.content),
         :ok <- DeploymentSignal.authorize(signal, authority) do
      payload = signal["payload"]

      [
        %{
          namespace: "publication:#{payload["kind"]}:#{payload["repository"]}",
          occurrence_ref: payload["run_ref"],
          lifecycle_state: lifecycle_state(payload["state"])
        }
      ]
    else
      _untrusted_or_untyped -> []
    end
  end

  def for_input(%Input{}), do: []

  @doc "The security domain a claim is scoped to; identities never cross it."
  @spec scope_ref(Input.t()) :: String.t()
  def scope_ref(%Input{source: %{kind: kind, ref: ref}}), do: "#{kind}:#{ref}"

  # Only the adapter's own vocabulary decides that a run is over. One run
  # finishing says nothing about the other signals of the same incident.
  defp lifecycle_state("pending"), do: :active
  defp lifecycle_state(_succeeded_or_failed), do: :terminal
end
