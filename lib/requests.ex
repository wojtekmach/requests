defmodule Requests do
  @doc """
  Make a GET request.

  Options:

    * `:headers` - list of headers, defaults to `[]`.
    
  """
  def get(url, opts \\ []) when is_binary(url) and is_list(opts) do
    request_headers =
      for {name, value} <- Keyword.get(opts, :headers, []) do
        case name do
          string when is_binary(string) ->
            {String.to_charlist(string), String.to_charlist(value)}

          atom when is_atom(atom) ->
            name = name |> Atom.to_charlist() |> :string.replace('_', '-')
            {name, String.to_charlist(value)}
        end
      end

    request = {url, request_headers}

    case :httpc.request(:get, request, [], body_format: :binary) do
      {:ok, {{_, status, _}, resp_headers, body}} ->
        resp_headers =
          for {key, value} <- resp_headers, do: {List.to_string(key), List.to_string(value)}

        body = decode_body(body, List.keyfind(resp_headers, "content-type", 0))
        {:ok, %{status: status, headers: resp_headers, body: body}}

      {:error, reason} ->
        message = inspect(reason)
        {:error, %RuntimeError{message: message}}
    end
  end

  defp decode_body(body, {_, type}), do: decode_body(body, type)

  if Code.ensure_loaded?(Jason) do
    defp decode_body(body, "application/json" <> _), do: Jason.decode!(body)
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
