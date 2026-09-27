defmodule Ryker.Evals.Job do
  @moduledoc """
  Explicit eval targets with fixed, empty-workspace authority.

  Never reads installation settings or accepts repository, project or network
  grants. The worker validates the target grammar; the controller computes the
  complete immutable job and its digest, with no operator-maintained digest.
  """

  alias Ryker.CoopFleet.{JobSpec, JobTemplates}

  @variables %{
    judge: "RYKER_EVAL_JUDGE_TARGET",
    world: "RYKER_EVAL_WORLD_TARGET",
    baseline: "RYKER_EVAL_BASELINE_TARGET"
  }

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

  def new(kind, target) when kind in [:judge, :world, :baseline, :learning] do
    if is_binary(target) and String.valid?(target) and byte_size(target) in 1..256 and
         not Regex.match?(~r/\s|\x00/u, target) do
      name = "ryker-eval-#{kind}"

      document =
        %{learning_models: [target]}
        |> JobTemplates.execution(:learning, false)
        |> Map.merge(%{"version" => 1, "job_ref" => name, "source" => nil, "companions" => []})

      with {:ok, digest} <- JobSpec.digest(document),
           do: {:ok, %{name: name, digest: digest, document: document}}
    else
      {:error, :invalid_model_eval_target}
    end
  end

  def new(_kind, _target), do: {:error, :invalid_model_eval_kind}

  def bind(%{name: name, digest: digest, document: document}, reference) when is_map(document) do
    with [target] <- document["targets"],
         kind when not is_nil(kind) <-
           Enum.find([:judge, :world, :baseline, :learning], &(name == "ryker-eval-#{&1}")),
         {:ok, %{document: ^document, digest: ^digest}} <- new(kind, target),
         {:ok, job, digest} <- JobSpec.rebind(document, digest, reference) do
      {:ok, job, digest}
    else
      _invalid -> {:error, :invalid_model_eval_job}
    end
  end

  def bind(_template, _reference), do: {:error, :invalid_model_eval_job}

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
