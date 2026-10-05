defmodule Ryker.Evals.Job do
  @moduledoc """
  Explicit eval targets with fixed, empty-workspace authority.

  Never reads installation settings or accepts repository, project or network
  grants. The worker validates the target grammar; the controller computes the
  complete immutable job and its digest, with no operator-maintained digest.

  The one repository an eval job may read is a world scenario's own captured
  checkout, staged for the eval Coop by `Ryker.Evals.WorldSource` and always
  read-only (`with_source/2`).
  """

  alias Ryker.CoopFleet.{JobSpec, JobTemplates}

  @variables %{
    judge: "RYKER_EVAL_JUDGE_TARGET",
    world: "RYKER_EVAL_WORLD_TARGET",
    baseline: "RYKER_EVAL_BASELINE_TARGET",
    routing: "RYKER_EVAL_ROUTING_TARGET",
    improvement: "RYKER_EVAL_IMPROVEMENT_TARGET"
  }

  @doc "The variables that name an eval's Coop socket and its targets."
  @spec variables() :: [String.t()]
  def variables, do: ["RYKER_EVAL_SOCKET" | Map.values(@variables)]

  def socket do
    case System.fetch_env("RYKER_EVAL_SOCKET") do
      {:ok, socket} ->
        if Path.type(socket) == :absolute,
          do: {:ok, socket},
          else: {:error, :model_eval_socket_must_be_absolute}

      :error ->
        {:error, :model_eval_socket_not_configured}
    end
  end

  def world do
    with {:ok, judge} <- required(:judge),
         {:ok, subject} <- required(:world),
         {:ok, baseline} <- optional(:baseline) do
      {:ok, %{judge: judge, subject: subject, baseline: baseline}}
    end
  end

  @doc "The model routing replays ask (`Ryker.Evals.RoutingReplay`), named explicitly."
  def routing, do: required(:routing)

  @doc "The model self-analysis replays ask (`Ryker.Evals.ImprovementReplay`), named explicitly."
  def improvement, do: required(:improvement)

  def new(kind, target)
      when kind in [:judge, :world, :baseline, :learning, :routing, :improvement] do
    if is_binary(target) and String.valid?(target) and byte_size(target) in 1..256 and
         not Regex.match?(~r/\s|\x00/u, target) do
      name = "ryker-eval-#{kind}"

      document =
        %{learning_models: [target]}
        |> JobTemplates.execution(:learning, false)
        |> Map.merge(%{"version" => 2, "job_ref" => name, "source" => nil, "companions" => []})

      with {:ok, digest} <- JobSpec.digest(document),
           do: {:ok, %{name: name, digest: digest, document: document}}
    else
      {:error, :invalid_model_eval_target}
    end
  end

  def new(_kind, _target), do: {:error, :invalid_model_eval_kind}

  @doc """
  The same world job, reading one staged scenario checkout (`Ryker.Evals.WorldSource`). Only a
  staged source qualifies, never a real GitHub repository, and the checkout stays read-only.
  """
  def with_source(
        %{name: "ryker-eval-" <> kind = name, document: document},
        %{"github_repository" => "ryker-eval/" <> _staged} = source
      )
      when kind in ["world", "baseline"] do
    document = Map.put(document, "source", source)

    if document["repository_read_only"] == true do
      with {:ok, digest} <- JobSpec.digest(document),
           do: {:ok, %{name: name, digest: digest, document: document}}
    else
      {:error, :invalid_model_eval_job}
    end
  end

  def with_source(_template, _source), do: {:error, :invalid_model_eval_job}

  def bind(%{name: name, digest: digest, document: document}, reference) when is_map(document) do
    with [target] <- document["targets"],
         kind when not is_nil(kind) <-
           Enum.find(
             [:judge, :world, :baseline, :learning, :routing, :improvement],
             &(name == "ryker-eval-#{&1}")
           ),
         {:ok, template} <- new(kind, target),
         {:ok, %{document: ^document, digest: ^digest}} <- sourced(template, document["source"]),
         {:ok, job, digest} <- JobSpec.rebind(document, digest, reference) do
      {:ok, job, digest}
    else
      _invalid -> {:error, :invalid_model_eval_job}
    end
  end

  def bind(_template, _reference), do: {:error, :invalid_model_eval_job}

  defp sourced(template, nil), do: {:ok, template}
  defp sourced(template, source), do: with_source(template, source)

  defp required(kind) do
    case optional(kind) do
      {:ok, nil} -> {:error, :model_eval_targets_not_configured}
      result -> result
    end
  end

  defp optional(kind) do
    case System.fetch_env(Map.fetch!(@variables, kind)) do
      {:ok, target} -> new(kind, target)
      :error -> {:ok, nil}
    end
  end
end
