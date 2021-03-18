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

  @moduledoc """
  Yet another HTTP client inspired by Python's [Requests](https://requests.readthedocs.io).

  ## Features

    * Extensible via request and response middlewares
    * Automatic decompression (via `decompress/2`)
    * Automatic body encoding/decoding (via `encode_request_body/2`, `decode_response_body/2`)

  ## Examples

      iex> Requests.get!("https://api.github.com/repos/elixir-lang/elixir").body["description"]
      "Elixir is a dynamic, functional language designed for building scalable and maintainable applications"

  """

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
  Makes a POST request.

  See `request/4` for possible options.
  """
  def post(url, body, opts \\ []) do
    request(:post, url, body, opts)
  end

  @doc """
  See `post/3`.
  """
  def post!(url, body, opts \\ []) do
    case post(url, body, opts) do
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
      * `encode_request_body/2`

    * `:response_middleware` - list of middleware to run the response through, defaults to `[]`.

    * `:default_response_middleware` - if `true` (default), prepends the following functions to
      the response middleware list:

      * `decompress/2`
      * `decode_response_body/2`

  The `opts` keywords list is passed to each middleware.

  ## Request middleware

  A request middleware is a function that takes two arguments and returns a possibly updated
  request:

  - a `Finch.Request` struct
  - an `opts` keywords list

  An example is `normalize_request_headers/2`.

  ## Response middleware

  A response middleware is a function that takes two arguments and returns a possibly updated
  response:

  - a `Finch.Response` struct
  - an `opts` keywords list

  An example is `decompress/2`.
  """
  def request(method, url, body, opts \\ []) when is_binary(url) and is_list(opts) do
    middleware =
      if Keyword.get(opts, :default_request_middleware, true) do
        [
          &normalize_request_headers/2,
          &default_headers/2,
          &encode_request_body/2
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
            &decode_response_body/2
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

  @doc """
  Encodes the reqeuest body based on the content-type header.

  ## Options

    * `:json_encoder` - if set, used on the `"application/json*"` content type. Defaults to
      [`&Jason.encode_to_iodata!/1`](`Jason.encode_to_iodata!/1`)
      if `jason` dependency is installed.

    * `:csv_encoder` - if set, used on the `"text/csv*"` content type. Defaults to
      [`&NimbleCSV.RFC4180.dump_to_iodata/1`](`NimbleCSV.RFC4180.dump_to_iodata/1`)
      if `nimble_csv` dependency is
      installed.

  """
  @doc middleware: :request
  def encode_request_body(request, opts) do
    json_encoder =
      Keyword.get_lazy(opts, :json_encoder, fn ->
        if Code.ensure_loaded?(Jason) do
          &Jason.encode_to_iodata!/1
        end
      end)

    csv_encoder =
      Keyword.get_lazy(opts, :csv_encoder, fn ->
        if Code.ensure_loaded?(NimbleCSV) do
          &NimbleCSV.RFC4180.dump_to_iodata/1
        end
      end)

    body =
      case get_header(request.headers, "content-type") do
        "application/json" <> _ when json_encoder != nil ->
          json_encoder.(request.body)

        "text/csv" <> _ when csv_encoder != nil ->
          csv_encoder.(request.body)

        _ ->
          request.body
      end

    %{request | body: body}
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

  ## Options

    * `:json_decoder` - if set, used on the `"application/json*"` content type. Defaults to
      [`&Jason.decode/1`](`Jason.decode/1`) if `jason` dependency is installed.

    * `:csv_decoder` - if set, used on the `"text/csv*"` content type. Defaults to
      [`&NimbleCSV.RFC4180.parse_string(&1, skip_headers: false)`](`NimbleCSV.RFC4180.parse_string/2`)
      if `nimble_csv` dependency is installed.

  """
  @doc middleware: :response
  def decode_response_body(response, opts) do
    json_decoder =
      Keyword.get_lazy(opts, :json_decoder, fn ->
        if Code.ensure_loaded?(Jason) do
          &Jason.decode!/1
        end
      end)

    csv_decoder =
      Keyword.get_lazy(opts, :csv_decoder, fn ->
        if Code.ensure_loaded?(NimbleCSV) do
          &NimbleCSV.RFC4180.parse_string(&1, skip_headers: false)
        end
      end)

    body =
      case get_header(response.headers, "content-type") do
        "application/json" <> _ when json_decoder != nil ->
          json_decoder.(response.body)

        "text/csv" <> _ when csv_decoder != nil ->
          csv_decoder.(response.body)

        _ ->
          response.body
      end

    %{response | body: body}
  end

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
