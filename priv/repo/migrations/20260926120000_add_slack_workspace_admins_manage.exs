defmodule Ryker.Repo.Migrations.AddSlackWorkspaceAdminsManage do
  use Ecto.Migration

  # Whether the workspace's admins and owners can manage Ryker from Slack
  # beside the people chosen for it. On unless someone turns it off (Andrew,
  # 2026-09-26), for new installations and for every one upgraded here.
  def change do
    alter table(:slack_settings) do
      add(:workspace_admins_manage, :boolean, null: false, default: true)
    end
  end
end
