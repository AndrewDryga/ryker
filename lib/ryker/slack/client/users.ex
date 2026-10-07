defmodule Ryker.Slack.Client.Users do
  @moduledoc """
  People in the workspace: whether someone may use Ryker, who is in a user
  group, and the display name of a person, channel or the workspace itself.

  Only an active full member of this workspace is allowed: a guest, a bot, a
  deactivated account or someone from another workspace is not. Display names
  are for reading and never take part in authorization.
  """
  alias Ryker.Slack.Client
  alias Ryker.Slack.Client.{Conversations, Fields, Transport}

  def user_allowed(client, user_ref, workspace_ref) do
    with :ok <- Fields.slack_id(user_ref),
         :ok <- Fields.slack_id(workspace_ref),
         {:ok, response} <- Transport.request(client, :get, user_path(user_ref), nil),
         {:ok, body} <- Transport.response(response) do
      allowed_user(body, user_ref, workspace_ref)
    end
  end

  @doc """
  Whether Slack lists someone as an admin or owner of this workspace: an
  active full member of it whose profile says `is_admin`, `is_owner` or
  `is_primary_owner`. A profile without those flags, or from another
  workspace, is no.
  """
  @spec workspace_admin(Client.t(), String.t(), String.t()) ::
          {:ok, boolean()} | {:error, term()}
  def workspace_admin(client, user_ref, workspace_ref) do
    with :ok <- Fields.slack_id(user_ref),
         :ok <- Fields.slack_id(workspace_ref),
         {:ok, response} <- Transport.request(client, :get, user_path(user_ref), nil),
         {:ok, body} <- Transport.response(response),
         {:ok, member} <- allowed_user(body, user_ref, workspace_ref) do
      {:ok, member and admin_flag?(body["user"])}
    end
  end

  def user_group_members(client, user_group_ref, workspace_ref) do
    with :ok <- Fields.slack_id(user_group_ref),
         :ok <- Fields.slack_id(workspace_ref),
         {:ok, response} <-
           Transport.request(
             client,
             :get,
             "/usergroups.users.list?" <> URI.encode_query(usergroup: user_group_ref),
             nil
           ),
         {:ok, body} <- Transport.response(response) do
      group_users(body)
    end
  end

  @doc "Read a display name only. These names never participate in authorization."
  @spec directory_name(Client.t(), String.t(), String.t()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def directory_name(client, workspace, ref) do
    with :ok <- Fields.slack_id(workspace), :ok <- Fields.slack_id(ref) do
      directory_name_request(client, workspace, ref)
    end
  end

  defp directory_name_request(client, workspace, "T" <> _ = workspace) do
    # auth.test needs no additional scope and returns the token's bound team.
    with {:ok, response} <- Transport.request(client, :post, "/auth.test", %{}),
         {:ok, %{"team_id" => ^workspace, "team" => name}} <- Transport.response(response) do
      {:ok, name}
    else
      {:error, _} = error -> error
      _ -> {:error, :directory_name_unavailable}
    end
  end

  defp directory_name_request(client, workspace, <<prefix, _::binary>> = ref)
       when prefix in [?U, ?W] do
    with {:ok, response} <- Transport.request(client, :get, user_path(ref), nil),
         {:ok, %{"user" => %{"id" => ^ref, "team_id" => ^workspace} = user}} <-
           Transport.response(response) do
      profile = user["profile"] || %{}

      {:ok,
       Enum.find(
         [profile["display_name"], profile["real_name"], user["name"]],
         &(is_binary(&1) and String.trim(&1) != "")
       )}
    else
      {:error, _} = error -> error
      _ -> {:error, :directory_name_unavailable}
    end
  end

  defp directory_name_request(client, _workspace, <<prefix, _::binary>> = ref)
       when prefix in [?C, ?G, ?D] do
    with {:ok, channel} <- Conversations.conversation_info(client, ref),
         do: {:ok, channel["name"] || "Direct message"}
  end

  defp directory_name_request(_, _, _), do: {:error, :directory_name_unavailable}

  defp user_path(user_ref), do: "/users.info?" <> URI.encode_query(user: user_ref)

  # Whether a users.info reply describes an active full member of this workspace.
  defp allowed_user(
         %{
           "user" => %{
             "deleted" => deleted,
             "id" => user_ref,
             "is_bot" => is_bot,
             "is_restricted" => is_restricted,
             "is_ultra_restricted" => is_ultra_restricted,
             "team_id" => workspace_ref
           }
         },
         user_ref,
         workspace_ref
       )
       when is_boolean(deleted) and is_boolean(is_bot) and is_boolean(is_restricted) and
              is_boolean(is_ultra_restricted) do
    {:ok, not deleted and not is_bot and not is_restricted and not is_ultra_restricted}
  end

  defp allowed_user(
         %{"user" => %{"id" => _id, "team_id" => _actual_workspace}},
         _user_ref,
         _expected_workspace
       ),
       do: {:ok, false}

  defp allowed_user(_body, _user_ref, _workspace_ref),
    do: {:error, {:slack_protocol_error, :user}}

  defp admin_flag?(user),
    do: Enum.any?(["is_admin", "is_owner", "is_primary_owner"], &(user[&1] == true))

  defp group_users(%{"users" => users}) when is_list(users) do
    if Enum.uniq(users) == users and Enum.all?(users, &(Fields.slack_id(&1) == :ok)),
      do: {:ok, Enum.sort(users)},
      else: {:error, {:slack_protocol_error, :user_group}}
  end

  defp group_users(_body), do: {:error, {:slack_protocol_error, :user_group}}
end
