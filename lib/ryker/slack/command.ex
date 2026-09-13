defmodule Ryker.Slack.Command do
  @moduledoc """
  One authenticated `/ryker` Socket Mode command.

  The response URL and arbitrary payload fields are deliberately discarded.
  Commands are acknowledged privately over the authenticated socket only after
  their deterministic host transition finishes.
  """

  @fields [:actor_ref, :channel_ref, :event_ref, :occurred_at, :text, :workspace_ref]
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          actor_ref: String.t(),
          channel_ref: String.t(),
          event_ref: String.t(),
          occurred_at: DateTime.t(),
          text: String.t(),
          workspace_ref: String.t()
        }

  @spec from_socket(map(), String.t(), DateTime.t()) :: {:ok, t()} | :ignore
  def from_socket(
        %{
          "accepts_response_payload" => true,
          "envelope_id" => envelope_ref,
          "payload" => %{
            "channel_id" => channel_ref,
            "command" => "/ryker",
            "team_id" => workspace_ref,
            "text" => text,
            "user_id" => actor_ref
          },
          "type" => "slash_commands"
        },
        workspace_ref,
        %DateTime{} = occurred_at
      ) do
    values = [actor_ref, channel_ref, envelope_ref, workspace_ref]

    if Enum.all?(values, &reference?/1) and text?(text) and utc?(occurred_at) do
      {:ok,
       %__MODULE__{
         actor_ref: actor_ref,
         channel_ref: channel_ref,
         event_ref: "slash:#{envelope_ref}",
         occurred_at: normalize_datetime(occurred_at),
         text: String.trim(text),
         workspace_ref: workspace_ref
       }}
    else
      :ignore
    end
  end

  def from_socket(_envelope, _workspace_ref, _occurred_at), do: :ignore

  defp text?(value),
    do:
      is_binary(value) and String.valid?(value) and byte_size(value) <= 4_096 and
        :binary.match(value, <<0>>) == :nomatch

  defp reference?(value),
    do:
      is_binary(value) and String.valid?(value) and byte_size(value) in 1..1_024 and
        String.trim(value) != "" and :binary.match(value, <<0>>) == :nomatch

  defp utc?(%DateTime{} = value),
    do: value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0

  defp normalize_datetime(%DateTime{microsecond: {microsecond, _precision}} = value),
    do: %{value | microsecond: {microsecond, 6}}
end
