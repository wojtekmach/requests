defmodule RequestsTest do
  use ExUnit.Case, async: true
  import Plug.Conn

  setup do
    bypass = Bypass.open()
    [bypass: bypass, url: "http://localhost:#{bypass.port}"]
  end

  test "simple requests", c do
    Bypass.expect(c.bypass, "GET", "/200", fn conn ->
      send_resp(conn, 200, "ok")
    end)

    assert Requests.get!(c.url <> "/200").status == 200

    Bypass.expect(c.bypass, "GET", "/404", fn conn ->
      send_resp(conn, 404, "not found")
    end)

    assert Requests.get!(c.url <> "/404").status == 404
  end

  test "user agent", c do
    Bypass.expect(c.bypass, "GET", "/user-agent", fn conn ->
      [user_agent | _] = get_req_header(conn, "user-agent")
      send_resp(conn, 200, user_agent)
    end)

    assert "requests/" <> _ = Requests.get!(c.url <> "/user-agent").body

    assert "custom" = Requests.get!(c.url <> "/user-agent", headers: [user_agent: "custom"]).body

    assert "mint/" <> _ =
             Requests.get!(c.url <> "/user-agent", default_request_middleware: false).body
  end

  test "json", c do
    Bypass.expect(c.bypass, "POST", "/json", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = body |> Jason.decode!() |> Jason.encode_to_iodata!()

      conn
      |> put_resp_content_type("application/json; charset=utf-8")
      |> send_resp(200, body)
    end)

    body = %{"x" => 1}
    opts = [headers: [content_type: "application/json"]]
    assert Requests.post!(c.url <> "/json", body, opts).body == body
  end

  test "csv", c do
    Bypass.expect(c.bypass, "POST", "/csv", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      body =
        body
        |> NimbleCSV.RFC4180.parse_string(skip_headers: false)
        |> NimbleCSV.RFC4180.dump_to_iodata()

      conn
      |> put_resp_content_type("text/csv; charset=utf-8")
      |> send_resp(200, body)
    end)

    body = [
      ~w(x y),
      ~w(1 1),
      ~w(2 2)
    ]

    opts = [headers: [content_type: "text/csv"]]
    assert Requests.post!(c.url <> "/csv", body, opts).body == body
  end

  test "decompress", c do
    Bypass.expect(c.bypass, "GET", "/gzip", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-encoding", "gzip")
      |> Plug.Conn.send_resp(200, :zlib.gzip("foo"))
    end)

    assert Requests.get!(c.url <> "/gzip").body == "foo"

    Bypass.expect(c.bypass, "GET", "/deflate+gzip", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-encoding", "deflate,gzip")
      |> Plug.Conn.send_resp(200, "foo" |> :zlib.zip() |> :zlib.gzip())
    end)

    assert Requests.get!(c.url <> "/deflate+gzip").body == "foo"
  end

  test "errors", c do
    :ok = Bypass.down(c.bypass)

    assert_raise Mint.TransportError, ~r/connection refused/, fn ->
      Requests.get!(c.url <> "/200")
    end
  end
end
