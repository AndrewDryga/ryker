defmodule Responder.Operator.FailureDetail do
  @moduledoc """
  Payload-free projection of stored diagnostics.

  Failure details may contain provider bodies, source content, or credentials.
  Operator surfaces expose presence and a stable digest for log correlation,
  never the raw diagnostic.
  """

  alias Responder.CanonicalJSON

  @spec project(String.t() | nil) :: String.t() | nil
  def project(nil), do: nil

  def project(detail) when is_binary(detail) do
    "stored diagnostic sha256:" <> CanonicalJSON.digest(detail)
  end
end
