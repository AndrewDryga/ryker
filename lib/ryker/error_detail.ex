defmodule Ryker.ErrorDetail do
  @moduledoc """
  What a lane keeps and logs about a failure: a code, the reason's leading
  atom, and the reason as bounded text with its secrets taken out.

  A remote reason carries what the provider said, which can quote a request
  with its credentials, so the text is redacted the way an inspected artifact
  is (`Ryker.InspectionRedactor.redact/2`). The reasons were stored in
  `last_error_detail` and logged raw, and nine lanes each had their own copy of
  the bound (2026-10-04 review).
  """
  alias Ryker.InspectionRedactor

  @maximum_bytes 4_096
  @marker "..."

  @doc "The code and the detail of `reason`; `fallback` is the code of a reason without a leading atom."
  @spec describe(term(), atom()) :: {String.t(), String.t()}
  def describe(reason, fallback) when is_atom(fallback),
    do: {code(reason, fallback), detail(reason)}

  @doc "The reason's leading atom as text, or `fallback`'s."
  @spec code(term(), atom()) :: String.t()
  def code(reason, _fallback) when is_atom(reason) and not is_nil(reason),
    do: Atom.to_string(reason)

  def code(reason, _fallback)
      when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)) and
             not is_nil(elem(reason, 0)),
      do: Atom.to_string(elem(reason, 0))

  def code(_reason, fallback) when is_atom(fallback), do: Atom.to_string(fallback)

  @doc "The reason inspected, redacted and cut to at most 4 KiB."
  @spec detail(term()) :: String.t()
  def detail(reason) do
    reason
    |> inspect(limit: 20, printable_limit: 3_500, width: 120)
    |> InspectionRedactor.redact(InspectionRedactor.configured_secrets())
    |> bound()
  end

  @doc "Text cut to at most 4 KiB on a character boundary, ending in `...` when cut."
  @spec bound(String.t()) :: String.t()
  def bound(text) when byte_size(text) <= @maximum_bytes, do: text

  def bound(text),
    do: String.byte_slice(text, 0, @maximum_bytes - byte_size(@marker)) <> @marker
end
