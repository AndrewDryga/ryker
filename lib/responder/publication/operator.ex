defmodule Responder.Publication.Operator do
  @moduledoc """
  Audited operator recovery for publication custody.

  The durable operator action and the fenced publication transition commit in
  one PostgreSQL transaction. Reusing an action ref returns the stored receipt;
  reusing it for a different request fails closed.
  """

  alias Responder.Operator.Actions
  alias Responder.Publication.{Custody, Publication}

  @actions [:retry, :update, :discard]

  @spec recover(String.t(), atom(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def recover(publication_ref, action, expected_generation, options) do
    with :ok <- reference(publication_ref, :publication_ref),
         true <- action in @actions,
         true <- is_integer(expected_generation) and expected_generation > 0,
         {:ok, settings} <- settings(options) do
      Actions.run(
        %{
          action: action,
          action_ref: settings.action_ref,
          actor_ref: settings.actor_ref,
          kind: "publication",
          request: %{
            "expected_recovery_generation" => expected_generation,
            "operation" => Atom.to_string(action)
          },
          resource_ref: publication_ref
        },
        fn -> recover_publication(publication_ref, action, expected_generation) end
      )
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, {:invalid_publication_recovery, :arguments}}
    end
  end

  defp recover_publication(publication_ref, action, expected_generation) do
    with {:ok, %{previous: previous, publication: publication}} <-
           Custody.recover(publication_ref, action, expected_generation) do
      {:ok, %{previous: previous, outcome: outcome(publication)}}
    end
  end

  defp outcome(%Publication{} = publication) do
    %{
      "publication_ref" => publication.ref,
      "recovery_generation" => publication.recovery_generation,
      "review_generation" => publication.review_generation,
      "status" => Atom.to_string(publication.status)
    }
  end

  defp settings(options) when is_list(options) do
    with true <- Keyword.keyword?(options),
         keys <- Keyword.keys(options),
         true <- Enum.uniq(keys) == keys,
         true <- Enum.sort(keys) == [:action_ref, :actor_ref],
         {:ok, action_ref} <- Keyword.fetch(options, :action_ref),
         {:ok, actor_ref} <- Keyword.fetch(options, :actor_ref),
         :ok <- reference(action_ref, :action_ref),
         :ok <- reference(actor_ref, :actor_ref) do
      {:ok, %{action_ref: action_ref, actor_ref: actor_ref}}
    else
      _invalid -> {:error, {:invalid_publication_recovery, :options}}
    end
  end

  defp settings(_options), do: {:error, {:invalid_publication_recovery, :options}}

  defp reference(value, field)
       when is_binary(value) and byte_size(value) in 1..1_024 do
    if String.valid?(value) and String.trim(value) != "" and
         :binary.match(value, <<0>>) == :nomatch,
       do: :ok,
       else: {:error, {:invalid_publication_recovery, field}}
  end

  defp reference(_value, field), do: {:error, {:invalid_publication_recovery, field}}
end
