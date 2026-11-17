defmodule Ryker.GitHub.Client.Labels do
  @moduledoc "Repository label provisioning and exact PR label changes; unrelated labels are never replaced."
  alias Ryker.GitHub.Client.{Fields, Transport}

  @maximum_pages 100
  @page_size 100

  def ensure_label(client, repository, %{name: name} = label) do
    with :ok <- Fields.repository(repository),
         {:ok, response} <- Transport.request(client, :get, label_path(repository, name), nil) do
      case response do
        %{status: 200, body: %{"name" => ^name}} -> :ok
        %{status: 404} -> create_label(client, repository, label)
        %{status: 200} -> {:error, {:github_protocol_error, :label}}
        _failed -> Transport.error(response)
      end
    end
  end

  defp create_label(client, repository, %{name: name, color: color, description: description}) do
    document = %{"name" => name, "color" => color, "description" => description}

    with {:ok, response} <-
           Transport.request(client, :post, "/repos/#{repository}/labels", document) do
      case response do
        %{status: 201, body: %{"name" => ^name}} -> :ok
        # Another installer can have created it after our read. Check the
        # exact label, rather than treating every validation error as success.
        %{status: 422} -> existing_label(client, repository, name)
        %{status: 201} -> {:error, {:github_protocol_error, :label}}
        _failed -> Transport.error(response)
      end
    end
  end

  defp existing_label(client, repository, name) do
    with {:ok, response} <- Transport.request(client, :get, label_path(repository, name), nil) do
      case response do
        %{status: 200, body: %{"name" => ^name}} -> :ok
        %{status: 200} -> {:error, {:github_protocol_error, :label}}
        _failed -> Transport.error(response)
      end
    end
  end

  def add_pull_label(client, repository, number, name) do
    with :ok <- Fields.target(repository, number),
         {:ok, response} <-
           Transport.request(client, :post, "/repos/#{repository}/issues/#{number}/labels", %{
             "labels" => [name]
           }) do
      labels_added(response, name)
    end
  end

  defp labels_added(%{status: 200, body: labels}, name) when is_list(labels) do
    if Enum.any?(labels, &match?(%{"name" => ^name}, &1)),
      do: :ok,
      else: {:error, {:github_protocol_error, :labels}}
  end

  defp labels_added(%{status: 200}, _name), do: {:error, {:github_protocol_error, :labels}}
  defp labels_added(response, _name), do: Transport.error(response)

  def remove_pull_label(client, repository, number, name) do
    path =
      "/repos/#{repository}/issues/#{number}/labels/#{URI.encode(name, &URI.char_unreserved?/1)}"

    with :ok <- Fields.target(repository, number),
         {:ok, response} <- Transport.request(client, :delete, path, nil) do
      case response do
        %{status: status} when status in [200, 404] -> :ok
        _failed -> Transport.error(response)
      end
    end
  end

  def labeled_pulls(client, repository, name) do
    with :ok <- Fields.repository(repository),
         do: labeled_page(client, repository, name, 1, [])
  end

  defp labeled_page(client, repository, name, page, accumulated) do
    path =
      "/repos/#{repository}/issues?state=all&labels=#{URI.encode(name, &URI.char_unreserved?/1)}&per_page=#{@page_size}&page=#{page}"

    with {:ok, response} <- Transport.request(client, :get, path, nil),
         {:ok, items} <- issue_page(response) do
      pulls = for %{"number" => number, "pull_request" => %{}} <- items, do: number
      values = accumulated ++ pulls

      cond do
        length(items) < @page_size -> {:ok, MapSet.new(values)}
        page >= @maximum_pages -> {:error, {:github_reconciliation_incomplete, :labels}}
        true -> labeled_page(client, repository, name, page + 1, values)
      end
    end
  end

  defp issue_page(%{status: 200, body: items}) when is_list(items) do
    if Enum.all?(
         items,
         &match?(%{"number" => number} when is_integer(number) and number > 0, &1)
       ), do: {:ok, items}, else: {:error, {:github_protocol_error, :labeled_pulls}}
  end

  defp issue_page(%{status: 200}), do: {:error, {:github_protocol_error, :labeled_pulls}}
  defp issue_page(response), do: Transport.error(response)

  defp label_path(repository, name),
    do: "/repos/#{repository}/labels/#{URI.encode(name, &URI.char_unreserved?/1)}"
end
