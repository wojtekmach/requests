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
  require Logger

  @vsn Mix.Project.config()[:version]

  @moduledoc """
  Yet another HTTP client.

  ## Features

    * Extensible via request and response middlewares

    * Automatic body encoding/decoding (via `encode_request_body/2` and `decode_response_body/2`
      middleware)

    * Automatic compression/decompression (via the `compress/2` and `decompress/2` middleware)

  ## Examples

      iex> Requests.get!("https://api.github.com/repos/elixir-lang/elixir").body["description"]
      "Elixir is a dynamic, functional language designed for building scalable and maintainable applications"

      iex> data = %{files: %{"hello.txt" => %{"content" => "world"}}}
      iex> headers = [authorization: "Bearer " <> System.fetch_env!("GITHUB_TOKEN")]
      iex> Requests.post!("https://api.github.com/gists", {:json, data}, headers: headers).status
      201

  ## Credits

    * [Requests](https://requests.readthedocs.io)
    * [Tesla](https://github.com/teamon/tesla)
    * [Finch](https://github.com/keathley/finch) (and [Mint](https://github.com/elixir-mint/mint) & [NimblePool](https://github.com/dashbitco/nimble_pool)!)

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
      * `compress/2`

    * `:response_middleware` - list of middleware to run the response through, defaults to `[]`.

    * `:default_response_middleware` - if `true` (default), prepends the following functions to
      the response middleware list:

      * `decompress/2`
      * `decode_response_body/2`

  The `opts` keywords list is passed to each middleware.

  ## Request middleware

  A request middleware is a function that takes two arguments:
  request:

  - a `Finch.Request` struct
  - an `opts` keywords list

  and returns a possibly updated.

  An example is `compress/2`.

  ## Response middleware

  A response middleware is a function that takes two arguments:

  - a `Finch.Response` struct
  - an `opts` keywords list

  and returns a possibly updated response.

  An example is `decompress/2`.
  """
  def request(method, url, body, opts \\ []) when is_binary(url) and is_list(opts) do
    middleware =
      if Keyword.get(opts, :default_request_middleware, true) do
        [
          &normalize_request_headers/2,
          &default_headers/2,
          &encode_request_body/2,
          &compress/2
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
  Encodes the request body based on its shape.

  If body is of the following shape, it's encoded and its `content-type` set
  accordingly. Otherwise it's unchanged.

  | Shape                     | Encoder               | Content-Type                          |
  | ------------------------- | ---------------       | ------------------------------------- |
  | `{:form, data}`           | `:form_encoder`       | `"application/x-www-form-urlencoded"` |
  | `{:json, data}`           | `:json_encoder`       | `"application/json"`                  |
  | `{:csv, rows}`            | `:csv_encoder`        | `"text/csv"`                          |
  | `{:csv, {:stream, rows}}` | `:csv_stream_encoder` | `"text/csv"`                          |

  ## Options

    * `:form_encoder` - defaults to [`&URI.encode_query/1`](`URI.encode_query/1`).

    * `:json_encoder` - defaults to [`&Jason.encode_to_iodata!/1`](`Jason.encode_to_iodata!/1`).

    * `:csv_encoder` - defaults to [`&NimbleCSV.RFC4180.dump_to_iodata/1`](`NimbleCSV.RFC4180.dump_to_iodata/1`).

    * `:csv_stream_encoder` - defaults to [`&NimbleCSV.RFC4180.dump_to_stream/1`](`NimbleCSV.RFC4180.dump_to_stream/1`).

  ## Examples

      iex> Requests.post!("https://httpbin.org/post", {:form, custname: "Alice"})
      %Finch.Response{
        status: 200,
        headers: [{"content-type", "application/json"}, ...],
        body: %{
          "form" => %{"custname" => "Alice"},
          ...
        }
      }

  """
  @doc middleware: :request
  def encode_request_body(request, opts) do
    case request.body do
      {:form, data} ->
        encode(request, URI.encode_query(data), "application/x-www-form-urlencoded")

      {:json, data} ->
        encoder =
          Keyword.get_lazy(opts, :json_encoder, fn ->
            unless Code.ensure_loaded?(Jason) do
              Logger.error("""
              Could not find jason dependency.

              Please add it to your dependencies:

                  {:jason, "~> 1.0"}

              Or set your own JSON encoder:

                  Requests.post!(url, {:json, data}, json_encoder: &MyEncoder.encode!/1)
              """)

              raise "missing jason dependency"
            end

            &Jason.encode_to_iodata!/1
          end)

        encode(request, encoder.(data), "application/json")

      {:csv, {:stream, data}} ->
        encoder =
          Keyword.get_lazy(opts, :csv_stream_encoder, fn ->
            unless Code.ensure_loaded?(NimbleCSV) do
              Logger.error("""
              Could not find nimble_csv dependency.

              Please add it to your dependencies:

                  {:nimble_csv, "~> 1.0"}

              Or set your own CSV encoder:

                  Requests.post!(url, {:csv, data}, csv_stream_encoder: &MyEncoder.encode!/1)
              """)

              raise "missing nimble_csv dependency"
            end

            &NimbleCSV.RFC4180.dump_to_stream/1
          end)

        encode(request, {:stream, encoder.(data)}, "text/csv")

      {:csv, data} ->
        encoder =
          Keyword.get_lazy(opts, :csv_encoder, fn ->
            unless Code.ensure_loaded?(NimbleCSV) do
              Logger.error("""
              Could not find nimble_csv dependency.

              Please add it to your dependencies:

                  {:nimble_csv, "~> 1.0"}

              Or set your own CSV encoder:

                  Requests.post!(url, {:csv, data}, csv_encoder: &MyEncoder.encode!/1)
              """)

              raise "missing nimble_csv dependency"
            end

            &NimbleCSV.RFC4180.dump_to_iodata/1
          end)

        encode(request, encoder.(data), "text/csv")

      _ ->
        request
    end
  end

  defp encode(request, body, content_type) do
    %{
      request
      | body: body,
        headers: put_new_header(request.headers, "content-type", content_type)
    }
  end

  @doc """
  Compresses the request body based on the `content-encoding` header.

  Supported values: `"gzip"`, `"x-gzip"`, `"deflate"`, and `"identity"`.
  """
  @doc middleware: :request
  def compress(request, _opts) do
    compression_algorithms = get_content_encoding_header(request.headers)
    update_in(request.body, &compress_body(&1, compression_algorithms))
  end

  defp compress_body(body, algorithms) do
    Enum.reduce(algorithms, body, &compress_with_algorithm/2)
  end

  defp compress_with_algorithm(gzip, body) when gzip in ["gzip", "x-gzip"],
    do: :zlib.gzip(body)

  defp compress_with_algorithm("deflate", body),
    do: :zlib.zip(body)

  defp compress_with_algorithm("identity", body),
    do: body

  defp compress_with_algorithm(algorithm, _body),
    do: raise("unsupported compression algorithm: #{inspect(algorithm)}")

  ## Response middleware

  @doc """
  Decompresses the response body based on the `content-encoding` header.

  Supported values: `"gzip"`, `"x-gzip"`, `"deflate"`, and `"identity"`.
  """
  @doc middleware: :response
  def decompress(response, _opts) do
    compression_algorithms = get_content_encoding_header(response.headers)
    update_in(response.body, &decompress_body(&1, compression_algorithms))
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
  Decodes the response body based on the `content-type` header.

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
end
