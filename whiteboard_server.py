#!/usr/bin/env python3
# Copyright (C) 2026 Ephraim BOURIAHI
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

"""
Minimal HTTPS server for the EduTerra whiteboard page.

Standard library only. Serves a single HTML file (nothing else on disk is
reachable), re-reading it on each request so edits show up without a restart.

Usage: whiteboard_server.py <port> --cert CERT --key KEY [--file PAGE] [--bind ADDR]
"""
import argparse
import os
import ssl
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_PAGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'EduTerraWhiteboard.html')
ROUTES = {'/', '/index.html', '/EduTerraWhiteboard.html'}


class WhiteboardHandler(BaseHTTPRequestHandler):
    page_path = DEFAULT_PAGE
    server_version = 'EduTerraWhiteboard'
    sys_version = ''
    timeout = 15  # Drop idle/slow clients so they don't hold a thread

    def setup(self):
        super().setup()
        # TLS handshake runs here, in the per-connection thread, so a slow
        # client can't block the accept loop
        self.connection.do_handshake()

    def _send_page(self, include_body):
        if self.path.split('?', 1)[0] not in ROUTES:
            self.send_error(404, 'Not Found')
            return
        try:
            with open(self.page_path, 'rb') as f:
                body = f.read()
        except OSError:
            self.send_error(500, 'Page unavailable')
            return

        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Strict-Transport-Security', 'max-age=31536000')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.end_headers()
        if include_body:
            self.wfile.write(body)

    def do_GET(self):
        self._send_page(include_body=True)

    def do_HEAD(self):
        self._send_page(include_body=False)


class WhiteboardServer(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        # Failed handshakes (scanners, browsers rejecting a self-signed cert,
        # plain HTTP on the TLS port) are routine: log one line, no traceback
        err = sys.exc_info()[1]
        if isinstance(err, (ssl.SSLError, ConnectionError, TimeoutError)):
            print(f"{client_address[0]} - connection dropped: {err.__class__.__name__}", file=sys.stderr)
            return
        super().handle_error(request, client_address)


def main():
    parser = argparse.ArgumentParser(description='HTTPS server for the EduTerra whiteboard page')
    parser.add_argument('port', type=int, help='Port to listen on')
    parser.add_argument('--cert', required=True, help='TLS certificate (PEM, full chain)')
    parser.add_argument('--key', required=True, help='TLS private key (PEM)')
    parser.add_argument('--file', default=DEFAULT_PAGE, help='HTML page to serve')
    parser.add_argument('--bind', default='', help='Address to bind (default: all interfaces)')
    args = parser.parse_args()

    page = os.path.abspath(args.file)
    if not os.path.isfile(page):
        print(f"Page not found: {page}", file=sys.stderr)
        sys.exit(1)
    WhiteboardHandler.page_path = page

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(args.cert, args.key)

    httpd = WhiteboardServer((args.bind, args.port), WhiteboardHandler)
    httpd.socket = context.wrap_socket(httpd.socket, server_side=True, do_handshake_on_connect=False)

    print(f"Serving {page} on https://{args.bind or '0.0.0.0'}:{args.port}/", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == '__main__':
    main()
