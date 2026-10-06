defmodule Ryker.Slack.ControlValue do
  @moduledoc """
  The value a behavior or schedule control button carries: the resource it acts
  on and the revision the person saw, `behavior-control:behavior:<id>:<revision>`.
  App Home writes it; App Home and the chat interaction handler read it back,
  and each kept its own copy of the reader.
  """

  @doc "The value for `kind`'s resource `ref` at `revision`."
  @spec encode(String.t(), String.t(), pos_integer()) :: String.t()
  def encode(kind, ref, revision), do: "#{kind}-control:#{ref}:#{revision}"

  @doc """
  The resource ref and revision a `kind` control's `value` carries: the ref is
  itself `kind:…` and the revision a positive integer. `:error` for anything
  else.
  """
  @spec decode(term(), String.t()) :: {:ok, String.t(), pos_integer()} | :error
  def decode(value, kind) when is_binary(value) do
    prefix = kind <> "-control:"

    {ref_parts, [revision_text]} =
      value |> String.replace_prefix(prefix, "") |> String.split(":") |> Enum.split(-1)

    ref = Enum.join(ref_parts, ":")

    with true <- String.starts_with?(value, prefix) and String.starts_with?(ref, kind <> ":"),
         {revision, ""} when revision > 0 <- Integer.parse(revision_text) do
      {:ok, ref, revision}
    else
      _invalid -> :error
    end
  end

  def decode(_value, _kind), do: :error
end
