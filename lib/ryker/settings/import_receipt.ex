defmodule Ryker.Settings.ImportReceipt do
  @moduledoc """
  Content-safe proof that one retired configuration document was imported.

  The receipt holds fingerprints, the resulting settings revision, the actor and
  the time. It never holds a value from the source, so exporting it cannot leak
  a credential reference, a policy digest or an operator identity.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "settings_import_receipts" do
    field(:source_fingerprint, :string)
    field(:plan_fingerprint, :string)
    field(:host_ref, :string)
    field(:revision, :integer)
    field(:actor_ref, :string)
    field(:inserted_at, :utc_datetime_usec)
  end
end
