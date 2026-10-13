defmodule Ryker.ConsoleAccess do
  @moduledoc """
  Who may use the console, and the browsers they signed in.

  Ryker signs people in itself. Andrew, 2026-10-13: "we should not use CF or anything else for
  auth - we can do it ourselves, CF/Tailscale should be only used for tunneling by default". A
  tunnel's requests reach Ryker just as a local browser's do, so nobody is anyone until they
  sign in. A verified Cloudflare Access token or Tailscale Serve's headers still name a person
  when they are there (`Ryker.ControlPlane.Viewer`); nothing needs them.

  A link signs one person in once:

  - an operator asks Ryker for one in Slack (`slack_link/3`), the people Slack already trusts
    with what Ryker is doing;
  - the host prints one for its owner (`owner_link/1`), for the first sign-in and whenever
    nobody else can;
  - anyone signed in can invite someone outside Slack (`invite/2`).

  Using a link starts a session for that browser (`sign_in/1`), which lasts 30 days from the
  last time it was used. Links and sessions keep the SHA-256 of their token: the token itself is
  only ever in the link and in the browser's cookie.
  """
  alias Ryker.ConsoleAccess.{Link, Session}
  alias Ryker.Crypto
  alias Ryker.Repo
  alias Ryker.Text

  @sign_in_seconds 15 * 60
  @owner_seconds 60 * 60
  @invite_seconds 7 * 86_400
  @session_seconds 30 * 86_400
  # A session's last use is written at most this often.
  @seen_seconds 3_600
  @token_bytes 32
  @maximum_name 120

  @type person :: %{
          via: :slack_operator | :invite | :owner,
          login: String.t(),
          name: String.t()
        }

  @doc "A link that signs a Slack operator in once in the next 15 minutes."
  @spec slack_link(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def slack_link(workspace_ref, user_ref, name)
      when is_binary(workspace_ref) and is_binary(user_ref) and is_binary(name) do
    create_link(
      :sign_in,
      %{
        via: :slack_operator,
        login: workspace_ref <> "." <> user_ref,
        name: person_name(name, user_ref)
      },
      "slack:user:" <> user_ref,
      nil,
      @sign_in_seconds
    )
  end

  @doc """
  A link that signs the host's owner in once in the next hour, and then opens `return_to`,
  a page of the console.
  """
  @spec owner_link(String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def owner_link(return_to \\ nil) do
    create_link(
      :sign_in,
      %{via: :owner, login: "owner", name: "Owner"},
      "host",
      return_to,
      @owner_seconds
    )
  end

  @doc """
  A link that signs someone outside Slack in once in the next seven days, under the name the
  person who invites them gives.
  """
  @spec invite(String.t(), String.t()) :: {:ok, String.t()} | {:error, :invalid_name | term()}
  def invite(name, created_by) when is_binary(name) and is_binary(created_by) do
    name = String.trim(name)

    if name != "" and Text.char_length(name) <= @maximum_name and String.valid?(name) and
         not Regex.match?(~r/[\x00-\x1F\x7F]/, name) do
      create_link(
        :invite,
        %{via: :invite, login: Repo.generate_id(), name: name},
        created_by,
        nil,
        @invite_seconds
      )
    else
      {:error, :invalid_name}
    end
  end

  @doc """
  The link a token opens, before anyone uses it: `{:error, :used}` or `{:error, :expired}`
  once it can no longer sign anyone in.
  """
  @spec fetch_link(term()) :: {:ok, Link.t()} | {:error, :not_found | :used | :expired}
  def fetch_link(token) do
    with {:ok, digest} <- digest(token),
         {:ok, link} <- fetch_link_by_digest(digest) do
      usable(link, Repo.now!())
    end
  end

  @doc """
  Who a link's token was made for, used or not, so a link that no longer works can say where
  a new one comes from: `:slack_operator`, `:owner` or `:invite`, or nil for no link.
  """
  @spec link_kind(term()) :: :slack_operator | :owner | :invite | nil
  def link_kind(token) do
    with {:ok, digest} <- digest(token),
         {:ok, link} <- fetch_link_by_digest(digest) do
      link.person_via
    else
      _missing -> nil
    end
  end

  @doc """
  Uses a link: it signs its person in on this browser. Answers the session's token, for the
  browser's cookie, the session, and the link, which names the page to open.
  """
  @spec sign_in(term()) ::
          {:ok, String.t(), Session.t(), Link.t()}
          | {:error, :not_found | :used | :expired | term()}
  def sign_in(token) do
    session_token = new_token()

    with {:ok, digest} <- digest(token),
         {:ok, {session, link}} <-
           Repo.transaction(fn -> redeem_locked(digest, session_token) end) do
      {:ok, session_token, session, link}
    end
  end

  defp redeem_locked(digest, session_token) do
    now = Repo.now!()

    with {:ok, link} <- fetch_and_lock_link(digest),
         {:ok, link} <- usable(link, now),
         changeset = Link.Changeset.redeem(link, now),
         {:ok, link} <- Repo.update(changeset),
         {:ok, session} <- insert_session(link, session_token, now) do
      {session, link}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp insert_session(link, session_token, now) do
    %{
      expires_at: DateTime.add(now, @session_seconds, :second),
      last_seen_at: now,
      person_login: link.person_login,
      person_name: link.person_name,
      person_via: link.person_via,
      token_sha256: Crypto.sha256_hex(session_token)
    }
    |> Session.Changeset.insert(now)
    |> Repo.insert()
  end

  @doc """
  The session a browser's token names, while it lasts. Each use keeps it for 30 more days;
  the use is written at most once an hour.
  """
  @spec fetch_session(term()) :: {:ok, Session.t()} | {:error, :not_found}
  def fetch_session(token) do
    now = Repo.now!()

    with {:ok, digest} <- digest(token),
         {:ok, session} <- fetch_live_session(digest, now) do
      {:ok, seen(session, now)}
    end
  end

  # One conditional update: two pages read at once both write, and the later one wins.
  defp seen(session, now) do
    cutoff = DateTime.add(now, -@seen_seconds, :second)

    if DateTime.compare(session.last_seen_at, cutoff) == :lt do
      expires_at = DateTime.add(now, @session_seconds, :second)

      session.id
      |> Session.Query.by_id()
      |> Session.Query.seen_before(cutoff)
      |> Repo.update_all(set: [last_seen_at: now, expires_at: expires_at, updated_at: now])

      %{session | last_seen_at: now, expires_at: expires_at}
    else
      session
    end
  end

  @doc "Signs the browser holding `token` out. Answers the session it ended, if any."
  @spec sign_out(term()) :: {:ok, Ecto.UUID.t() | nil}
  def sign_out(token) do
    with {:ok, digest} <- digest(token),
         {_count, [id]} <- delete_session_by_digest(digest) do
      {:ok, id}
    else
      _nothing -> {:ok, nil}
    end
  end

  @doc "Ends one browser's session, as Settings › Access does for someone else's."
  @spec end_session(Ecto.UUID.t()) :: :ok | {:error, :not_found}
  def end_session(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {1, _rows} <- delete_session(id) do
      :ok
    else
      _missing -> {:error, :not_found}
    end
  end

  @doc "The browsers signed in now, the most recently used first."
  @spec sessions() :: [Session.t()]
  def sessions do
    Repo.now!()
    |> Session.Query.live_at()
    |> Session.Query.ordered_by_recently_seen()
    |> Repo.all()
  end

  @doc "The invites nobody has used yet that still work, the newest first."
  @spec open_invites() :: [Link.t()]
  def open_invites do
    Link.Query.invites()
    |> Link.Query.usable_at(Repo.now!())
    |> Link.Query.ordered_by_recent()
    |> Repo.all()
  end

  @doc "Withdraws an invite nobody has used yet: its link no longer signs anyone in."
  @spec withdraw_invite(Ecto.UUID.t()) :: :ok | {:error, :not_found}
  def withdraw_invite(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {1, _rows} <- delete_open_invite(id) do
      :ok
    else
      _missing -> {:error, :not_found}
    end
  end

  # The address a link's token opens in the console.
  defp link_url(token) do
    base = Application.fetch_env!(:ryker, :control_public_url)
    String.trim_trailing(base, "/") <> "/sign-in/" <> token
  end

  defp fetch_link_by_digest(digest), do: digest |> Link.Query.by_digest() |> Repo.fetch()

  defp fetch_and_lock_link(digest),
    do: digest |> Link.Query.by_digest() |> Link.Query.lock_for_update() |> Repo.fetch()

  defp fetch_live_session(digest, now),
    do: digest |> Session.Query.by_digest() |> Session.Query.live_at(now) |> Repo.fetch()

  defp delete_session_by_digest(digest),
    do: digest |> Session.Query.by_digest() |> Session.Query.select_ids() |> Repo.delete_all()

  defp delete_session(id), do: id |> Session.Query.by_id() |> Repo.delete_all()

  defp delete_open_invite(id) do
    id
    |> Link.Query.by_id()
    |> Link.Query.invites()
    |> Link.Query.usable_at(Repo.now!())
    |> Repo.delete_all()
  end

  defp create_link(purpose, person, created_by, return_to, seconds) do
    token = new_token()
    now = Repo.now!()

    %{
      created_by: created_by,
      expires_at: DateTime.add(now, seconds, :second),
      person_login: person.login,
      person_name: person.name,
      person_via: person.via,
      purpose: purpose,
      return_to: return_to,
      token_sha256: Crypto.sha256_hex(token)
    }
    |> Link.Changeset.insert(now)
    |> Repo.insert()
    |> case do
      {:ok, _link} -> {:ok, link_url(token)}
      {:error, changeset} -> {:error, {:invalid_console_link, changeset.errors}}
    end
  end

  defp usable(%Link{used_at: %DateTime{}}, _now), do: {:error, :used}

  defp usable(%Link{} = link, now) do
    if DateTime.compare(link.expires_at, now) == :gt, do: {:ok, link}, else: {:error, :expired}
  end

  defp new_token, do: Crypto.random_secret(@token_bytes)

  # A token is 43 URL-safe characters; anything else names nothing.
  defp digest(token) when is_binary(token) and byte_size(token) == 43 do
    if Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, token),
      do: {:ok, Crypto.sha256_hex(token)},
      else: {:error, :not_found}
  end

  defp digest(_token), do: {:error, :not_found}

  # Cut as the column counts, in code points, never splitting a character a reader sees.
  defp person_name(name, fallback) do
    kept = Text.characters(String.trim(name), @maximum_name)
    if kept == "", do: fallback, else: kept
  end
end
