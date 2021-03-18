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

  See `request/4` for possible options.
  """
  def get(url, opts \\ []) do
    request(:get, url, "", opts)
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

  @doc """
  Makes a HTTP request.

  Options:

    * `:headers` - list of request headers, defaults to `[]`.

    * `:finch` - name of the `Finch` pool to use, defaults to `Requests.Finch` that is started
      with the default options.

    * `:request_middleware` - list of middleware to run the request through, defaults to `[]`.

    * `:default_request_middleware` - if `true` (default), prepends the following functions
       to the request middleware list:

      * `normalize_request_headers/2`
      * `default_headers/2`

    * `:response_middleware` - list of middleware to run the response through, defaults to `[]`.

    * `:default_response_middleware` - if `true` (default), prepends the following functions to
      the response middleware list:

      * `decompress/2`
      * `response_content_type/2`

  ## Request middleware

  A request middleware is a function that two arguments:

  - `request` struct
  - `opts`

  An example is `normalize_request_headers/2`.

  ## Response middleware

  A response middleware is a function that two arguments:

  - `response` struct
  - `opts`

  An example is `decompress/2`.
  """
  def request(method, url, body, opts \\ []) when is_binary(url) and is_list(opts) do
    middleware =
      if Keyword.get(opts, :default_request_middleware, true) do
        [
          &normalize_request_headers/2,
          &default_headers/2
        ]
      else
        []
      end ++ Keyword.get(opts, :request_middleware, [])

    request = Finch.build(method, url, Keyword.get(opts, :headers, []), body)
    request = Enum.reduce(middleware, request, &apply(&1, [&2, opts]))

    with {:ok, response} <- Finch.request(request, Requests.Finch) do
      middleware =
        if Keyword.get(opts, :default_response_middleware, true) do
          [
            &decompress/2,
            &response_content_type/2
          ]
        else
          []
        end ++ Keyword.get(opts, :response_middleware, [])

      {:ok, Enum.reduce(middleware, response, &apply(&1, [&2, opts]))}
    end
  end

  ## Request middleware

  @doc """
  Normalizes request headers.

  Turns atom header names into strings, e.g.: `:user_agent` becomes `"user-agent"`.
  Non-atom names are returned as is.
  """
  @doc middleware: :request
  def normalize_request_headers(request, _opts) do
    headers =
      for {name, value} <- request.headers do
        if is_atom(name) do
          {name |> Atom.to_string() |> String.replace("_", "-"), value}
        else
          {name, value}
        end
      end

    %{request | headers: headers}
  end

  @doc """
  Adds default request headers.

  Currently these headers are added:

    * `"user-agent"` - `"requests/#{@vsn}"`

    * `"accept-encoding"` - `"gzip"`

  """
  @doc middleware: :request
  def default_headers(request, _opts) do
    update_in(request.headers, fn headers ->
      headers
      |> put_new_header("user-agent", "requests/#{@vsn}")
      |> put_new_header("accept-encoding", "gzip")
    end)
  end

  ## Response middleware

  @doc """
  Decompresses the response body.
  """
  @doc middleware: :response
  def decompress(response, _opts) do
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

  @doc """
  Decodes the response body based on the content-type header.

  Currently these `"content-type"` values are supported:

    * `"application/json*"` - using `Jason.decode!/1` (if Jason is available)

    * `"text/csv*"` - using `NimbleCSV.RFC4180.parse_string(body, skip_headers: false)`
      (if NimbleCSV is available)

  """
  @doc middleware: :response
  def response_content_type(response, _opts) do
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

  ## Utilities

  defp get_header(headers, name) do
    Enum.find_value(headers, nil, fn {key, value} ->
      if String.downcase(key) == name do
        value
      else
        nil
      end
    end)
  end

  defp put_new_header(headers, name, value) do
    if Enum.any?(headers, fn {key, _} -> String.downcase(key) == name end) do
      headers
    else
      [{name, value} | headers]
    end
  end
end
