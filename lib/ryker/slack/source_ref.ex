defmodule Ryker.Slack.SourceRef do
  @moduledoc false

  @id ~r/\A[A-Z0-9]+\z/
  @resource_id ~r/\A[A-Za-z0-9]+\z/
  @timestamp ~r/\A[0-9]{10,}\.[0-9]{1,6}\z/

  @spec channel(String.t(), String.t()) :: String.t()
  def channel(workspace_ref, channel_ref),
    do: encode(workspace_ref, channel_ref, "channel", nil)

  @spec message(String.t(), String.t(), String.t()) :: String.t()
  def message(workspace_ref, channel_ref, message_ref),
    do: encode(workspace_ref, channel_ref, "message", message_ref)

  @spec thread(String.t(), String.t(), String.t()) :: String.t()
  def thread(workspace_ref, channel_ref, message_ref),
    do: encode(workspace_ref, channel_ref, "thread", message_ref)

  @spec file(String.t(), String.t(), String.t()) :: String.t()
  def file(workspace_ref, channel_ref, file_ref),
    do: encode_resource(workspace_ref, channel_ref, "file", file_ref)

  @spec canvas(String.t(), String.t(), String.t()) :: String.t()
  def canvas(workspace_ref, channel_ref, canvas_ref),
    do: encode_resource(workspace_ref, channel_ref, "canvas", canvas_ref)

  @spec bookmark(String.t(), String.t(), String.t()) :: String.t()
  def bookmark(workspace_ref, channel_ref, bookmark_ref),
    do: encode_resource(workspace_ref, channel_ref, "bookmark", bookmark_ref)

  @doc "The ref of a parsed source, exactly as `parse/2` read it."
  @spec encode(map()) :: String.t()
  def encode(%{kind: :channel, workspace_ref: workspace_ref, channel_ref: channel_ref}),
    do: channel(workspace_ref, channel_ref)

  def encode(%{kind: kind, workspace_ref: workspace_ref, channel_ref: channel_ref} = source)
      when kind in [:message, :thread],
      do: encode(workspace_ref, channel_ref, Atom.to_string(kind), source.message_ref)

  def encode(%{kind: kind, workspace_ref: workspace_ref, channel_ref: channel_ref} = source)
      when kind in [:bookmark, :canvas, :file],
      do: encode_resource(workspace_ref, channel_ref, Atom.to_string(kind), source.resource_ref)

  @doc "A workspace, channel or user id as Slack issues them."
  @spec slack_id?(term()) :: boolean()
  def slack_id?(value), do: id?(value)

  @spec parse(String.t(), String.t()) :: {:ok, map()} | {:error, :invalid_slack_source_ref}
  def parse(value, expected_workspace_ref) when is_binary(value) do
    case String.split(value, ":") do
      ["slack-source", "v1", workspace_ref, channel_ref, "channel"] ->
        parsed(workspace_ref, channel_ref, :channel, nil, expected_workspace_ref)

      ["slack-source", "v1", workspace_ref, channel_ref, kind, message_ref]
      when kind in ["message", "thread"] ->
        parsed(
          workspace_ref,
          channel_ref,
          String.to_existing_atom(kind),
          message_ref,
          expected_workspace_ref
        )

      ["slack-source", "v1", workspace_ref, channel_ref, kind, resource_ref]
      when kind in ["bookmark", "canvas", "file"] ->
        resource_parsed(
          workspace_ref,
          channel_ref,
          String.to_existing_atom(kind),
          resource_ref,
          expected_workspace_ref
        )

      _invalid ->
        {:error, :invalid_slack_source_ref}
    end
  end

  def parse(_value, _expected_workspace_ref), do: {:error, :invalid_slack_source_ref}

  defp encode(workspace_ref, channel_ref, kind, nil) do
    if id?(workspace_ref) and id?(channel_ref),
      do: Enum.join(["slack-source", "v1", workspace_ref, channel_ref, kind], ":"),
      else: raise(ArgumentError, "invalid Slack source identity")
  end

  defp encode(workspace_ref, channel_ref, kind, message_ref) do
    if id?(workspace_ref) and id?(channel_ref) and timestamp?(message_ref),
      do:
        Enum.join(
          ["slack-source", "v1", workspace_ref, channel_ref, kind, message_ref],
          ":"
        ),
      else: raise(ArgumentError, "invalid Slack source identity")
  end

  defp encode_resource(workspace_ref, channel_ref, kind, resource_ref) do
    if id?(workspace_ref) and id?(channel_ref) and resource_id?(resource_ref),
      do:
        Enum.join(
          ["slack-source", "v1", workspace_ref, channel_ref, kind, resource_ref],
          ":"
        ),
      else: raise(ArgumentError, "invalid Slack source identity")
  end

  defp parsed(workspace_ref, channel_ref, kind, message_ref, expected_workspace_ref) do
    valid_message = is_nil(message_ref) or timestamp?(message_ref)

    if workspace_ref == expected_workspace_ref and id?(workspace_ref) and id?(channel_ref) and
         valid_message do
      {:ok,
       %{
         channel_ref: channel_ref,
         kind: kind,
         message_ref: message_ref,
         resource_ref: nil,
         workspace_ref: workspace_ref
       }}
    else
      {:error, :invalid_slack_source_ref}
    end
  end

  defp resource_parsed(
         workspace_ref,
         channel_ref,
         kind,
         resource_ref,
         expected_workspace_ref
       ) do
    if workspace_ref == expected_workspace_ref and id?(workspace_ref) and id?(channel_ref) and
         resource_id?(resource_ref) do
      {:ok,
       %{
         channel_ref: channel_ref,
         kind: kind,
         message_ref: nil,
         resource_ref: resource_ref,
         workspace_ref: workspace_ref
       }}
    else
      {:error, :invalid_slack_source_ref}
    end
  end

  defp id?(value), do: is_binary(value) and Regex.match?(@id, value)
  defp resource_id?(value), do: is_binary(value) and Regex.match?(@resource_id, value)
  defp timestamp?(value), do: is_binary(value) and Regex.match?(@timestamp, value)
end
