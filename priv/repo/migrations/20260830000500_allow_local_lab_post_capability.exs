defmodule Ryker.Repo.Migrations.AllowLocalLabPostCapability do
  use Ecto.Migration

  def up do
    drop(constraint(:ingress_inbox_entries, :ingress_inbox_source_capabilities_valid))

    create(
      constraint(:ingress_inbox_entries, :ingress_inbox_source_capabilities_valid,
        check: source_capabilities_check()
      )
    )
  end

  def down do
    drop(constraint(:ingress_inbox_entries, :ingress_inbox_source_capabilities_valid))

    create(
      constraint(:ingress_inbox_entries, :ingress_inbox_source_capabilities_valid,
        check: slack_only_source_capabilities_check()
      )
    )
  end

  defp source_capabilities_check do
    """
    jsonb_typeof(source_capabilities::jsonb) = 'object'
    AND (
      NOT (source_capabilities::jsonb ? 'react')
      OR (source_item_ref IS NOT NULL AND char_length(source_item_ref) > 0)
    )
    AND (
      NOT (source_capabilities::jsonb ? 'post_slack_message')
      OR (
        (
          source_kind = 'slack'
          OR (
            source_kind = 'control_plane'
            AND source_ref = 'local'
            AND destination_transport = 'control_plane'
            AND destination_conversation_ref LIKE 'control-plane:lab:%'
            AND destination_thread_ref = destination_conversation_ref
            AND source_capabilities::jsonb -> 'post_slack_message' -> 'destination_refs'
              = jsonb_build_array(destination_conversation_ref)
          )
        )
        AND actor_kind = 'user'
        AND source_item_ref IS NOT NULL
        AND char_length(source_item_ref) > 0
        AND jsonb_typeof(source_capabilities::jsonb -> 'post_slack_message') = 'object'
        AND jsonb_typeof(source_capabilities::jsonb -> 'post_slack_message' -> 'destination_refs') = 'array'
        AND jsonb_array_length(source_capabilities::jsonb -> 'post_slack_message' -> 'destination_refs') BETWEEN 1 AND 8
      )
    )
    """
  end

  defp slack_only_source_capabilities_check do
    """
    jsonb_typeof(source_capabilities::jsonb) = 'object'
    AND (
      NOT (source_capabilities::jsonb ? 'react')
      OR (source_item_ref IS NOT NULL AND char_length(source_item_ref) > 0)
    )
    AND (
      NOT (source_capabilities::jsonb ? 'post_slack_message')
      OR (
        source_kind = 'slack'
        AND actor_kind = 'user'
        AND source_item_ref IS NOT NULL
        AND char_length(source_item_ref) > 0
        AND jsonb_typeof(source_capabilities::jsonb -> 'post_slack_message') = 'object'
        AND jsonb_typeof(source_capabilities::jsonb -> 'post_slack_message' -> 'destination_refs') = 'array'
        AND jsonb_array_length(source_capabilities::jsonb -> 'post_slack_message' -> 'destination_refs') BETWEEN 1 AND 8
      )
    )
    """
  end
end
