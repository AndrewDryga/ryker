defmodule Ryker.Operator.FailureDetail do
  @moduledoc """
  Payload-free projection of stored diagnostics.

  Failure details may contain provider bodies, source content, or credentials.
  Operator surfaces expose presence, a stable digest for log correlation, and
  finite allowlisted protocol facts, never the raw diagnostic.
  """
  alias Ryker.CanonicalJSON

  @coop_codes ~w(invalid_session_state session_cleanup_error revision_conflict session_not_found operation_not_found operation_uncertain idempotency_conflict budget_exhausted unauthorized forbidden)
  @cleanup_operation_codes @coop_codes ++ ~w(internal_error storage_unavailable invalid_request)
  @cleanup_operation ~r/\A\{:coop_cleanup_operation_failed,\s*"[0-9a-f-]{36}",\s*"([a-z_]{1,80})"\}\z/

  @doc "Allowlisted protocol facts only; never copies diagnostic payload text."
  def facts(detail) when is_binary(detail) and byte_size(detail) <= 4_096 do
    case Regex.run(~r/\A\{:coop_error,\s*([1-5]\d{2}),\s*"([a-z_]{1,80})",/, detail) do
      [_, status, code] when code in @coop_codes ->
        %{http_status: String.to_integer(status), code: code}

      _unrecognized ->
        cleanup_operation_facts(detail) || Ryker.PublicationRetry.facts(detail) ||
          closed_pull_request_facts(detail)
    end
  end

  def facts(_detail), do: nil

  defp cleanup_operation_facts(detail) do
    case Regex.run(@cleanup_operation, detail) do
      [_, code] when code in @cleanup_operation_codes -> %{code: code}
      _unrecognized -> nil
    end
  end

  defp closed_pull_request_facts(detail) do
    case closed_pull_request(detail) do
      nil -> nil
      closed -> %{closed_pull_request: closed}
    end
  end

  # Coop's `closed_pull_request`, as `Ryker.CoopFleet.Client` saved it: a number and a GitHub
  # pull request URL, both checked before they were saved, and checked again here because the
  # detail is free text.
  @closed_pull_request ~r<\A\{:publication_branch_has_closed_pull_request, ([1-9][0-9]{0,9}), (?:"(https://[A-Za-z0-9.-]+/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]+)"|nil)\}\z>

  @doc "The closed pull request a `publication_branch_has_closed_pull_request` refusal named, or nil."
  @spec closed_pull_request(String.t() | nil) ::
          %{number: pos_integer(), url: String.t() | nil} | nil
  def closed_pull_request(detail) when is_binary(detail) and byte_size(detail) <= 1_200 do
    case Regex.run(@closed_pull_request, detail) do
      [_, number] -> %{number: String.to_integer(number), url: nil}
      [_, number, url] -> %{number: String.to_integer(number), url: url}
      nil -> nil
    end
  end

  def closed_pull_request(_detail), do: nil

  @spec project(String.t() | nil) :: String.t() | nil
  def project(nil), do: nil

  def project(detail) when is_binary(detail) do
    "stored diagnostic sha256:" <> CanonicalJSON.digest(detail)
  end
end
