defmodule Ryker.ControlPlane.FormDraft do
  @moduledoc """
  A settings form's draft, kept in the browser while its page is away
  (`priv/static/settings-draft.mjs`). A form's unsaved values live in its
  component, and LiveView handles Back and server-side navigation itself, so
  the leave guard could not ask before those threw the values away
  (2026-10-04 review).

  The form says what its draft began from: the revision it saves against and
  a digest of the saved values it is compared with. A draft read back later
  saves against the current revision when those saved values read the same
  as when it began, as a live refresh lets a draft follow, and against the
  revision it began from otherwise, so its save meets the conflict instead of
  writing over the change.
  """
  alias Plug.Conn.{InvalidQueryError, Query}

  @doc "A digest of the saved values a draft is compared with."
  @spec digest(term()) :: String.t()
  def digest(baseline) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(baseline, [:deterministic]))
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Reads a kept draft back: its fields, decoded the way LiveView decodes a
  form, and the revision to save against, `:current` when `baseline` still
  reads as it did when the draft began.
  """
  @spec read(term(), term()) :: {:ok, map(), integer() | :current} | :error
  def read(%{"revision" => revision, "baseline" => began, "form" => form}, baseline)
      when is_binary(revision) and is_binary(began) and is_binary(form) do
    with {revision, ""} <- Integer.parse(revision),
         {:ok, params} <- decode(form) do
      {:ok, params, if(began == digest(baseline), do: :current, else: revision)}
    else
      _unreadable -> :error
    end
  end

  def read(_kept, _baseline), do: :error

  defp decode(form) do
    {:ok, Query.decode(form)}
  rescue
    InvalidQueryError -> :error
  end
end
