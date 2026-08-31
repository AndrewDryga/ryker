defmodule Responder.Cutover.LegacySchema do
  @moduledoc """
  Exact legacy Go schema accepted by the one-time replacement cutover.

  The digest covers every non-SQLite object returned from `sqlite_schema`, in
  canonical `(table, type, name)` order. Updating this contract is a deliberate
  cutover change, never an automatic consequence of seeing a positive schema
  version.
  """

  @version 90
  @sha256 "e9aaa44b42dac7b2afe4e5740bcf6e4d24b9f93c2c2182781374e12e6643c535"

  @spec version() :: pos_integer()
  def version, do: @version

  @spec sha256() :: String.t()
  def sha256, do: @sha256

  @spec supported?(term(), term()) :: boolean()
  def supported?(@version, @sha256), do: true
  def supported?(_version, _sha256), do: false
end
