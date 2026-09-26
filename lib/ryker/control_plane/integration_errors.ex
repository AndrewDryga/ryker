defmodule Ryker.ControlPlane.IntegrationErrors do
  @moduledoc """
  What went wrong connecting or changing an integration, as one sentence for
  the person who pressed the button: what failed, then what to change.

  QA, 2026-09-25: refusals read "Connection could not be verified
  (account_identity_unavailable)" and "(app_token)", an internal code in
  brackets and nothing about what to do. A refusal no sentence here names
  still says which service to check, never its code.
  """

  @slack_sign_in_refused ["invalid_auth", "not_authed", "token_revoked", "token_expired"]

  @doc "The sentence for one refusal from `Ryker.IntegrationSetup` or the settings it writes."
  @spec message(term()) :: String.t()
  def message({:invalid_credential, :app_token}),
    do:
      "That app token does not look right: it starts with xapp- and is under Basic " <>
        "Information › App-Level Tokens in your Slack app."

  def message({:invalid_credential, :swapped_tokens}),
    do:
      "The two tokens are swapped: the app token starts with xapp- and the bot token " <>
        "with xoxb-. Paste each in its own box, then verify again."

  def message({:invalid_credential, :bot_token}),
    do:
      "That bot token does not look right: it starts with xoxb- and is under OAuth & " <>
        "Permissions in your Slack app."

  def message({:invalid_credential, :token}),
    do: "Paste the API token from your Emisar account."

  def message({:invalid_credential, :display_name}),
    do: "Give the account a name of up to 120 characters."

  def message({:invalid_credential, :account_ref}),
    do:
      "Emisar did not say which account this token belongs to. Check that you pasted an " <>
        "API token and the right Emisar address, then try again."

  def message({:invalid_credential, :ref}),
    do: "That account no longer exists. Reload the page."

  def message({:slack_verification_failed, :socket_mode}),
    do:
      "Slack did not open a connection with the app token. Turn on Socket Mode in your " <>
        "Slack app, then verify again."

  def message({:slack_verification_failed, code}) when code in @slack_sign_in_refused,
    do:
      "Slack did not accept these tokens; they may be mistyped, revoked or expired. Copy " <>
        "both again from your Slack app, then verify again."

  def message({:slack_verification_failed, "account_inactive"}),
    do:
      "Slack says the app's account is no longer active. Reinstall the app in your " <>
        "workspace, then paste its new tokens."

  def message({:slack_verification_failed, "not_allowed_token_type"}),
    do:
      "One token is the wrong kind: the app token starts with xapp- and the bot token with " <>
        "xoxb-. Check both, then verify again."

  def message({:slack_verification_failed, "ratelimited"}),
    do: "Slack asked Ryker to slow down. Wait a minute, then verify again."

  def message({:slack_verification_failed, :members}),
    do:
      "Slack did not list the people in your workspace. Check that the app has the " <>
        "users:read permission, then try again."

  def message({:slack_verification_failed, _refused}),
    do:
      "Slack did not confirm the workspace and bot for these tokens. Check that both come " <>
        "from the same Slack app, then verify again."

  def message({:slack_missing_scopes, scopes}),
    do:
      "Your Slack app is missing these permissions: #{Enum.join(scopes, ", ")}. Add them " <>
        "under OAuth & Permissions, reinstall the app, then verify again."

  def message({:github_verification_failed, :app_id_mismatch}),
    do:
      "That private key belongs to a different GitHub App than this App ID. Use the key " <>
        "from the same App's settings page."

  def message({:github_verification_failed, :app_not_connected}),
    do: "Connect the GitHub App first, then try again."

  def message({:github_verification_failed, reason})
      when reason in [:installations, :repositories],
      do:
        "GitHub did not list the repositories the App can reach. Check that the App is " <>
          "installed on them, then try again."

  def message({:github_verification_failed, reason}) when reason in [:actor, :operator_not_found],
    do:
      "GitHub did not return the App's bot account. Check that the App is installed, then " <>
        "try again in a minute."

  def message({:github_verification_failed, _refused}),
    do:
      "GitHub did not accept this App ID and private key. Check both on the App's settings " <>
        "page, then verify again."

  def message({:invalid_github_app_jwt, :app_id}),
    do: "Enter the App ID as it appears on the App's settings page in GitHub: a number."

  def message({:invalid_github_app_jwt, _key}),
    do:
      "GitHub could not read the App's private key. Upload the .pem file GitHub gave you, " <>
        "then verify again."

  def message({:emisar_verification_failed, :rpc_url}),
    do:
      "The Emisar address must start with https://, such as " <>
        "https://emisar.dev/api/mcp/rpc. Keep the default unless your Emisar is self-hosted."

  def message({:emisar_verification_failed, :account_identity_unavailable}),
    do:
      "Emisar did not say which account this token belongs to. Check that you pasted an " <>
        "API token and the right Emisar address, then try again."

  def message({:emisar_verification_failed, _refused}),
    do:
      "Emisar did not answer as expected. Check the token and the Emisar address, then try " <>
        "again."

  def message({:delivery_transport_unavailable, _reason}),
    do: "Ryker could not reach the service. Check the address and your network, then try again."

  def message({:delivery_credentials_unavailable, _reason}),
    do: "Ryker could not read the saved secret. Paste it again, then try again."

  def message({:delivery_protocol_error, _reason}),
    do:
      "The service answered with something Ryker could not read. Check the address, then " <>
        "try again."

  def message(:credential_name_invalid),
    do: "That name cannot be used. Use lowercase letters, numbers, dots, dashes and colons."

  def message(:credential_value_invalid), do: "That secret is empty or too long."

  def message(:credential_value_too_short),
    do: "That secret is too short. Use at least 8 characters."

  def message(:webhook_secret_too_short),
    do: "A signing secret needs at least 32 characters. Leave it empty and Ryker creates one."

  def message(:connection_not_found), do: "That account no longer exists. Reload the page."

  def message(:environment_not_found),
    do: "That environment no longer exists. Reload the page."

  def message(:emisar_account_mismatch),
    do: "That token belongs to a different Emisar account."

  def message({:invalid_settings, _errors}),
    do: "These values were refused. Check them and try again."

  def message({:settings_conflict, _current}),
    do: "The settings changed in the meantime. Reload the page and try again."

  def message(_reason),
    do: "This did not work. Check the values and try again."
end
