defmodule Ryker.ControlPlane.EngineeringOffer do
  @moduledoc "Reviews the delivered engineering brief before a repository writer starts it."
  alias Ryker.ControlPlane.PublicPage
  alias Ryker.GitHubActions

  @salt "github-engineering-offer"

  def call(conn, :engineering_offer, token, options) do
    ref = conn.path_params["ref"]

    case GitHubActions.engineering_offer(ref, token, options) do
      {:ok, %{offer: offer}} ->
        snapshot =
          Phoenix.Token.sign(conn.secret_key_base, @salt, %{
            ref: ref,
            fingerprint: offer.fingerprint
          })

        PublicPage.page(conn, 200, offer.record.payload["title"], [
          "<div class=\"github-action-page\"><p>Review the saved brief. Starting this task authorizes these code changes.</p><pre>",
          PublicPage.escape(offer.record.payload["prompt"]),
          "</pre><form method=\"post\" action=\"",
          path(ref),
          "\">",
          PublicPage.csrf(),
          "<input type=\"hidden\" name=\"snapshot\" value=\"",
          PublicPage.escape(snapshot),
          "\"><button class=\"ui-button primary\" type=\"submit\">Start this task</button></form></div>"
        ])

      {:error, _unavailable} ->
        unavailable(conn)
    end
  end

  def call(conn, :confirm_engineering_offer, token, options) do
    ref = conn.path_params["ref"]

    with {:ok, %{ref: ^ref, fingerprint: expected}} <-
           Phoenix.Token.verify(conn.secret_key_base, @salt, conn.params["snapshot"],
             max_age: 3600
           ),
         {:ok, _started} <- GitHubActions.confirm_engineering_offer(ref, token, expected, options) do
      PublicPage.page(
        conn,
        202,
        "Task started",
        "<p>Ryker will report progress in the original GitHub discussion. Repeating this approval does not start another task.</p>"
      )
    else
      _unavailable -> unavailable(conn)
    end
  end

  defp path(ref), do: "/github/actions/offer/" <> URI.encode(ref, &URI.char_unreserved?/1)

  defp unavailable(conn) do
    PublicPage.page(
      conn,
      409,
      "Offer unavailable",
      "<p>This offer or your repository access could not be verified. Open the latest offer in the GitHub discussion and sign in again.</p>"
    )
  end
end
