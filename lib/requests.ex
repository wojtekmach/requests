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
    request_headers =
      for {name, value} <- Keyword.get(opts, :headers, []) do
        if is_atom(name) do
          {name |> Atom.to_string() |> String.replace("_", "-"), value}
        else
          {name, value}
        end
      end

    request_headers = with_default_request_headers(request_headers)

    request = Finch.build(:get, url, request_headers)

    with {:ok, response} <- Finch.request(request, Requests.Finch) do
      {:ok, process(request, response)}
    end
  end

  @doc """
  See `get/2`.
  """
  def get!(url, opts \\ []) do
    case get(url, opts) do
      {:ok, response} -> response
      {:error, exception} -> raise exception
    end
  end

  @default_user_agent "requests/#{@vsn} Elixir/#{System.version()}"

  defp with_default_request_headers(headers) do
    if List.keyfind(headers, "user-agent", 0) do
      headers
    else
      [{"user-agent", @default_user_agent}] ++ headers
    end
  end

  defp process(request, response) do
    middleware = [
      &decompress/2,
      &content_type/2
    ]

    Enum.reduce(middleware, response, &apply(&1, [request, &2]))
  end

  defp decompress(_request, response) do
    compression_algorithms = get_content_encoding_header(response.headers)
    update_in(response.body, &decompress_body(&1, compression_algorithms))
  end

  defp get_content_encoding_header(headers) do
    Enum.find_value(headers, [], fn {name, value} ->
      if String.downcase(name) == "content-encoding" do
        value
        |> String.downcase()
        |> String.split(",", trim: true)
        |> Stream.map(&String.trim/1)
        |> Enum.reverse()
      else
        nil
      end
    end)
  end

  defp decompress_body(body, algorithms) do
    Enum.reduce(algorithms, body, &decompress_with_algorithm/2)
  end

  defp decompress_with_algorithm(gzip, body) when gzip in ["gzip", "x-gzip"],
    do: :zlib.gunzip(body)

  defp decompress_with_algorithm("deflate", body),
    do: :zlib.unzip(body)

  defp decompress_with_algorithm("identity", body),
    do: body

  defp decompress_with_algorithm(algorithm, _body),
    do: raise("unsupported decompression algorithm: #{inspect(algorithm)}")

  defp content_type(_request, response) do
    content_type =
      with {_, value} <- List.keyfind(response.headers, "content-type", 0) do
        value
      end

    %{response | body: decode_body(response.body, content_type)}
  end

  if Code.ensure_loaded?(Jason) do
    defp decode_body(body, "application/json" <> _), do: Jason.decode!(body)
  end

  if Code.ensure_loaded?(NimbleCSV) do
    defp decode_body(body, "text/csv" <> _) do
      NimbleCSV.RFC4180.parse_string(body, skip_headers: false)
    end
  end

  defp decode_body(body, _), do: body
end
