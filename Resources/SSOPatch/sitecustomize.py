"""Force openconnect-sso's named QtWebEngine profile to remain memory-only."""

import os


if os.environ.get("OPENCONNECT_SANDBOX_EPHEMERAL_SSO") == "1":
    import openconnect_sso.browser.webengine_process as _webengine

    _original_profile = _webengine.QWebEngineProfile

    def _ephemeral_profile(*_args, **_kwargs):
        # Qt's no-name constructor creates an off-the-record profile: cookies,
        # cache, and browser state stay in memory and vanish with the process.
        return _original_profile()

    _ephemeral_profile.openconnect_sandbox_ephemeral = True
    _webengine.QWebEngineProfile = _ephemeral_profile
