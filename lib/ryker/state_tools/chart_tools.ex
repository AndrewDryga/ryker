defmodule Ryker.StateTools.ChartTools do
  @moduledoc false
  alias Ryker.Artifacts
  alias Ryker.CanonicalJSON
  alias Ryker.Charts
  alias Ryker.Crypto
  alias Ryker.Repo
  alias Ryker.StateTools.Binding

  @doc "Render locally and retain a chart under the current turn's authority."
  @spec render_chart(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def render_chart(arguments, binding, options \\ []) do
    ref = "artifact:chart:" <> CanonicalJSON.digest(arguments)

    with {:ok, existing} <- authorized_existing(binding, ref) do
      case existing do
        [artifact] -> {:ok, result(artifact)}
        [] -> render_and_store(arguments, binding, ref, options)
      end
    end
  end

  defp authorized_existing(binding, ref) do
    Repo.transaction(fn ->
      case fetch_and_lock_renderable(binding) do
        {:ok, current} -> existing_or_capacity!(current.turn.id, ref)
        _denied -> Repo.rollback(:unauthorized)
      end
    end)
  end

  defp existing_or_capacity!(turn_id, ref) do
    case Artifacts.Outputs.fetch_many(turn_id, [ref]) do
      {:ok, artifacts} ->
        artifacts

      {:error, :work_output_artifact_not_found} ->
        if length(Artifacts.Outputs.chart_metadata(turn_id)) < 5,
          do: [],
          else: Repo.rollback(:chart_limit_reached)
    end
  end

  defp fetch_and_lock_renderable(binding) do
    with {:ok, current} <- Binding.fetch_and_lock_current(binding),
         true <- Artifacts.Outputs.delivery_supported?(current.episode),
         true <- writable?(current.turn) do
      {:ok, current}
    else
      _denied -> {:error, :unauthorized}
    end
  end

  defp render_and_store(arguments, binding, ref, options) do
    with {:ok, png} <- Charts.render(arguments, options) do
      metadata = %{
        "id" => ref,
        "name" => filename(arguments["title"]),
        "media_type" => "image/png",
        "sha256" => Crypto.sha256_hex(png),
        "bytes" => byte_size(png)
      }

      store_chart(binding, metadata, png)
    end
  end

  # Render outside the transaction, then recheck the lease and capacity
  # under the same session lock used by other state-tool writes.
  defp store_chart(binding, metadata, png) do
    Repo.transaction(fn ->
      case fetch_and_lock_renderable(binding) do
        {:ok, current} -> store_or_reuse!(current.turn.id, metadata, png)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp store_or_reuse!(turn_id, metadata, png) do
    existing = Artifacts.Outputs.chart_metadata(turn_id)

    case Enum.find(existing, &(&1["sha256"] == metadata["sha256"])) do
      %{"id" => ref} ->
        {:ok, [artifact]} = Artifacts.Outputs.fetch_many(turn_id, [ref])
        result(artifact)

      nil ->
        put_chart!(turn_id, existing ++ [metadata], metadata, png)
    end
  end

  defp put_chart!(turn_id, all_metadata, metadata, png) do
    with {:ok, _metadata} <- Artifacts.Outputs.prepare_metadata(all_metadata),
         {:ok, [artifact]} <-
           Artifacts.Outputs.put_many(turn_id, [Map.put(metadata, "data", png)]) do
      result(artifact)
    else
      {:error, {:invalid_work_output_artifacts, _field}} -> Repo.rollback(:chart_limit_reached)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp result(artifact) do
    %{
      "artifact_ref" => artifact.ref,
      "name" => artifact.name,
      "media_type" => artifact.media_type
    }
  end

  defp writable?(turn),
    do: is_nil(turn.validation_intent) or turn.validation_intent["verdict"] != "accept"

  defp filename(title) do
    title
    |> String.replace(~r/[\x00-\x1F\x7F\/\\]/u, " ")
    |> Ryker.Text.cut(180)
    |> Kernel.<>(".png")
  end

  @doc "The public chart description, with bounded rows and labels."
  @spec tool() :: map()
  def tool do
    label = %{"type" => "string", "minLength" => 1, "maxLength" => 100}
    number = %{"type" => "number", "minimum" => -1.0e15, "maximum" => 1.0e15}
    value = %{"anyOf" => [label, number]}

    %{
      "name" => "render_chart",
      "description" =>
        "Create a PNG chart from observed inline data. type: line (x is an ISO date or timestamp, y a number), bar (x category, y number), histogram (x numeric samples), heatmap (x/y categories, value number), scatter (x/y numbers). Optional series groups line, bar or scatter points; use it on every row or none, at most six series. At most 500 rows and 24 categories per axis. Bar rows must be unique by x/series and heatmap rows by x/y; aggregate observations explicitly before rendering. title describes the chart; x_label and y_label include units, and histogram y_label describes the count. Keep heatmap value units in the title. Returns artifact_ref immediately: include it in the final outcome.artifact_refs. Summarize the result and cite the underlying observations in the reply, which also supplies the attachment's accessible description. A chart itself is not evidence. No URLs, code, file paths or external service are needed.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ~w(type title x_label y_label data),
        "properties" => %{
          "type" => %{"type" => "string", "enum" => ~w(line bar histogram heatmap scatter)},
          "title" => label,
          "x_label" => label,
          "y_label" => label,
          "data" => %{
            "type" => "array",
            "minItems" => 1,
            "maxItems" => 500,
            "items" => %{
              "type" => "object",
              "additionalProperties" => false,
              "required" => ["x"],
              "properties" => %{"x" => value, "y" => value, "series" => label, "value" => number}
            }
          }
        }
      }
    }
  end
end
