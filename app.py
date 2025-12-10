from flask import Flask, request, Response
import requests

app = Flask(__name__)

MATRIX_BASE = "https://disaccord.cc"  # real homeserver

@app.route("/_matrix/client/v3/<path:path>", methods=["GET", "PUT", "POST"])
def proxy(path):
    upstream_url = f"{MATRIX_BASE}/_matrix/client/v3/{path}"

    # Log incoming request from Discourse
    print("=== Incoming from Discourse ===")
    print("Method:", request.method)
    print("URL:", request.url)
    print("Upstream URL:", upstream_url)
    print("Headers:")
    for k, v in request.headers.items():
        print(f"  {k}: {v}")
    body = request.get_data()
    print("Body:", body.decode("utf-8", errors="ignore"))
    print("===============================")

    # Prepare headers for forwarding
    headers = dict(request.headers)
    
    # --- FIXES ---
    # Remove the Host header so 'requests' sets it correctly for disaccord.cc
    headers.pop("Host", None)
    # Remove Content-Length so 'requests' recalculates it (avoids length mismatch errors)
    headers.pop("Content-Length", None)
    # -------------

    # Optionally, force a specific token instead of passing through:
    # headers["Authorization"] = "Bearer YOUR_REAL_MATRIX_TOKEN_HERE"

    resp = requests.request(
        method=request.method,
        url=upstream_url,
        headers=headers,
        data=body,
        params=request.args,
        timeout=30,
    )

    # Log response
    print("=== Response from Matrix ===")
    print("Status:", resp.status_code)
    print("Headers:")
    for k, v in resp.headers.items():
        print(f"  {k}: {v}")
    print("Body:", resp.text[:1000])  # don’t spam too much
    print("============================")

    # Clean up response headers to avoid encoding mismatches
    # (requests automatically decodes gzip, so we must remove Content-Encoding if present)
    excluded_headers = ['content-encoding', 'content-length', 'transfer-encoding', 'connection']
    response_headers = [(k, v) for k, v in resp.headers.items() if k.lower() not in excluded_headers]

    return Response(resp.content, status=resp.status_code, headers=dict(response_headers))

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5006)