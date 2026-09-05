defmodule Responder.Operator.FailureDetail do
  @moduledoc """
  Payload-free projection of stored diagnostics.

  Failure details may contain provider bodies, source content, or credentials.
  Operator surfaces expose presence, a stable digest for log correlation, and
  finite allowlisted protocol facts, never the raw diagnostic.
  """

  alias Responder.CanonicalJSON

  @coop_codes ~w(invalid_session_state session_cleanup_error revision_conflict session_not_found operation_not_found operation_uncertain idempotency_conflict unauthorized forbidden)
  @legacy_ownership ~s({:coop_error, 409, "invalid_session_state", "legacy remote session has no immutable fork ownership proof; recreate the session after preserving its workspace"})

  @doc "Allowlisted protocol facts only; never copies diagnostic payload text."
  def facts(detail) when is_binary(detail) and byte_size(detail) <= 4_096 do
    case Regex.run(~r/\A\{:coop_error,\s*([1-5]\d{2}),\s*"([a-z_]{1,80})",/, detail) do
      [_, status, code] when code in @coop_codes ->
        %{
          http_status: String.to_integer(status),
          code: code,
          reason: if(detail == @legacy_ownership, do: :missing_ownership)
        }

      _unrecognized ->
        nil
    end
  end

  def facts(_detail), do: nil

  @spec project(String.t() | nil) :: String.t() | nil
  def project(nil), do: nil

  def project(detail) when is_binary(detail) do
    "stored diagnostic sha256:" <> CanonicalJSON.digest(detail)
  end
end
