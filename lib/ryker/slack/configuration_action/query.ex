defmodule Ryker.Slack.ConfigurationAction.Query do
  @moduledoc "Answers people gave a channel setup conversation, for every read of `slack_configuration_actions`."
  import Ecto.Query
  alias Ryker.Slack.ConfigurationAction

  def all, do: from(actions in ConfigurationAction, as: :slack_configuration_actions)

  def by_event_ref(queryable \\ all(), event_ref),
    do: where(queryable, [slack_configuration_actions: a], a.event_ref == ^event_ref)

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
