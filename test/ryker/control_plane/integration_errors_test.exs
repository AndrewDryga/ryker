defmodule Ryker.ControlPlane.IntegrationErrorsTest do
  @moduledoc """
  QA, 2026-09-25: connecting an integration that refused answered
  "Connection could not be verified (account_identity_unavailable)" and
  "Connection could not be verified (app_token)": an internal code in
  brackets, and nothing about what to change. Every refusal the connection
  pages can meet is said as a plain sentence that names what to do next.
  """
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.IntegrationErrors

  # Every refusal `Ryker.IntegrationSetup` and the credential store return to
  # the Slack, GitHub, Emisar and webhook pages.
  @refusals [
    {:invalid_credential, :app_token},
    {:invalid_credential, :swapped_tokens},
    {:invalid_credential, :bot_token},
    {:invalid_credential, :token},
    {:invalid_credential, :ref},
    {:invalid_credential, :display_name},
    {:slack_verification_failed, :socket_mode},
    {:slack_verification_failed, "invalid_auth"},
    {:slack_verification_failed, "not_authed"},
    {:slack_verification_failed, "token_revoked"},
    {:slack_verification_failed, "account_inactive"},
    {:slack_verification_failed, "not_allowed_token_type"},
    {:slack_verification_failed, "ratelimited"},
    {:slack_verification_failed, :response},
    {:slack_verification_failed, :identity},
    {:slack_verification_failed, :auth},
    {:slack_verification_failed, :members},
    {:slack_missing_scopes, ["users:read", "chat:write"]},
    {:github_verification_failed, :response},
    {:github_verification_failed, :app_id_mismatch},
    {:github_verification_failed, :app_not_installed},
    {:github_verification_failed, :app_not_connected},
    {:github_verification_failed, :installations},
    {:github_verification_failed, :repositories},
    {:github_verification_failed, :actor},
    {:github_verification_failed, :operator_not_found},
    {:invalid_github_app_jwt, :private_key},
    {:invalid_github_app_jwt, :app_id},
    {:emisar_verification_failed, :rpc_url},
    {:emisar_verification_failed, :token_refused},
    {:emisar_verification_failed, :wrong_key_kind},
    {:emisar_key_already_connected, "emisar.dev"},
    {:emisar_verification_failed, :response},
    {:delivery_transport_unavailable, %{reason: :econnrefused}},
    {:delivery_protocol_error, :invalid_json},
    {:delivery_credentials_unavailable, :invalid_token},
    :credential_name_invalid,
    :credential_value_invalid,
    :credential_value_too_short,
    :webhook_secret_too_short,
    :connection_not_found,
    :environment_not_found,
    {:invalid_settings, [{:enabled, :required}]},
    {:settings_conflict, %{}}
  ]

  test "a refused connection is a plain sentence, never a code in brackets" do
    for refusal <- @refusals do
      message = IntegrationErrors.message(refusal)

      refute message =~ ~r/\([a-z_:]+\)/, "#{inspect(refusal)} says #{message}"
      refute message =~ ~r/[a-z]_[a-z]/, "#{inspect(refusal)} says #{message}"
      refute message =~ "could not be verified.", "#{inspect(refusal)} says #{message}"
      assert message =~ ~r/[.]\z/, "#{inspect(refusal)} says #{message}"
    end
  end

  test "the refusals QA met say what to change" do
    assert IntegrationErrors.message({:emisar_verification_failed, :token_refused}) ==
             "Emisar refused this API key. Create an agent API key in Emisar under AI agents " <>
               "› Connect, paste it here, and keep the address unless your Emisar is self-hosted."

    assert IntegrationErrors.message({:invalid_credential, :app_token}) ==
             "That app token does not look right: it starts with xapp- and is under Basic " <>
               "Information › App-Level Tokens in your Slack app."

    assert IntegrationErrors.message({:slack_missing_scopes, ["users:read", "chat:write"]}) ==
             "Your Slack app is missing these permissions: users:read, chat:write. Add them " <>
               "under OAuth & Permissions, reinstall the app, then verify again."
  end
end
