defmodule Responder.Slack.MemberDirectory do
  @moduledoc false

  @callback user_allowed(term(), String.t(), String.t()) ::
              {:ok, boolean()} | {:error, term()}

  @callback user_group_members(term(), String.t(), String.t()) ::
              {:ok, [String.t()]} | {:error, term()}

  @optional_callbacks user_group_members: 3
end
