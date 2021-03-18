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
    pid = self()

    Bypass.expect(c.bypass, "GET", "/user-agent", fn conn ->
      send(pid, {:user_agent, get_req_header(conn, "user-agent")})
      send_resp(conn, 200, "ok")
    end)

    assert Requests.get!(c.url <> "/user-agent").status == 200
    assert_received {:user_agent, ["requests/" <> _]}

    assert Requests.get!(c.url <> "/user-agent", headers: [user_agent: "custom"]).status == 200
    assert_received {:user_agent, ["custom"]}
  end

  test "json", c do
    Bypass.expect(c.bypass, "GET", "/json", fn conn ->
      conn
      |> put_resp_content_type("application/json; charset=utf-8")
      |> send_resp(200, Jason.encode!(%{"x" => 1}))
    end)

    assert Requests.get!(c.url <> "/json").body == %{"x" => 1}
  end

  test "csv", c do
    Bypass.expect(c.bypass, "GET", "/csv", fn conn ->
      body = NimbleCSV.RFC4180.dump_to_iodata([~w(x y), ~w(1 1), ~w(2 2)])

      conn
      |> put_resp_content_type("text/csv; charset=utf-8")
      |> send_resp(200, body)
    end)

    assert Requests.get!(c.url <> "/csv").body == [
             ~w(x y),
             ~w(1 1),
             ~w(2 2)
           ]
  end

  test "gzip", c do
    Bypass.expect(c.bypass, "GET", "/gzip", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-encoding", "gzip")
      |> Plug.Conn.send_resp(200, :zlib.gzip("foo"))
    end)

    assert Requests.get!(c.url <> "/gzip").body == "foo"
  end

  test "errors", c do
    :ok = Bypass.down(c.bypass)

    assert_raise Mint.TransportError, ~r/connection refused/, fn ->
      Requests.get!(c.url <> "/200")
    end
  end
end
