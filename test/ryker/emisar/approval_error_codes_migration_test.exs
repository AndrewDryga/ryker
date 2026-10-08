defmodule Ryker.Emisar.ApprovalErrorCodesMigrationTest do
  # An approval watch kept what stopped it only as a printed term, and the
  # queries and the Failures page matched the text (2026-10-04 review). The
  # migration gives every saved term the code the host derives from the term
  # itself; this holds the two to the same answer for every kind of reason.
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL
  alias Ryker.Emisar.Approvals
  alias Ryker.ErrorDetail

  @version 20_261_007_140_000

  test "a saved error reads as the code the host now saves beside it" do
    reasons = [
      {:delivery_credentials_unavailable, :credential_missing},
      {:delivery_credentials_unavailable, :credential_decryption_failed},
      {:emisar_http_error, 401, "unauthorized"},
      {:emisar_http_error, 403, String.duplicate("forbidden ", 40)},
      {:emisar_protocol_error, :review},
      {:emisar_protocol_error, :run_url},
      {:emisar_protocol_error, {:api_result, %{"unexpected" => true}}},
      {:invalid_emisar_client, :rpc_origin},
      :emisar_approval_identity_mismatch,
      {:emisar_approval_presentation_permanent, :message_not_found},
      {:timeout, :emisar}
    ]

    code =
      "SELECT #{migration(@version).code_sql()} FROM (SELECT $1::text AS last_error) AS saved"

    for reason <- reasons do
      %{rows: [[saved]]} = SQL.query!(Repo, code, [ErrorDetail.detail(reason)])
      assert saved == Approvals.error_code(reason), inspect(reason)
    end

    assert migrate_down(@version) == :ok
    refute "last_error_code" in columns()

    assert migrate_up(@version) == :ok
    assert "last_error_code" in columns()
  end

  defp columns do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_name = 'episode_emisar_approvals'",
        []
      )

    List.flatten(rows)
  end
end
