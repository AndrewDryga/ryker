defmodule Mix.Tasks.Ryker.ImportConfiguration do
  @moduledoc """
  Imports one retired application YAML into durable settings, exactly once.

      MIX_ENV=prod mix ryker.import_configuration /absolute/path/ryker-elixir.yaml
      MIX_ENV=prod mix ryker.import_configuration /absolute/path/ryker-elixir.yaml --apply

  Without `--apply` this is a read-only dry run: it prints the redacted semantic
  plan — every setting and the row that will hold it, the deployment variables
  the new contract needs, the credential names it remaps, the non-default tuning
  a shipped default now replaces, the retired declarations, the changed effects
  and the per-channel participation the four old layers resolve to — and writes
  nothing. Run it first and read it.

  `--apply` writes that plan in one transaction under the installation identity
  the document names, so existing worker, delivery and publication custody is not
  re-keyed, and records a content-safe receipt. Rerunning the same document
  reports `already_applied`; a changed document, or settings edited after the
  import, is a conflict and nothing is overwritten.

  No value from the document is ever printed as a credential: only credential
  *names* appear, and the process environment is never enumerated. The importer
  starts no platform adapter and contacts no model. Normal startup never reaches
  it.
  """

  use Mix.Task

  alias Mix.Tasks.Ryker.OperatorSupport, as: Support
  alias Ryker.{Bootstrap, Settings}
  alias Ryker.Settings.Import

  @shortdoc "Dry-runs, or with --apply performs, the one-time configuration import"

  @impl Mix.Task
  def run(arguments) do
    case Support.parse(arguments, [apply: :boolean], 1) do
      {:ok, options, [path]} -> print_result(import_configuration(path, options))
      {:error, reason} -> Support.fail("configuration import", reason)
    end
  end

  defp import_configuration(path, options) do
    Support.with_repo(fn ->
      bootstrap = Bootstrap.load!()

      if Keyword.get(options, :apply, false),
        do: Import.apply_plan(path, bootstrap, Settings.actor()),
        else: dry_run(path, bootstrap)
    end)
  end

  defp dry_run(path, bootstrap) do
    with {:ok, plan} <- Import.plan(path, bootstrap), do: {:ok, Import.document(plan)}
  end

  defp print_result({:ok, outcome}), do: Support.print(Settings.stringify(outcome))
  defp print_result({:error, reason}), do: Support.fail("configuration import", reason)
end
