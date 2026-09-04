#!/usr/bin/env python3
"""Verified non-persistent entry point for the installed openconnect-sso package."""

import sys

import openconnect_sso.browser.webengine_process as webengine


if not getattr(webengine.QWebEngineProfile, "openconnect_sandbox_ephemeral", False):
    print("OpenConnect Sandbox refused SSO because ephemeral browser setup failed.", file=sys.stderr)
    raise SystemExit(78)

from openconnect_sso.cli import main


if __name__ == "__main__":
    raise SystemExit(main())
