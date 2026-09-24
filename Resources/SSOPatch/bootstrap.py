#!/usr/bin/env python3
"""Verified managed entry point for the installed openconnect-sso package."""

import os
import sys

import openconnect_sso.browser.webengine_process as webengine


if os.environ.get("OPENCONNECT_SANDBOX_EPHEMERAL_SSO") == "1":
    if not getattr(webengine.QWebEngineProfile, "openconnect_sandbox_ephemeral", False):
        print("OpenConnect Sandbox refused SSO because ephemeral browser setup failed.", file=sys.stderr)
        raise SystemExit(78)

if os.environ.get("OPENCONNECT_SANDBOX_MANAGED_CREDENTIALS") == "1":
    import openconnect_sso.config as config
    if not getattr(config.Credentials, "openconnect_sandbox_managed", False):
        print("OpenConnect Sandbox refused SSO because credential isolation failed.", file=sys.stderr)
        raise SystemExit(78)

from openconnect_sso.cli import main


if __name__ == "__main__":
    raise SystemExit(main())
