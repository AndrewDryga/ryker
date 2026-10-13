defmodule Ryker.ConsoleAccess.Session.Query do
  @moduledoc "Signed-in console browsers, for every read of `console_sessions`."
  use Ryker, :query
  alias Ryker.ConsoleAccess.Session

  def all, do: from(sessions in Session, as: :console_sessions)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [console_sessions: s], s.id == ^id)

  def by_digest(queryable \\ all(), token_sha256),
    do: where(queryable, [console_sessions: s], s.token_sha256 == ^token_sha256)

  @doc "Still signed in at `now`."
  def live_at(queryable \\ all(), now),
    do: where(queryable, [console_sessions: s], s.expires_at > ^now)

  @doc "Last used before `cutoff`."
  def seen_before(queryable \\ all(), cutoff),
    do: where(queryable, [console_sessions: s], s.last_seen_at < ^cutoff)

  def select_ids(queryable \\ all()), do: select(queryable, [console_sessions: s], s.id)

  def ordered_by_recently_seen(queryable \\ all()),
    do: order_by(queryable, [console_sessions: s], desc: s.last_seen_at, desc: s.id)
end
