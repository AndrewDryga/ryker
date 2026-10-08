defmodule Ryker.GitObject do
  @moduledoc """
  A git object id as Ryker stores and compares one: a commit, tree or blob,
  named by 40 lowercase hex digits (SHA-1) or 64 (SHA-256). Ten modules had
  their own copy of this rule, in two spellings (2026-10-04 review). A branch's
  full ref name is checked here too.
  """

  @id ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @branch_ref ~r/\Arefs\/heads\/[A-Za-z0-9._\/-]{1,240}\z/

  @doc "Whether `value` is a full, lowercase SHA-1 or SHA-256 object id."
  @spec id?(term()) :: boolean()
  def id?(value), do: is_binary(value) and Regex.match?(@id, value)

  @doc ~s(Whether `value` is a branch's full ref name: "refs/heads/" and a branch Ryker would name.)
  @spec branch_ref?(term()) :: boolean()
  def branch_ref?(value), do: is_binary(value) and Regex.match?(@branch_ref, value)
end
