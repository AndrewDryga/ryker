defmodule Responder.ControlPlane.SettingsView do
  @moduledoc """
  What the settings page reads: the durable snapshot plus the deployment facts
  an operator needs to interpret it.

  Credentials appear as configured, missing or invalid — never as values — and
  a database that cannot be read is reported as unavailable rather than as an
  installation without settings. The two are different problems and only one of
  them is fixed by filling in a form.
  """

  alias Responder.{Bootstrap, Settings}
  alias Responder.Settings.WorkerPolicies

  @type t :: %{
          snapshot: Settings.snapshot(),
          host_ref: String.t(),
          revision: pos_integer(),
          applied_revision: non_neg_integer(),
          application: :applied | :pending | {:failed, atom()},
          saved_by: String.t(),
          saved_at: DateTime.t(),
          credentials: [map()],
          webhook_secret_names: [String.t()] | :invalid,
          workers: WorkerPolicies.catalog()
        }

  @spec fetch() :: {:ok, t()} | {:error, :settings_not_initialized | :settings_unavailable}
  def fetch do
    case Settings.fetch() do
      {:ok, snapshot} -> {:ok, view(snapshot)}
      {:error, :settings_not_initialized} -> {:error, :settings_not_initialized}
    end
  rescue
    # A table that is mid-migration, a connection that died and a domain row
    # that is somehow missing are all "could not be read". None of them is an
    # installation without settings, and treating them as one would offer to
    # create a second identity over live history.
    _error in [DBConnection.ConnectionError, Ecto.NoResultsError, Postgrex.Error] ->
      {:error, :settings_unavailable}
  end

  @doc "The view for a snapshot the caller already holds, after a save."
  @spec view(Settings.snapshot()) :: t()
  def view(%{installation: installation} = snapshot) do
    %{
      snapshot: snapshot,
      host_ref: installation.host_ref,
      revision: installation.revision,
      applied_revision: installation.applied_revision,
      application: Settings.application_status(snapshot),
      saved_by: installation.saved_by,
      saved_at: installation.saved_at,
      credentials: Bootstrap.credential_status(),
      webhook_secret_names: registered_secret_names(),
      workers: WorkerPolicies.catalog(snapshot.work.workspace_ref)
    }
  end

  defp registered_secret_names do
    case Bootstrap.registered_webhook_secret_names() do
      {:ok, names} -> names
      :error -> :invalid
    end
  end
end
