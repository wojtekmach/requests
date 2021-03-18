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

    * `:headers` - list of request headers, defaults to `[]`.

    * `:default_headers` - if `true` (default), includes the default headers:

      * `"user-agent"` - `"requests/#{@vsn}"`

    * `:finch` - name of the `Finch` pool to use, defaults to `Requests.Finch` that is started
      with the default options.

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

    request_headers =
      case Keyword.get(opts, :default_headers, true) do
        true -> with_default_request_headers(request_headers)
        false -> request_headers
      end

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

  defp with_default_request_headers(headers) do
    put_new_header(headers, "user-agent", "requests/#{@vsn}")
  end

  defp put_new_header(headers, name, value) do
    if Enum.any?(headers, fn {key, _} -> String.downcase(key) == name end) do
      headers
    else
      [{name, value} | headers]
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
    if value = get_header(headers, "content-encoding") do
      value
      |> String.downcase()
      |> String.split(",", trim: true)
      |> Stream.map(&String.trim/1)
      |> Enum.reverse()
    else
      []
    end
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
    content_type = get_header(response.headers, "content-type")
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

  defp get_header(headers, name) do
    Enum.find_value(headers, nil, fn {key, value} ->
      if String.downcase(key) == name do
        value
      else
        nil
      end
    end)
  end
end
