defmodule Ryker.ConsoleAccess.Link.Query do
  @moduledoc "Console sign-in links, for every read of `console_sign_in_links`."
  use Ryker, :query
  alias Ryker.ConsoleAccess.Link

  def all, do: from(links in Link, as: :console_sign_in_links)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [console_sign_in_links: l], l.id == ^id)

  def by_digest(queryable \\ all(), token_sha256),
    do: where(queryable, [console_sign_in_links: l], l.token_sha256 == ^token_sha256)

  def invites(queryable \\ all()),
    do: where(queryable, [console_sign_in_links: l], l.purpose == :invite)

  @doc "Not used yet, and not expired at `now`."
  def usable_at(queryable \\ all(), now),
    do: where(queryable, [console_sign_in_links: l], is_nil(l.used_at) and l.expires_at > ^now)

  def ordered_by_recent(queryable \\ all()),
    do: order_by(queryable, [console_sign_in_links: l], desc: l.inserted_at, desc: l.id)

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
