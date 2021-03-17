defmodule Requests.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [{Finch, name: Requests.Finch}]
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end

defmodule Requests do
  @vsn Mix.Project.config()[:version]

  @doc """
  Makes a GET request.

  Options:

    * `:headers` - list of headers, defaults to `[]`.
    
  """
  def get(url, opts \\ []) when is_binary(url) and is_list(opts) do
    request_headers = with_default_request_headers(Keyword.get(opts, :headers, []))

    request_headers =
      for {name, value} <- request_headers do
        if is_atom(name) do
          {name |> Atom.to_string() |> String.replace("_", "-"), value}
        else
          {name, value}
        end
      end

    request = Finch.build(:get, url, request_headers)

    with {:ok, response} <- Finch.request(request, Requests.Finch) do
      body = decode_body(response.body, List.keyfind(response.headers, "content-type", 0))
      {:ok, %{response | body: body}}
    end
  end

  @default_user_agent "requests/#{@vsn} Elixir/#{System.version()}"

  defp with_default_request_headers(headers) do
    if List.keyfind(headers, "user-agent", 0) || List.keyfind(headers, :user_agent, 0) do
      headers
    else
      [user_agent: @default_user_agent] ++ headers
    end
  end

  defp decode_body(body, {_, type}), do: decode_body(body, type)

  if Code.ensure_loaded?(Jason) do
    defp decode_body(body, "application/json" <> _), do: Jason.decode!(body)
  end

  if Code.ensure_loaded?(NimbleCSV) do
    defp decode_body(body, "text/csv" <> _) do
      NimbleCSV.RFC4180.parse_string(body, skip_headers: false)
    end
  end

  defp decode_body(body, _), do: body

  @doc """
  See `get/2`.
  """
  def get!(url, opts \\ []) do
    case get(url, opts) do
      {:ok, response} -> response
      {:error, exception} -> raise exception
    end
  end
end
