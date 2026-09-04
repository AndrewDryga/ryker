defmodule Responder.Publication.DeploymentSignal do
  @moduledoc """
  Strict adapter contract for deployment and Terraform verification signals.

  Authentication belongs to the ingress adapter. This module validates the
  normalized content only; arbitrary provider payloads and prose are never
  interpreted as deployment evidence.
  """

  @event_type "responder.publication_lifecycle.v1"
  @payload_fields ~w(environment kind references repository run_ref state target)
  @kinds ~w(deployment terraform)
  @states ~w(pending succeeded failed)

  @spec prepare(map()) :: {:ok, map()} | {:error, term()}
  def prepare(%{"event_type" => @event_type, "payload" => payload} = content)
      when map_size(content) == 2 and is_map(payload) do
    with true <- Enum.sort(Map.keys(payload)) == Enum.sort(@payload_fields),
         :ok <- member(payload["kind"], @kinds, :kind),
         :ok <- member(payload["state"], @states, :state),
         :ok <- reference(payload["environment"], :environment, 256),
         :ok <- reference(payload["repository"], :repository, 256),
         :ok <- reference(payload["run_ref"], :run_ref, 1_024),
         :ok <- reference(payload["target"], :target, 1_024),
         {:ok, references} <- references(payload["references"]) do
      {:ok,
       %{
         "event_type" => @event_type,
         "payload" => %{
           "environment" => payload["environment"],
           "kind" => payload["kind"],
           "references" => references,
           "repository" => payload["repository"],
           "run_ref" => payload["run_ref"],
           "state" => payload["state"],
           "target" => payload["target"]
         }
       }}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, {:invalid_publication_deployment_signal, :fields}}
    end
  end

  def prepare(_content),
    do: {:error, {:invalid_publication_deployment_signal, :fields}}

  @spec authorize(map(), map()) :: :ok | {:error, term()}
  def authorize(
        %{"payload" => payload},
        %{
          "environments" => environments,
          "kinds" => kinds,
          "repositories" => repositories,
          "targets" => targets
        }
      ) do
    if payload["environment"] in environments and payload["kind"] in kinds and
         payload["repository"] in repositories and payload["target"] in targets,
       do: :ok,
       else: {:error, :publication_lifecycle_source_unauthorized}
  end

  def authorize(_signal, _capability),
    do: {:error, :publication_lifecycle_source_unauthorized}

  defp references(values) when is_list(values) and length(values) in 1..34 do
    with true <- Enum.uniq(values) == values,
         :ok <- Enum.reduce_while(values, :ok, &validate_reference/2) do
      {:ok, values}
    else
      {:error, _reason} = error -> error
      false -> {:error, {:invalid_publication_deployment_signal, :references}}
    end
  end

  defp references(_values),
    do: {:error, {:invalid_publication_deployment_signal, :references}}

  defp validate_reference(value, :ok) do
    case reference(value, :references, 2_048) do
      :ok -> {:cont, :ok}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp member(value, allowed, field) do
    if value in allowed,
      do: :ok,
      else: {:error, {:invalid_publication_deployment_signal, field}}
  end

  defp reference(value, field, maximum)
       when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= maximum do
    if String.valid?(value) and String.trim(value) != "" and
         :binary.match(value, <<0>>) == :nomatch,
       do: :ok,
       else: {:error, {:invalid_publication_deployment_signal, field}}
  end

  defp reference(_value, field, _maximum),
    do: {:error, {:invalid_publication_deployment_signal, field}}
end
