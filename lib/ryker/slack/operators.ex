defmodule Ryker.Slack.Operators do
  @moduledoc """
  Who can manage Ryker from Slack: the people chosen for it on
  Integrations › Slack and, while the installation allows it (the default),
  the workspace's admins and owners.

  Every Slack surface that decides whether someone may change Ryker (`/ryker`,
  Home, channel setup, incident rooms, answers to Ryker's questions and the
  saved settings themselves) asks `operator?/2`, so none of them can drift
  from the others on who that is. Whether someone is an admin is Slack's
  answer about them (`Ryker.Slack.WorkspaceAdmins`), and no answer is no.
  """
  alias Ryker.Slack.WorkspaceAdmins

  @enforce_keys [:chosen, :workspace_admins, :workspace_ref]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          chosen: MapSet.t(String.t()),
          workspace_admins: boolean(),
          workspace_ref: String.t() | nil
        }

  @doc """
  `chosen` are the people saved as able to manage Ryker, `workspace_admins`
  whether the workspace's admins and owners can too, and `workspace_ref` the
  workspace they are admins of. Anything but `true` keeps admins out.
  """
  @spec new(Enumerable.t(String.t()), term(), String.t() | nil) :: t()
  def new(chosen, workspace_admins, workspace_ref) do
    %__MODULE__{
      chosen: MapSet.new(chosen),
      workspace_admins: workspace_admins == true,
      workspace_ref: workspace_ref
    }
  end

  @doc "Whether this Slack person can manage Ryker right now."
  @spec operator?(t(), term()) :: boolean()
  def operator?(%__MODULE__{} = operators, user_ref) when is_binary(user_ref) do
    MapSet.member?(operators.chosen, user_ref) or
      (operators.workspace_admins and is_binary(operators.workspace_ref) and
         WorkspaceAdmins.admin?(operators.workspace_ref, user_ref))
  end

  def operator?(_operators, _user_ref), do: false

  @doc "The people chosen by name, in a stable order, such as the ones an incident room invites."
  @spec chosen(t()) :: [String.t()]
  def chosen(%__MODULE__{chosen: chosen}), do: chosen |> MapSet.to_list() |> Enum.sort()
end
