defmodule Ryker.Evals.Policy do
  @moduledoc """
  Dedicated evaluation authority, supplied explicitly and never inherited.

  Eval policies come from the evaluation environment, not from the product's
  durable settings: an eval must not be able to acquire production repository or
  mutation authority by reading the installation it happens to run beside. The
  resolver refuses any policy whose name or digest matches a reviewed production
  binding present in the database it is pointed at.
  """

  import Ecto.Query

  alias Ryker.Repo
  alias Ryker.Settings.PolicyBinding

  @type authority :: %{name: String.t(), digest: String.t()}
  @type selection :: %{
          baseline: authority() | nil,
          judge: authority(),
          subject: authority()
        }

  @variables %{
    no_tools: "RYKER_EVAL_NO_TOOLS_POLICY",
    world: "RYKER_EVAL_WORLD_POLICY",
    world_baseline: "RYKER_EVAL_WORLD_BASELINE_POLICY"
  }

  @doc "The eval socket the dedicated evaluation Coop listens on."
  @spec socket() :: {:ok, Path.t()} | {:error, atom()}
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

  @doc """
  The world lane's authorities: the sandbox-only subject policy, the tool-free
  no-tools policy its quality judge runs under, and the optional pinned
  baseline for paired qualification.
  """
  @spec for_kind(:world) :: {:ok, selection()} | {:error, atom()}
  def for_kind(:world) do
    with {:ok, no_tools} <- policy(:no_tools),
         {:ok, world} <- policy(:world),
         {:ok, baseline} <- optional_policy(:world_baseline),
         :ok <- distinct([no_tools, world, baseline]) do
      {:ok, %{baseline: baseline, judge: no_tools, subject: world}}
    end
  end

  def for_kind(_kind), do: {:error, :invalid_model_eval_kind}

  defp policy(name) do
    case optional_policy(name) do
      {:ok, nil} -> {:error, :model_eval_policies_not_configured}
      other -> other
    end
  end

  defp optional_policy(name) do
    variable = Map.fetch!(@variables, name)

    case System.fetch_env(variable) do
      :error -> {:ok, nil}
      {:ok, value} -> authority(value, variable <> "_DIGEST")
    end
  end

  defp authority(name, digest_variable) do
    digest = System.get_env(digest_variable)

    cond do
      not (is_binary(name) and String.trim(name) != "" and byte_size(name) <= 256) ->
        {:error, :invalid_model_eval_policy}

      not (is_binary(digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)) ->
        {:error, :invalid_model_eval_policy_digest}

      true ->
        isolated(%{digest: digest, name: name})
    end
  end

  # Production authority is never an eval authority, whichever database this is
  # pointed at.
  defp isolated(%{name: name, digest: digest} = authority) do
    reused? =
      Repo.exists?(
        from(binding in PolicyBinding,
          where: binding.policy_name == ^name or binding.policy_digest == ^digest
        )
      )

    if reused?, do: {:error, :model_eval_reuses_production_authority}, else: {:ok, authority}
  rescue
    # An eval may run before any settings exist; that is isolation, not failure.
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> {:ok, authority}
  end

  defp distinct(policies) do
    present = Enum.reject(policies, &is_nil/1)
    names = Enum.map(present, & &1.name)
    digests = Enum.map(present, & &1.digest)

    if Enum.uniq(names) == names and Enum.uniq(digests) == digests,
      do: :ok,
      else: {:error, :model_eval_policies_must_be_distinct}
  end
end
